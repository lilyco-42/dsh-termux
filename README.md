# dsh-termux

One-command installer for [DeepSeek's `@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) CLI on **Termux (Android)**.

## Why this exists

`npm install -g @deepseek-ai/dsh` fails on Termux because two of its native
dependencies can't compile:

| Package | Problem | Fix |
|---------|---------|-----|
| `node-pty` | node-gyp copies `process.config.variables.OS = "android"` into `config.gypi`, making gyp reference the undefined `android_ndk_path` variable. | Patch node-gyp to drop the `OS` variable so gyp infers `linux`. |
| `koffi` | `src/.../base.cc` calls `statx()`, which bionic hides below Android API 30; Termux's clang targets `android24`. | Raise the compile target to `aarch64-unknown-linux-android30` (safe on API 30+ devices). |

## Install

```bash
pkg install -y git
git clone https://github.com/lilyco-42/dsh-termux.git
cd dsh-termux
bash install.sh
```

Or, directly from a single command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lilyco-42/dsh-termux/main/install.sh)
```

## Verify

```bash
dsh --version
```

## Requirements

- Termux (with `pkg`). The script installs everything else itself.
- Android 11 (API 30) or newer — required at runtime because `koffi` is
  compiled against API 30 (`statx`).

## What the script does

1. Installs `nodejs`, `build-essential`, `clang`, `cmake`, `ninja`, `python`.
2. Patches node-gyp's `create-config-gypi.js` (idempotent) to remove the bogus
   `OS=android` variable.
3. Installs `@deepseek-ai/dsh` globally with `CFLAGS`/`CXXFLAGS` targeting
   `android30`.
4. Runs `termux-fix-shebang` on the `dsh` entry point so `#!/usr/bin/env` works.
