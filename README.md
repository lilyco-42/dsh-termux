# dsh-termux

One-command installer for [DeepSeek's `@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) CLI on **Termux (Android)**, including the runtime patches needed to actually run it.

## Why this exists

`npm install -g @deepseek-ai/dsh` installs but does not run on Termux. Five
independent incompatibilities have to be fixed:

| # | Package / feature | Problem | Fix |
|---|---|---|---|
| 1 | `node-pty` | node-gyp copies `process.config.variables.OS = "android"` into `config.gypi`, making gyp reference the undefined `android_ndk_path`. | Patch node-gyp to drop the `OS` variable so gyp infers `linux`. |
| 2 | `koffi` | `base.cc` calls `statx()`, hidden by bionic below API 30; clang targets `android24`. | Compile with `--target=aarch64-unknown-linux-android30`. |
| 3 | `sharp` | No prebuilt binding for `android-arm64`. | Install system `libvips` and build sharp against it. |
| 4 | HMR service | `cordis-plugin-hmr` needs Node `--expose-internals`; `node-addon-require-builtin` has no android prebuild. | Rewrite the `dsh` shebang to `node --expose-internals`. |
| 5 | `session-persistence-jsonl` | Publishes logs with a hard `link()`, forbidden on Android (`EACCES`). | Switch the atomic publish to `rename()`. |

## Install

```bash
pkg install -y git
git clone https://github.com/lilyco-42/dsh-termux.git
cd dsh-termux
bash install.sh
```

Or a single command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lilyco-42/dsh-termux/main/install.sh)
```

## Verify

```bash
dsh --version
dsh web            # serves the browser UI
dsh --profile headless "hello"   # one task, prints result, exits
```

You need a DeepSeek API key (`export DEEPSEEK_API_KEY=...`, or set it in the
web UI's Models page).

## Requirements

- Termux (the script installs everything else via `pkg`).
- Android 11 (API 30) or newer — required at runtime because `koffi` is built
  against API 30 (`statx`).

## What the script does

1. Installs `nodejs`, `build-essential`, `clang`, `cmake`, `ninja`, `python`, `libvips`.
2. Patches node-gyp's `create-config-gypi.js` (idempotent).
3. Installs `@deepseek-ai/dsh` globally with `CFLAGS`/`CXXFLAGS` targeting `android30`.
4. Builds `sharp` against the system `libvips`.
5. Patches `session-persistence-jsonl` to use `rename()` instead of `link()`.
6. Rewrites the `dsh` shebang to `node --expose-internals`.

All post-install patches are idempotent, so re-running `install.sh` is safe.
