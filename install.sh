#!/data/data/com.termux/files/usr/bin/bash
# Install @deepseek-ai/dsh on Termux (Android).
#
# dsh has two native dependencies (node-pty and koffi) whose build is broken
# on Termux:
#   1. node-pty: node-gyp copies process.config.variables.OS ("android") into
#      config.gypi, which makes gyp reference the undefined android_ndk_path.
#   2. koffi: calls statx(), hidden by bionic below Android API 30, while
#      Termux's clang targets android24.
#
# This script patches node-gyp and raises the compile target to android30,
# then installs dsh and fixes its shebang.

set -euo pipefail

NDK_TARGET="aarch64-unknown-linux-android30"

log() { printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "$3"; }

log 1 4 "Installing prerequisites (nodejs, toolchain, cmake/ninja, python)..."
pkg install -y nodejs build-essential clang cmake ninja python >/dev/null

log 2 4 "Patching node-gyp to drop the bogus OS=android variable..."
NODE_GYP_LIB="$(npm root -g)/npm/node_modules/node-gyp/lib"
CREATE_GYPI="$NODE_GYP_LIB/create-config-gypi.js"
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
with open(path, encoding="utf-8") as f:
    src = f.read()

anchor = "const variables = config.variables\n"
assert anchor in src, "patch anchor not found; node-gyp may have changed"

block = (
    anchor
    + "\n"
    + "  // Termux's Node.js reports process.config.variables.OS as \"android\" even\n"
    + "  // though native addons are built against the Termux (linux-like) sysroot\n"
    + "  // and not the Android NDK. gyp's \"OS == android\" branches then reference\n"
    + "  // the undefined android_ndk_path variable and fail. Drop OS so gyp infers\n"
    + "  // it as \"linux\" from the host platform.\n"
    + "  delete variables.OS\n"
)

with open(path, "w", encoding="utf-8") as f:
    f.write(src.replace(anchor, block, 1))
print("    patched", path)
PY
fi

log 3 4 "Installing @deepseek-ai/dsh (native modules will be compiled)..."
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
npm install -g @deepseek-ai/dsh

log 4 4 "Fixing shebang for Termux..."
DSH_BIN="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
if [ -f "$DSH_BIN" ]; then
    termux-fix-shebang "$DSH_BIN"
fi

printf '\n\033[1;32mDone.\033[0m Verify with:  dsh --version\n'
