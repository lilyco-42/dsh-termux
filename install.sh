#!/data/data/com.termux/files/usr/bin/bash
# Install @deepseek-ai/dsh on Termux (Android) and patch it into a working state.
#
# dsh has several native deps and Linux-isms that break on Termux:
#   1. node-pty: node-gyp copies process.config.variables.OS ("android") into
#      config.gypi, making gyp reference the undefined android_ndk_path.
#   2. koffi: calls statx(), hidden by bionic below API 30 (clang targets 24).
#   3. sharp: no prebuilt for android-arm64; must build against system libvips.
#   4. HMR service needs Node --expose-internals (no android binding for
#      node-addon-require-builtin).
#   5. session-persistence-jsonl publishes logs with a hard link(), which
#      Android forbids (EACCES); rename() is equally atomic and works.
#   6. attachment-local fsyncs every ancestor directory up to "/" (the
#      untrusted_app SELinux domain cannot open("/data/data")) and also
#      publishes attachments with link(), which Android forbids; the walk
#      now tolerates unopenable ancestors and publication falls back to
#      rename(). Without this, read_image cannot store an image.
#   7. fs-local publishes a NEW file with link() (no-replace semantics);
#      Android refuses link() too, so every create-file write fails with
#      FS_IO_ERROR. Publication falls back to rename(); the surrounding
#      guard still refuses to overwrite an existing file.

set -euo pipefail

NDK_TARGET="aarch64-unknown-linux-android30"
# NODE_BIN / NODE_GYP_BIN / DSH_LIB are resolved AFTER the `pkg install` below:
# on a fresh Termux device `node`/`npm` don't exist yet, so computing them up
#here leaves NODE_BIN empty and `set -e` makes the script silently exit (nothing
#installed, no error message) before the installer even runs.

log() { printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "$3"; }

# Auto-scan for a DeepSeek API key across common sources and print the first
# match. Priority: environment, dsh's credential store, shell rc files, then
# standalone key files. Prints nothing and returns 1 when no key is found.
find_deepseek_key() {
    local key f creds
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        printf '%s' "$DEEPSEEK_API_KEY"; return 0
    fi
    creds="${DSH_HOME:-$HOME/.dsh}/.credentials.yaml"
    if [ -f "$creds" ]; then
        key="$(grep -E 'DEEPSEEK_API_KEY[[:space:]]*:' "$creds" | head -1 \
            | sed -E 's/.*DEEPSEEK_API_KEY[[:space:]]*:[[:space:]]*//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    fi
    for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ -f "$f" ] || continue
        key="$(grep -E '^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=' "$f" | head -1 \
            | sed -E 's/^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    for f in "$HOME/.deepseek_api_key" "$HOME/.deepseek"; do
        [ -f "$f" ] || continue
        key="$(head -1 "$f" | tr -d " \t\r\n")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    return 1
}

log 1 9 "Installing prerequisites..."
pkg install -y nodejs build-essential clang cmake ninja python libvips >/dev/null

# Resolve Node/npm paths only now that nodejs is installed — before, on a
# fresh device, `command -v node` would be empty, making node-gyp rebuild and
# the shebang patch silently use an empty "" (or `set -e` would silently exit).
# Fail loudly if Node/npm still aren't available instead of crashing silently.
if ! NODE_BIN="$(command -v node)"; then
    echo "error: 'node' not found after 'pkg install -y nodejs'; NODE_BIN is empty" >&2
    exit 1
fi
if [ -z "$NODE_BIN" ]; then
    echo "error: 'node' resolves to an empty path after 'pkg install -y nodejs'" >&2
    exit 1
fi
NODE_GYP_BIN="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"
if [ ! -f "$NODE_GYP_BIN" ]; then
    echo "error: node-gyp not found at $NODE_GYP_BIN (did 'pkg install -y nodejs' succeed?)" >&2
    exit 1
fi

log 2 9 "Patching node-gyp (drop bogus OS=android)..."
CREATE_GYPI="$(npm root -g)/npm/node_modules/node-gyp/lib/create-config-gypi.js"
if [ ! -f "$CREATE_GYPI" ]; then
    echo "error: node-gyp not found at $CREATE_GYPI" >&2
    exit 1
fi
if grep -q "delete variables.OS" "$CREATE_GYPI"; then
    echo "    node-gyp already patched, skipping."
