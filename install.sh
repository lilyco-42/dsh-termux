#!/data/data/com.termux/files/usr/bin/bash
# dsh-termux-installer
# 在Termux上一键安装DeepSeek Harness (@deepseek-ai/dsh)
# 涵盖pkg更新 | 基础工具/编译链/Node | npm配置与镜像 | common.gypi补丁
#       dsh原生模块源码编译安装| require-builtin JS垫片 | sharp wasm兜底 | 启动包装器
#       sdcard存储授权与默认工作区
#
# 已修复的关键问题：
#   - koffi / node-pty无android预编译，需现场编译
#   - Termux clang默认target API 24，statx()需 API >= 30（-target ...android30）
#   - node-gyp在 ermux上报android_ndk_path未定义（common.gypi 补丁）
#   - npm install-scripts安全门跳过构建脚本（allow-scripts 放行）
#   - sharp 无android-arm64预编译（@img/sharp-wasm32 WebAssembly 兜底）
#   - HMR 插件硬要求--expose-internals（dsh 启动包装器）
#   - node-addon-require-builtin无android-arm64预编译（--expose-internals + JS 垫片）
#
# 用法： bash install.sh [--skip-upgrade] [--cn]
#        --cn            使用 npmmirror 镜像源（大陆内推荐）
# 环境： Termux（F-Droid），Android11+，arm64/ armv7

set -euo pipefail
echo "Ciallo～ (∠・ω< )⌒★"

echo "正在异常退出后的清理临时目录=w="
SWDIR="$HOME/.dsh-termux-sw"
trap 'rm -rf "$SWDIR"' EXIT

START_TS="$(date +%s)"

SKIP_UPGRADE=0
CN_MODE=0
for arg in "$@"; do
  case "$arg" in
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --cn) CN_MODE=1 ;;
    -h|--help) sed -n '1,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数！(´｀;)? : $arg（可用 --skip-upgrade / --cn）"; exit 1 ;;
  esac
done

log()  {
  if [ $# -ge 3 ]; then
    printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "${@:3}"
  else
    printf '\033[1;36m==> %s\033[0m\n' "$*"
  fi
}

# Auto-scan for a DeepSeek API key across common sources, print the first
# match. Priority: environment, dsh credential store, shell rc files, key files.
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
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; }

monitor_pid=""
mon_seq=0
DSH_TOTAL=${DSH_TOTAL:-0}

