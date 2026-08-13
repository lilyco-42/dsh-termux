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

set -euo pipefail

NDK_TARGET="aarch64-unknown-linux-android30"
NODE_BIN="$(command -v node)"
NODE_GYP_BIN="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"

log() { printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "$3"; }

log 1 6 "Installing prerequisites..."
pkg install -y nodejs build-essential clang cmake ninja python libvips >/dev/null

log 2 6 "Patching node-gyp (drop bogus OS=android)..."
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

log 3 6 "Installing @deepseek-ai/dsh (native modules will be compiled)..."
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
npm install -g @deepseek-ai/dsh

log 4 6 "Building sharp against system libvips..."
SHARP_DIR="$DSH_LIB/node_modules/sharp"
if [ -f "$SHARP_DIR/src/build/Release/sharp-android-arm64-"*.node ]; then
    echo "    sharp already built, skipping."
else
    (cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=1 \
        CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
        "$NODE_BIN" "$NODE_GYP_BIN" rebuild --directory=src >/dev/null)
fi

log 5 6 "Patching session persistence (hard link -> rename)..."
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

log 6 6 "Fixing shebang (node --expose-internals)..."
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

printf '\n\033[1;32mDone.\033[0m Verify with:\n  dsh --version\n  dsh web\n'
printf 'For headless/web you will need a DeepSeek API key (export DEEPSEEK_API_KEY or set it in the web UI).\n'