else
    python3 - "$CREATE_GYPI" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = "const variables = config.variables\n"
assert anchor in src, "patch anchor not found; node-gyp may have changed"
block = (
    anchor + "\n"
    + "  // Termux's Node.js reports process.config.variables.OS as \"android\" even\n"
    + "  // though native addons build against the Termux (linux-like) sysroot, not\n"
    + "  // the Android NDK. gyp's \"OS == android\" branches then reference the\n"
    + "  // undefined android_ndk_path variable and fail. Drop OS so gyp infers it\n"
    + "  // as \"linux\" from the host platform.\n"
    + "  delete variables.OS\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, block, 1))
print("    patched", path)
PY
fi

log 3 9 "Installing @deepseek-ai/dsh (native modules will be compiled)..."
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
npm install -g @deepseek-ai/dsh

log 4 9 "Building sharp against system libvips..."
SHARP_DIR="$DSH_LIB/node_modules/sharp"
if [ -f "$SHARP_DIR/src/build/Release/sharp-android-arm64-"*.node ]; then
    echo "    sharp already built, skipping."
else
    (cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=1 \
        CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
        "$NODE_BIN" "$NODE_GYP_BIN" rebuild --directory=src >/dev/null)
fi

log 5 9 "Patching session persistence (hard link -> rename)..."
SESSION_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
if [ -f "$SESSION_JS" ]; then
    if grep -q "await rename(tmp, finalPath)" "$SESSION_JS"; then
        echo "    session persistence already patched, skipping."
    else
        python3 - "$SESSION_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
)
src = src.replace(
    "\t\t\tawait link(tmp, finalPath);",
    "\t\t\tawait rename(tmp, finalPath);",
)
open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
    fi
else
    echo "    warning: session persistence module not found, skipping."
fi

log 6 9 "Patching attachment store (durability walk + hard link fallback)..."
ATTACH_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js"
if [ ! -f "$ATTACH_JS" ]; then
    echo "    warning: attachment module not found, skipping (read_image will not work)."
elif grep -q "termux-hardlink-fallback" "$ATTACH_JS"; then
    echo "    attachment store already patched, skipping."
else
    python3 - "$ATTACH_JS" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "termux-hardlink-fallback" in src:
    print("    already patched")
    sys.exit(0)


def once(old, new):
    global src
    assert src.count(old) == 1, "patch anchor not found (%d matches); dsh may have changed" % src.count(old)
    src = src.replace(old, new, 1)


# (a) The durability walk fsyncs every ancestor up to the filesystem root, but
#     an untrusted Android app cannot open("/"), "/data" or "/data/data".
once(
    "\tconst handle = await open(path, constants.O_RDONLY);",
    "\tlet handle;\n"
    "\ttry {\n"
    "\t\thandle = await open(path, constants.O_RDONLY);\n"
    "\t} catch (error) {\n"
    "\t\t/* termux-durability-guard */\n"
    "\t\tif (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"ENOENT\") return;\n"
    "\t\tthrow error;\n"
    "\t}",
)

# (b) Publication uses link(), which Android refuses (EACCES); rename() inside
#     the same private root is equally atomic. (c) rename() consumes the
#     staging name, so the follow-up unlink() must tolerate ENOENT.
helpers = (
    "/**\n"
    " * Publish one staged object into place.\n"
    " * POSIX links are the cheapest atomic publish, but Android refuses link()\n"
    " * for untrusted apps (EACCES: no hard links). rename() inside the same\n"
    " * private root is equally atomic, so fall back to it. rename() replaces an\n"
    " * existing target instead of raising EEXIST, which is safe here because\n"
    " * targets are content-addressed: an object already at `target` holds the\n"
    " * same digest as the bytes being published.\n"
    " */\n"
    "/* termux-hardlink-fallback */\n"
    "async function publishStagedName(source, target) {\n"
    "\ttry {\n"
    "\t\tawait link(source, target);\n"
    "\t} catch (error) {\n"
    "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
    "\t\tawait rename(source, target);\n"
    "\t}\n"
    "}\n"
    "/** Remove a staging name, tolerating one already consumed by the rename fallback. */\n"
    "async function removeStagedName(path) {\n"
    "\ttry {\n"
    "\t\tawait unlink(path);\n"
    "\t} catch (error) {\n"
    "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"ENOENT\")) throw error;\n"
    "\t}\n"
    "}\n"
    "async function publishStagedObject(root, target, staged) {"
)
once("async function publishStagedObject(root, target, staged) {", helpers)
once("\t\t\tawait link(staged.path, target);", "\t\t\tawait publishStagedName(staged.path, target);")
once("\t\t\tawait link(source, target);", "\t\t\tawait publishStagedName(source, target);")
assert src.count("\t\tawait unlink(staged.path);") == 1, "staging unlink anchor not found"
src = src.replace("\t\tawait unlink(staged.path);", "\t\tawait removeStagedName(staged.path);")