cutc() {
  local s="$1" n="$2"
  if [ ${#s} -gt "$n" ]; then printf '%s' "${s:0:n}"; else printf '%s' "$s"; fi
}

pkg_name_from_log() {
  local f="$1" n
  n="$(tail -n 30 "$f" 2>/dev/null | grep -oE '[^/ ]+\.tgz' | tail -n 1)" || n=""
  if [ -z "$n" ]; then
    n="$(tail -n 30 "$f" 2>/dev/null | grep -a 'http fetch GET 200' | awk '{print $6}' | tail -n 1)" || n=""
    n="${n##*/}"
  fi
  n="${n%.tgz}"
  n="$(printf '%s' "$n" | sed -E 's/-[0-9][0-9A-Za-z.+-]*$//' 2>/dev/null)" || n=""
  printf '%s' "$n"
}

panel_draw() {
  local phase="$1" start="$2" logf="$3"
  local el done_cnt total pct name bar fill i j tgz meta
  el=$(( $(date +%s) - start ))
  total=0
  case "$phase" in *dsh*) total="$DSH_TOTAL" ;; esac
  done_cnt=0
  if [ "$total" -gt 0 ] 2>/dev/null; then
    tgz=$(grep -ac 'http fetch GET 200 .*\.tgz' "$logf" 2>/dev/null) || tgz=0
    [ -n "$tgz" ] || tgz=0
    meta=$(grep -a 'http fetch GET 200' "$logf" 2>/dev/null | grep -av '\.tgz' | awk '{print $6}' | sort -u | wc -l) || meta=0
    [ -n "$meta" ] || meta=0
    if [ "$tgz" -gt 0 ]; then done_cnt="$tgz"; else done_cnt="$meta"; fi
  fi
  if [ "$total" -gt 0 ] 2>/dev/null && [ "$done_cnt" -gt 0 ]; then
    pct=$(( done_cnt * 100 / total )); [ "$pct" -le 100 ] || pct=100
  else
    pct=-1
  fi
  name="$(pkg_name_from_log "$logf")"
  [ -n "$name" ] || name="$phase"
  name="$(cutc "$name" 12)"
  bar=""
  if [ "$pct" -ge 0 ]; then
    fill=$(( pct * 12 / 100 ))
    i=0
    while [ "$i" -lt 12 ]; do
      if [ "$i" -lt "$fill" ]; then bar="$bar#"; else bar="$bar-"; fi
      i=$((i + 1))
    done
    printf '\r\033[K%s:%s %3d%%' "$name" "$bar" "$pct"
  else
    i=$(( (el * 2) % 12 ))
    j=0
    while [ "$j" -lt 12 ]; do
      if [ "$j" -ge "$i" ] && [ "$j" -lt $((i + 3)) ]; then bar="$bar#"; else bar="$bar-"; fi
      j=$((j + 1))
    done
    printf '\r\033[K%s:%s 进行中' "$name" "$bar"
  fi
}

monitor_start() {
  monitor_phase="$1"; monitor_log="$2"; monitor_ts="$(date +%s)"
  ( while :; do panel_draw "$monitor_phase" "$monitor_ts" "$monitor_log" || true; sleep 1; done ) &
  monitor_pid=$!
}

monitor_stop() {
  if [ -n "$monitor_pid" ]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  monitor_pid=""
  printf '\r\033[K'
}

run_monitored() {
  local phase="$1"; shift
  local rc logf
  mon_seq=$((mon_seq + 1))
  mkdir -p "$SWDIR" 2>/dev/null || true
  logf="$(mktemp "$SWDIR/dsh-mon.XXXXXX" 2>/dev/null)" || logf="$SWDIR/dsh-mon.$$.$mon_seq"
  : > "$logf" 2>/dev/null || true
  monitor_start "$phase" "$logf"
  "$@" >>"$logf" 2>&1
  rc=$?
  monitor_stop
  if [ "$rc" -ne 0 ]; then
    warn "「$phase」失败（退出码 $rc），最后20行输出TwT"
    tail -n 20 "$logf" 2>/dev/null || true
  else
    ok "「$phase」完成"
  fi
  rm -f "$logf" 2>/dev/null || true
  return "$rc"
}

echo "环境预检ing (。ヘ°)？"
if [ -z "${PREFIX:-}" ]; then
  echo "错误！(>囗＜?): 未检测到Termux环境（\$PREFIX 为空）。请在手机Termux里运行本脚本。"
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64)              TARGET="aarch64-linux-android30";;
  armv7l|armv8l)        TARGET="armv7a-linux-androideabi30";;
  x86_64)               TARGET="x86_64-linux-android30";;
  i686)                 TARGET="i686-linux-android30";;
  *)
    warn "未知架构！?(*´･д･)ﾉ $ARCH，按arm64处理，如编译失败请提交issue"
    TARGET="aarch64-linux-android30" ;;
esac
log 1 9 "架构: $ARCH   编译目标: $TARGET"

echo "构建很耗时捏，尽量保持屏幕常亮(-w-)"
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock
fi

echo "1. 系统更新与编译工具链 Ciallo～ (∠・ω< )⌒★"
if [ "$SKIP_UPGRADE" -eq 0 ]; then
  log "pkg update && pkg upgrade（首次运行较久，务必等它完成！TwT）"
  run_monitored "pkg update" pkg update -y
  run_monitored "pkg upgrade" pkg upgrade -y
else
  warn "环境为最新状态～(=･ω･=)～已跳过pkg update/upgrade"
fi

log 2 9 "安装基础工具与编译工具链: git curl cmake clang make python binutils pkg-config libandroid-spawn termux-tools"
run_monitored "安装编译工具链" pkg install -y git curl cmake clang make python binutils pkg-config libandroid-spawn termux-tools