open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
fi

log 7 9 "Fixing shebang (node --expose-internals)..."
DSH_BIN="$DSH_LIB/lib/bin.js"
if [ -f "$DSH_BIN" ]; then
    python3 - "$DSH_BIN" "$NODE_BIN" <<'PY'
import sys
path, node = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
first, _, rest = src.partition("\n")
if not first.startswith("#!"):
    sys.exit("no shebang on first line")
src = "#!" + node + " --expose-internals\n" + rest
open(path, "w", encoding="utf-8").write(src)
print("    shebang set:", node, "--expose-internals")
PY
fi

log 8 9 "Patching file publication (hard link -> rename fallback)..."
FS_LOCAL_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
if [ ! -f "$FS_LOCAL_JS" ]; then
    echo "    warning: fs-local module not found, skipping (write/edit tools will not work)."
elif grep -q "termux-noreplace-fallback" "$FS_LOCAL_JS"; then
    echo "    file publication already patched, skipping."
else
    python3 - "$FS_LOCAL_JS" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "termux-noreplace-fallback" in src:
    print("    already patched")
    sys.exit(0)

old = (
    "\t\tif (createIfAbsent !== void 0) try {\n"
    "\t\t\tawait linkFile(tempPath, absolutePath);\n"
    "\t\t} catch (error) {\n"
    "\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);\n"
    "\t\t}"
)
assert src.count(old) == 1, "patch anchor not found (%d matches); dsh may have changed" % src.count(old)
new = (
    "\t\tif (createIfAbsent !== void 0) try {\n"
    "\t\t\ttry {\n"
    "\t\t\t\tawait linkFile(tempPath, absolutePath);\n"
    "\t\t\t} catch (error) {\n"
    "\t\t\t\t/* termux-noreplace-fallback */\n"
    "\t\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
    "\t\t\t\tawait rename(tempPath, absolutePath);\n"
    "\t\t\t}\n"
    "\t\t} catch (error) {\n"
    "\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);\n"
    "\t\t}"
)
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
print("    patched", path)
PY
fi

log 9 9 "Setting DeepSeek API key..."
PERSIST_KEY=""
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    echo "    DEEPSEEK_API_KEY already set in environment, using it."
    PERSIST_KEY="$DEEPSEEK_API_KEY"
else
    printf '    Paste your DeepSeek API key (input hidden): '
    IFS= read -r -s PERSIST_KEY || true
    echo
    if [ -n "$PERSIST_KEY" ]; then
        echo "    Key captured (not echoed)."
        export DEEPSEEK_API_KEY="$PERSIST_KEY"
    else
        # No input: fall back to scanning for an existing key.
        if PERSIST_KEY="$(find_deepseek_key)"; then
            echo "    Found existing DeepSeek API key, using it."
            export DEEPSEEK_API_KEY="$PERSIST_KEY"
        else
            echo "    No key provided; set it later with: export DEEPSEEK_API_KEY=sk-..."
        fi
    fi
fi
if [ -n "${PERSIST_KEY:-}" ]; then
    RC="$HOME/.bashrc"
    touch "$RC"
    grep -v '^export DEEPSEEK_API_KEY=' "$RC" > "$RC.tmp" 2>/dev/null || true
    printf "export DEEPSEEK_API_KEY='%s'\n" "$PERSIST_KEY" >> "$RC.tmp"
    mv "$RC.tmp" "$RC"
    echo "    Saved DEEPSEEK_API_KEY to $RC"
fi

printf '\n\033[1;32mDone.\033[0m Verify with:\n  dsh --version\n  dsh web\n'
printf 'For headless/web you will need a DeepSeek API key (export DEEPSEEK_API_KEY or set it in the web UI).\n'