echo "2. Node.js>=22.12（dsh依赖commander15的硬性要求）(˶ᵔ ᵕ ᵔ˶)"
if ! command -v node >/dev/null 2>&1; then
  log "安装nodejs"
  run_monitored "安装nodejs" pkg install -y nodejs
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
NODE_MINOR="$(node -p 'process.versions.node.split(".")[1]')"
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 12 ]; }; then
  echo "错误！T-T: dsh需要Node >= 22.12，当前是 $(node -v)。请先执行pkg upgrade -y && pkg install nodejs再重跑install.sh"
  exit 1
fi
ok "Node $(node -v)"

echo "3. npm镜像与install-scripts放行"
echo "Ciallo～ (∠・ω<)⌒★"

ALLOW_LIST="@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs,pnpm"
log 3 9 "配置 npm 镜像与 install-scripts 放行"
if npm config set allow-scripts="$ALLOW_LIST" --location=user 2>/dev/null; then
  ok "npm install-scripts 已放行（新npm安全门）"
else
  warn "当前npm不支持 allow-scripts（较旧版本）——旧npm默认会执行构建脚本，可忽略此警告"
fi

if [ "$CN_MODE" -eq 1 ]; then
  log "使用npmmirror 镜像源（--cn）"
  npm config set registry https://registry.npmmirror.com --location=user
  warn "如果pkg更新源也慢/失败，可运行termux-change-repo选择国内镜像(>囗＜?)"
fi

echo "加大npm下载超时与重试(。ヘ°)"
npm config set fetch-retries 5 --location=user 2>/dev/null || true
npm config set fetch-retry-mintimeout 20000 --location=user 2>/dev/null || true
npm config set fetch-retry-maxtimeout 120000 --location=user 2>/dev/null || true
npm config set fetch-timeout 300000 --location=user 2>/dev/null || true

echo "Ciallo～ (∠・ω< )⌒★"
echo "4. node-gyp common.gypi 补丁（android_ndk_path）"

log 4 9 "预下载 Node 头文件并修补 common.gypi"
NODE_GYP="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
if [ -f "$NODE_GYP" ]; then
  run_monitored "node-gyp预下载" node "$NODE_GYP" install || warn "node-gyp头文件预下载失败（安装过程会自动重试）"
fi

patch_common_gypi() {
  local patched=0
  local f
  for f in "$HOME"/.cache/node-gyp/*/include/node/common.gypi; do
    [ -f "$f" ] || continue
    if grep -q "android_ndk_path%'" "$f"; then
      patched=1
      continue
    fi
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index("'variables': {") + len("'variables': {")
s = s[:i] + "\n    'android_ndk_path%': ''," + s[i:]
open(p, "w").write(s)
PY
    ok "已修补 $f"
    patched=1
  done
  if [ "$patched" -eq 0 ]; then
    warn "未找到node-gyp缓存(ΩДΩ)！若安装时node-pty报 android_ndk_path，重跑本脚本即可"
  fi
  return 0
}
patch_common_gypi

echo "Ciallo～ (∠・ω< )⌒★"
echo "5. 全局安装 @deepseek-ai/dsh"

if [ "$CN_MODE" -eq 0 ]; then
  if ! curl -fsS --max-time 8 -o /dev/null https://registry.npmjs.org/-/ping 2>/dev/null; then
    warn "registry.npmjs.org 连接超时 → 自动切换 npmmirror 镜像源"
    npm config set registry https://registry.npmmirror.com --location=user
  fi
fi

log 5 9 "安装 @deepseek-ai/dsh（最耗时：原生模块编译，约 5~15 分钟）"
log "下载阶段可能长时间无输出，属正常，请保持屏幕常亮，不要关闭Termux"
export CFLAGS="-target $TARGET"
export CXXFLAGS="-target $TARGET"

export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"

TOTAL_CACHE="$HOME/.dsh-termux-npm-total"
DSH_TOTAL=0
if [ -f "$TOTAL_CACHE" ]; then DSH_TOTAL="$(cat "$TOTAL_CACHE" 2>/dev/null || true)"; fi
case "$DSH_TOTAL" in ''|*[!0-9]*) DSH_TOTAL=0 ;; esac
if [ "$DSH_TOTAL" -le 0 ]; then
  echo "首次统计依赖包数量用于下载百分比，约1~2分钟TwT"
  mkdir -p "$SWDIR"
  rm -f "$SWDIR/dry.json"
  run_monitored "统计依赖包数量" sh -c "npm install -g --dry-run --json --no-audit --no-fund @deepseek-ai/dsh > '$SWDIR/dry.json' 2>&1" || true
  DSH_TOTAL="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("add") or []) + len(json.load(open(sys.argv[1])).get("change") or []))' "$SWDIR/dry.json" 2>/dev/null)" || DSH_TOTAL=0
  case "$DSH_TOTAL" in ''|*[!0-9]*) DSH_TOTAL=0 ;; esac
  if [ "$DSH_TOTAL" -gt 0 ]; then printf '%s\n' "$DSH_TOTAL" > "$TOTAL_CACHE"; fi
fi
export DSH_TOTAL

if ! run_monitored "安装dsh（下载+编译）" npm install -g --foreground-scripts --loglevel=http --no-audit --no-fund @deepseek-ai/dsh; then
  warn "首次安装失败，修补common.gypi后重试一次"
  patch_common_gypi
  if [ "$CN_MODE" -eq 0 ]; then
    warn "仍失败则自动切换npmmirror镜像源再试（中国大陆网络常见）"
    npm config set registry https://registry.npmmirror.com --location=user || true
  fi
  run_monitored "安装dsh（重试）" npm install -g --foreground-scripts --loglevel=http --no-audit --no-fund @deepseek-ai/dsh
fi
unset CFLAGS CXXFLAGS CMAKE_BUILD_PARALLEL_LEVEL

echo "检查dsh命令ing......"

if ! command -v dsh >/dev/null 2>&1; then
  echo ""
  echo "✗✗ 错误: npm安装结束后仍未找到dsh命令✗✗"
  echo "   说明上面npm install实际失败了（常见原因）："
  echo "   1) Network timeout 安装阶段长时间（>15分钟）无任何输出 用 --cn 参数重跑，或确认VPN/代理"
  echo '   2) 进程被杀 手机内存不足（OOM）或Termux被系统回收，请杀掉后台重新执行install.sh，在电源管理中将Termux设置为"无限制"'
  echo "   3) 磁盘空间不足 请检查有足够的存储空间"
  echo "   4) 编译失败 向上翻终端找\"npm error\" 开头的行，把最后20行提交至到仓库issue"
  echo "   5) 本脚本幂等，任何一步失败直接重跑即可续上"
  exit 1
fi
ok "dsh 命令已就位: $(command -v dsh)"

D="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
[ -d "$D" ] || { echo "错误: 安装完成后未找到 $D"; exit 1; }

# ---- 5.5 link() > rename() 补丁（部分定制ROM全局禁用link()系统调用）---------
# 症状：会话保存报EACCES: permission denied, link '...session.jsonl.zstd.tmp' >'...'
# 方案来自upstream discussion #248：把dsh-session-persistence-jsonl与
# dsh-attachment-local里的原子发布从link()改为rename()（rename同目录原子且
# 在所有ROM上都可用）
# 幂等：已修补则跳过
patch_link_rename() {
  local f patched=0

  f="$D/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
  if [ -f "$f" ]; then
    if grep -q "await rename(tmp, finalPath)" "$f"; then
      patched=1
    elif grep -q "await link(tmp, finalPath)" "$f"; then
      python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
)
s = s.replace("await link(tmp, finalPath);", "await rename(tmp, finalPath);")
open(p, "w").write(s)
PY
      ok "已修补 $f（link -> rename）"
      patched=1
    fi
  fi

  f="$D/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js"
  if [ -f "$f" ]; then
    if grep -q "await rename(temporary, target)" "$f"; then
      patched=1
    elif grep -q "await link(temporary, target)" "$f"; then
      python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import { chmod, link, mkdir, open, readFile, unlink } from "node:fs/promises";',
    'import { chmod, link, mkdir, open, readFile, rename, unlink } from "node:fs/promises";',
)
s = s.replace("await link(temporary, target);", "await rename(temporary, target);")
# rename后staging文件已不存在，必须容忍unlink的ENOENT（仅修改saveImageFile内）
old = "await unlink(temporary);"
new = ('await unlink(temporary).catch((cleanupError) => {\n'
       '\t\t\tif (!(cleanupError instanceof Error && "code" in cleanupError && cleanupError.code === "ENOENT")) throw cleanupError;\n'
       '\t\t});')
idx = s.find(old)
if idx != -1:
    s = s[:idx] + new + s[idx + len(old):]
open(p, "w").write(s)
PY
      ok "已修补 $f（link -> rename）"
      patched=1
    fi
  fi

  [ "$patched" -eq 0 ] && warn "link() 补丁未命中（包结构可能已变化，遇到 EACCES link 报错请发 issue）"
  return 0
}
patch_link_rename

# ---- 5.6 node-addon-require-builtin JS垫片（Android无预编译原生二进制）---------
# 症状：dsh web启动报
#   Cannot find module '.../node-addon-require-builtin/build/napi/napi-v9-android-arm64/require_builtin.node'
# 原因：node-addon-require-builtin@0.1.x 没有 android-arm64 预编译产物，且其JS兜底
#       （node-addon-native-custom-loader）仍会强制加载该原生二进制
#       但启动包装器已强制--expose-internals，该flag下require('internal/...')
#       可直接解析 Node 内部模块，故用纯 JS 垫片等价顶替，无需现场编译
# 幂等：文件已含"js-fallback"标记则跳过，首次写入前备份为 *.orig.bak
patch_require_builtin_shim() {
  local f="$D/node_modules/node-addon-require-builtin/lib/index.js"
  [ -f "$f" ] || { warn "未找到node-addon-require-builtin，跳过JS垫片"; return 0; }
  if grep -q "js-fallback" "$f"; then
    ok "node-addon-require-builtin JS 垫片已存在"
    return 0
  fi
  cp -p "$f" "$f.orig.bak"
  cat > "$f" <<'SHIM_EOF'
"use strict";
// JS fallback for node-addon-require-builtin on platforms without a prebuilt
// native binding (Android/Termux). Under Node --expose-internals, require()
// resolves Node's internal builtin modules directly, so this shim provides the
// same API without the native require_builtin.node.
function requireBuiltin(moduleId) { return require(moduleId); }
function isAllowedInternalId(moduleId) { return true; }
function getBindingInfo() {
  return { mode: 'js-fallback', product: 'require-builtin', backend: 'js',
           abi: 'expose-internals', bindingPath: null, bindingSource: 'js-fallback' };
}
exports.requireBuiltin = requireBuiltin;
exports.isAllowedInternalId = isAllowedInternalId;
exports.getBindingInfo = getBindingInfo;
exports.default = { requireBuiltin, isAllowedInternalId, getBindingInfo };
SHIM_EOF
  ok "已写入node-addon-require-builtin JS垫片"
}
patch_require_builtin_shim


# ---- 5.7 Android上flock原生绑定缺失的兜底（会话持久化要用）(˶ᵔ ᵕ ᵔ˶)------
# 症状：dsh web里跑任务报flock不支持Android-arm64，会话写盘失败
# 原因：@deepseek-ai/node-addon-system只预编译darwin与linux，android-arm64没有绑定，
#       flock.js遇到非linux/darwin平台直接抛ERR_FLOCK_UNSUPPORTED_PLATFORM
# 处理：用锁文件加pid存活检测的纯JS兜底，保留"会话已被占用"的判定，幂等
patch_android_flock() {
  local f="$D/node_modules/@deepseek-ai/node-addon-system/lib/flock.js"
  [ -f "$f" ] || { warn "未找到node-addon-system，跳过flock兜底"; return 0; }
  if grep -q "android-flock-fallback" "$f"; then
    ok "flock Android兜底已存在"
    return 0
  fi
  cp -p "$f" "$f.orig.bak"
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "android-flock-fallback" in s:
    print("    already patched")
    sys.exit(0)
old = "import { getSystemErrorName } from 'node:util';"
if old in s:
    s = s.replace(old, old + "\nimport { readlink, stat, open, readFile, unlink } from 'node:fs/promises';", 1)
helper = '''/* android-flock-fallback: Android没有预编译绑定，改用锁文件加pid存活检测兜底 */
async function androidTryLock(fd) {
    let target;
    try {
        target = await readlink('/proc/self/fd/' + fd);
    } catch {
        return;
    }
    const lockPath = target + '.flock';
    const takeLock = async () => {
        const fh = await open(lockPath, 'wx');
        await fh.writeFile(String(process.pid));
        await fh.close();
    };
    try {
        await takeLock();
        return;
    } catch (error) {
        if (error?.code !== 'EEXIST') return;
    }
    let owner = '';
    try { owner = (await readFile(lockPath, 'utf8')).trim(); } catch {}
    const pid = Number.parseInt(owner, 10);
    if (Number.isInteger(pid) && pid > 0 && pid !== process.pid) {
        let alive = false;
        try { await stat('/proc/' + pid); alive = true; } catch {}
        if (alive) {
            throw Object.assign(new Error('EAGAIN: flock failed'), { code: 'EAGAIN', errno: 11, syscall: 'flock' });
        }
        await unlink(lockPath).catch(() => {});
        try { await takeLock(); } catch {}
    }
}

export async function tryLockExclusive(fd) {
    if (process.platform === 'android') {
        await androidTryLock(fd);
        return;
    }'''
anchor = "export async function tryLockExclusive(fd) {"
if anchor not in s:
    print("    anchor not found, skip")
    sys.exit(0)
s = s.replace(anchor, helper, 1)
open(p, "w").write(s)
print("    patched", p)
PY
  ok "已写入flock Android兜底"
}
patch_android_flock

# ---- 5.8 补rename导入（link改rename后import漏项会报rename未定义）(˶ᵔ ᵕ ᵔ˶)------
# 症状：运行时报rename未定义
# 原因：某些版本的import行与补丁预期不一致，调用被改成rename()但没把rename加进import
# 处理：扫三个用到的包，只要出现rename(调用而import里没有rename就补上，幂等
patch_rename_import() {
  local f
  for f in \
    "$D/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" \
    "$D/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js" \
    "$D/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if 'rename(' not in s:
    sys.exit(0)
m = re.search(r'import \{([^}]*)\} from "node:fs/promises";', s)
if not m:
    print('    no fs/promises import, skip', p)
    sys.exit(0)
names = m.group(1)
if re.search(r'\brename\b', names):
    sys.exit(0)
fixed = 'import {' + names.rstrip() + ', rename } from "node:fs/promises";'
s = s.replace(m.group(0), fixed, 1)
open(p, 'w').write(s)
print('    added rename to', p)
PY
  done
}
patch_rename_import
echo "Ciallo～ (∠・ω< )⌒★"
echo "6. sharp WebAssembly兜底"
SHARP_VER="$(python3 -c "import json;print(json.load(open('$D/node_modules/sharp/package.json'))['version'])")"
if [ -z "$SHARP_VER" ]; then
  fail "读取sharp版本失败（$D/node_modules/sharp/package.json 不存在？）"
  exit 1
fi
log 6 9 "安装 sharp@$SHARP_VER 的 WebAssembly 兜底"

# 注意！@img/sharp-wasm32包内没有名为sharp.node的文件，顶层"./sharp.node"是
# exports映射到index.cjs的虚拟入口，真实产物是lib/sharp-wasm32-<ver>.node.{js,wasm}，
# 所以用包目录 + lib/*.wasm判断是否就位
wasm_present() { [ -d "$1" ] && ls "$1"/lib/*.wasm >/dev/null 2>&1; }

if wasm_present "$D/node_modules/@img/sharp-wasm32"; then
  ok "@img/sharp-wasm32已存在，skip"
else
  rm -rf "$SWDIR"                 # 清掉上次失败可能留下的残留
  mkdir -p "$SWDIR"
  cd "$SWDIR" || { fail "无法进入 $SWDIR"; exit 1; }
  npm init -y >/dev/null 2>&1 || true   # 失败无所谓，npm install不需要package.json
  log "下载@img/sharp-wasm32@$SHARP_VER ..."
  if ! run_monitored "npm下载sharp-wasm32" npm install --no-save --no-audit --no-fund "@img/sharp-wasm32@$SHARP_VER"; then
    warn "官方源安装失败，改用npmmirror重试"
    if ! run_monitored "sharp-wasm32镜像" npm install --no-save --no-audit --no-fund --registry=https://registry.npmmirror.com "@img/sharp-wasm32@$SHARP_VER"; then
      fail "@img/sharp-wasm32下载/安装失败（见上方输出）请检查网络后重跑本脚本"
      exit 1
    fi
  fi
  if ! wasm_present node_modules/@img/sharp-wasm32; then
    fail "sharp-wasm32安装结果异常（未找到lib/*.wasm）"
    exit 1
  fi
  rm -rf "$D/node_modules/@img/sharp-wasm32" "$D/node_modules/@emnapi"
  mkdir -p "$D/node_modules/@img"
  cp -r node_modules/@img/sharp-wasm32 "$D/node_modules/@img/"
  if [ -d node_modules/@emnapi ]; then
    cp -r node_modules/@emnapi "$D/node_modules/"
  fi
  cd "$HOME" || exit 1
  rm -rf "$SWDIR"
  if ! wasm_present "$D/node_modules/@img/sharp-wasm32"; then
    fail "sharp-wasm32复制到dsh失败"
    exit 1
  fi
  ok "sharp wasm兜底已就位"
fi

echo "Ciallo～ (∠・ω< )⌒★"
echo "7. dsh 启动包装器（HMR插件硬要求--expose-internals）"
log 7 9 "安装 dsh 启动包装器（--expose-internals）"
rm -f "$PREFIX/bin/dsh"
cat > "$PREFIX/bin/dsh" <<EOF
#!$PREFIX/bin/sh
exec node --expose-internals $D/lib/bin.js "\$@"
EOF
chmod +x "$PREFIX/bin/dsh"
ok "包装器已写入 $PREFIX/bin/dsh"

echo "安装开始！Ciallo～ (∠・ω< )⌒★"
echo "8. pnpm（dsh plugin子命令依赖）"
log 8 9 "安装 pnpm（dsh plugin 依赖）"
if ! command -v pnpm >/dev/null 2>&1; then
  run_monitored "npm安装pnpm" npm install -g --no-audit --no-fund pnpm
fi

# ---- 8.5 sdcard存储权限 + 默认工作区（Android 11+ 作用域存储）------------------
# 网页版无法读sdcard通常有两层原因：
#   1) Termux应用没有存储权限 > termux-setup-storage授权并生成 ~/storage/shared
#   2) dsh默认工作区是启动目录 > 在cordis.patch.yml里把fs-sandbox.cwd
#      固定到sdcard，浏览器UI的文件树/工作区就直接落在手机存储上
# 可用环境变量覆盖：DSH_WORKSPACE=/path/to/dir或DSH_WORKSPACE=""跳过此步
log 9 9 "配置 sdcard 访问与默认工作区"
if command -v termux-setup-storage >/dev/null 2>&1; then
  echo '  → 若弹出存储权限对话框，请点击"允许"；Android 11+ 会跳转"所有文件访问"设置页'
  termux-setup-storage || warn "termux-setup-storage 未完成，请手动授权后重跑本脚本"
fi

WORKSPACE="${DSH_WORKSPACE:-$HOME/storage/shared}"
if [ -n "$WORKSPACE" ]; then
  if [ -d "$WORKSPACE" ]; then
    mkdir -p "$HOME/.dsh/profiles/web"
    PATCH="$HOME/.dsh/profiles/web/cordis.patch.yml"
    if grep -q "id: fs-sandbox" "$PATCH" 2>/dev/null; then
      ok "cordis.patch.yml 已含 fs-sandbox 工作区配置"
    elif [ -s "$PATCH" ] && ! grep -qE '^[[:space:]]*\[\][[:space:]]*$' "$PATCH"; then
      printf '\n- id: fs-sandbox\n  config:\n    cwd: %s\n' "$WORKSPACE" >> "$PATCH"
      ok "已追加fs-sandbox工作区配置 -> $WORKSPACE"
    else
      cat > "$PATCH" <<EOF
# dsh profile patch layer (generated by android-termux-dsh)
# 默认工作区固定在sdcard,如需修改请改下面cwd，或删除本段恢复默认
- id: fs-sandbox
  config:
    cwd: $WORKSPACE
EOF
      ok "已写入默认工作区配置 > $WORKSPACE"
    fi
  else
    warn "未找到 $WORKSPACE sdcard权限未生效!"
    warn '请到系统设置 > 应用 > Termux > 权限，允许"文件和媒体"（Android11+为"所有文件访问"），然后重跑本脚本'
  fi
else
  warn "已跳过sdcard工作区配置（DSH_WORKSPACE为空）"
fi

echo "→ 配置 DeepSeek API Key"
PERSIST_KEY=""
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  ok "DEEPSEEK_API_KEY 已在环境变量中设置"
  PERSIST_KEY="$DEEPSEEK_API_KEY"
else
  printf '  请粘贴 DeepSeek API Key（输入不回显，直接回车则扫描已有 Key）: '
  IFS= read -r -s PERSIST_KEY || true
  echo
  if [ -n "$PERSIST_KEY" ]; then
    ok "已读取 Key（未回显）"
    export DEEPSEEK_API_KEY="$PERSIST_KEY"
  elif PERSIST_KEY="$(find_deepseek_key)"; then
    ok "找到已有 DeepSeek API Key"
    export DEEPSEEK_API_KEY="$PERSIST_KEY"
  else
    warn "未配置 Key；稍后可用 export DEEPSEEK_API_KEY=sk-... 或在 Web UI 设置"
  fi
fi
if [ -n "${PERSIST_KEY:-}" ]; then
  RC="$HOME/.bashrc"
  touch "$RC"
  grep -v '^export DEEPSEEK_API_KEY=' "$RC" > "$RC.tmp" 2>/dev/null || true
  printf "export DEEPSEEK_API_KEY='%s'\n" "$PERSIST_KEY" >> "$RC.tmp"
  mv "$RC.tmp" "$RC"
  ok "已保存 DEEPSEEK_API_KEY 到 $RC"
fi

echo "Ciallo～ (∠・ω< )⌒★"
echo "==================== 验证 ===================="
FAIL=0
if dsh --version >/dev/null 2>&1; then ok "dsh"; else fail "dsh"; FAIL=1; fi
if (cd "$D" && node --input-type=module -e "await import('koffi')" >/dev/null 2>&1); then
  ok "koffi（原生FFI可加载）"
else
  fail "koffi无法加载"; FAIL=1
fi
if [ -f "$D/node_modules/node-pty/build/Release/pty.node" ]; then
  ok "node-pty（pty.node已编译）"
else
  fail "node-pty未编译"; FAIL=1
fi
if (cd "$D" && node --input-type=module -e "const s=(await import('sharp')).default; if(!s.versions)process.exit(1)" >/dev/null 2>&1); then
  ok "sharp（WebAssembly 版可加载）"
else
  fail "sharp无法加载"; FAIL=1
fi
if grep -q "js-fallback" "$D/node_modules/node-addon-require-builtin/lib/index.js" 2>/dev/null; then
  ok "require-builtin（JS 垫片已就位）"
else
  fail "require-builtin JS 垫片缺失"; FAIL=1
fi
if timeout 30 dsh web --help >/dev/null 2>&1; then
  ok "dsh web 可启动（profile组装通过）"
else
  fail "dsh web启动失败"; FAIL=1
fi
if [ -d "$HOME/storage/shared" ]; then
  ok "sdcard（$HOME/storage/shared）可访问，默认工作区已就绪"
else
  warn "sdcard暂不可访问——运行dsh web后如无法读取手机存储，请先执行termux-setup-storage并授权"
fi

echo ""
ELAPSED="$(( $(date +%s) - START_TS ))"
echo "   总耗时: $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "Ciallo～ (∠・ω< )⌒★ 全部通过！"
  echo ""
  echo "   默认工作区已固定在sdcard（~/storage/shared），网页版可直接读写手机存储,需要控制底层文件时请赋权root给浏览器与Termux"
  echo "   注意：重新npm安装dsh后，需重跑本脚本恢复sharp兜底，启动包装器与工作区配置"
  echo ""
  echo "   启动DSH服务请使用："
  echo "   dsh web"
  echo "   如果需要大肥鱼(DSH)进行/目录的文件管理操作请使用："
  echo "   sudo dsh web  拉起服务，一定要先给Termux赋权再sudo！"
  echo ""
  echo "   请复制dsh web服务生成的回环地址+token粘贴到浏览器中访问Web UI！否则无校验webui"
else
  echo "(>囗＜?) ！！！部分验证未通过，请查看上方报错项，或截图与保存报错块，上至GitHub仓库提交issue"
  exit 1
fi
