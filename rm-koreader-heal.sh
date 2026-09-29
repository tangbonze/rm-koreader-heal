#!/usr/bin/env bash
# =============================================================================
#  rm-koreader-heal.sh — 一条命令修好 reMarkable 上「升级后 KOReader 打不开」
#
#  背景 / Why this exists
#  ---------------------------------------------------------------------------
#  reMarkable 的系统 OTA 升级是「整块根文件系统替换」：/etc、/usr 等全部重置，
#  只有 /home 分区保留。于是升级之后：
#
#    * KOReader 本体还在          /home/root/koreader/           ✅ 完好
#    * 但 systemd 服务被清掉了    /etc/systemd/system/*.service   ❌ 没了
#    * 于是 button-listen 不再运行 → 长按中键没反应
#    * 时区等写进 /etc 的设置也被重置回 UTC
#
#  表现就是「升级系统后 KOReader 无法启动」，但本体其实一点问题都没有。
#
#  本脚本在 Mac 上运行：自动发现设备（USB 或 Wi-Fi）→ SSH 连进去 → 体检 →
#  把该补的补回去 → 复检。**幂等**：一切正常时它只报告，不改动任何东西。
#
#  用法 / Quick start
#  ---------------------------------------------------------------------------
#    ./rm-koreader-heal.sh                    # 自动发现 + 一键修复
#    ./rm-koreader-heal.sh --check            # 只体检，不做任何改动
#    ./rm-koreader-heal.sh --host 192.168.1.42
#    ./rm-koreader-heal.sh --install-key      # 装公钥，以后免密码
#    ./rm-koreader-heal.sh --watch            # 常驻：设备一上线就自动修复
#
#  兼容：macOS 自带 bash 3.2 即可；无第三方依赖（只用 ssh/scp/nc/mktemp）。
#
#  Author : tangbonze
#  License: MIT
# =============================================================================

set -u

VERSION="1.0.0"
PROG="$(basename "$0")"

# ---------- 可调默认值 -------------------------------------------------------
RM_USER="${RM_USER:-root}"
RM_PORT="${RM_PORT:-22}"
RM_HOST="${RM_HOST:-}"                          # 显式指定设备地址；留空则自动发现
KO_DIR="${KO_DIR:-/home/root/koreader}"         # KOReader 本体目录（改过装法才需要动）
TZ_REQUESTED="${TZ_REQUESTED:-__AUTO__}"        # __AUTO__ / 具体时区名 / 空=不动
INSTALL_DEVICE_HEAL="${INSTALL_DEVICE_HEAL:-1}" # 在设备上装「SSH 登录即自愈」脚本
INSTALL_BOOT_SERVICE="${INSTALL_BOOT_SERVICE:-1}" # 在设备上装「开机自愈」oneshot
WATCH_INTERVAL="${WATCH_INTERVAL:-60}"
USB_CANDIDATES="10.11.99.1 10.11.99.2"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rm-koreader-heal"
KNOWN_HOSTS_FILE="$CACHE_DIR/known_hosts"
HOST_CACHE_FILE="$CACHE_DIR/last_host"
KEY_PATH="$HOME/.ssh/rmk_koreader_heal_ed25519"
LOCK_DIR="$CACHE_DIR/watch.lock"

# 时区模式：auto=只在设备已被重置回 UTC 时补 / force=总是设 / off=不碰
TZ_MODE="auto"

# ---------- 可选用户配置 -----------------------------------------------------
# 路径：${XDG_CONFIG_HOME:-~/.config}/rm-koreader-heal/config
# 内容是普通的 shell 赋值，例如：
#     TZ_REQUESTED=Asia/Hong_Kong
#     WATCH_INTERVAL=120
#     RM_HOST=192.168.1.42
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rm-koreader-heal/config"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  case "${TZ_REQUESTED:-__AUTO__}" in
    "")        TZ_MODE="off"   ;;
    __AUTO__)  TZ_MODE="auto"  ;;
    *)         TZ_MODE="force" ;;
  esac
fi

# ---------- 运行期状态 -------------------------------------------------------
MODE="heal"          # heal | check
DRY_RUN=0
VERBOSE=0
DO_SCAN=0
WATCH=0
INSTALL_KEY=0
RESET_KNOWNS=0
START_KORADER=0
PASSWORD="${RM_PASSWORD:-}"
PASSWORD_FROM_ENV=0
[ -n "$PASSWORD" ] && PASSWORD_FROM_ENV=1
DEV_HOST=""
RESOLVED_TZ=""
SCAN_OK=0
TMP_FILES=""
TMPF=""
EFFECTIVE_DRY=0   # 1 = 只说不做（--check 或 --dry-run）

# 解析出来的设备状态
STATE_MACHINE=""; STATE_VERSION=""; STATE_BTN=""; STATE_BTN_PROCS=""
STATE_XOCHITL=""; STATE_TZ=""; STATE_ROOT_KB=""; STATE_DATE=""
KO_DIR_OK=0; RESULT_LINE=""
UNIT_PRESENT=""; UNIT_MISSING=""; UNIT_INSTALLED=""; UNIT_FAILED=""
DEVHEAL=""; BASHRC=""; BOOT=""; TZ_ACTION=""; DAEMON_RELOADED=0

# ---------- 颜色 / 输出 ------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'
else
  B=; DIM=; R=; RED=; GRN=; YEL=; CYA=
fi

hr()     { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${R}"; }
say()    { printf '%s\n' "$*"; }
ok()     { printf '      %s✓%s %s\n' "$GRN" "$R" "$*"; }
no()     { printf '      %s✗%s %s\n' "$RED" "$R" "$*"; }
warn()   { printf '      %s!%s %s\n' "$YEL" "$R" "$*"; }
bullet() { printf '      %s•%s %s\n' "$CYA" "$R" "$*"; }
die()    { printf '\n%s错误:%s %s\n' "$RED$B" "$R" "$*" >&2; cleanup; exit 1; }

cleanup() {
  [ -n "$TMP_FILES" ] || return 0
  # shellcheck disable=SC2086
  for f in $TMP_FILES; do rm -f "$f" 2>/dev/null; done
  TMP_FILES=""
}
trap cleanup EXIT INT TERM

new_tmp() {
  TMPF="$(mktemp -t rm-koreader-heal)" || die "无法创建临时文件"
  TMP_FILES="$TMP_FILES $TMPF"
}

# ---------- 帮助 -------------------------------------------------------------
usage() {
  cat <<EOF
${B}rm-koreader-heal $VERSION${R} — 一条命令修好 reMarkable 上「升级后 KOReader 打不开」

${B}用法${R}
  $PROG [选项]

${B}常用选项${R}
  --check, --status     只体检、不改动（默认是「体检 + 修复」）
  --host HOST           指定设备地址（Wi-Fi 下的局域网 IP）；不给则自动发现
  --user USER           SSH 用户（默认 root）
  --port PORT           SSH 端口（默认 22）
  --scan                允许扫描本机所在子网来找设备（默认只在 USB / 缓存 /
                        Bonjour 里找，不主动扫网段）
  --watch[=秒]          常驻模式：设备一上线、或服务又缺失，就自动修复
                        （默认每 60 秒检查，Ctrl-C 退出）
  --install-key         生成专用 SSH 密钥并装到设备上，以后免密码
                        （/home 分区在 OTA 后保留，密钥也跟着保留）
  --start-koreader      修完之后顺手把 KOReader 拉起来（会占用设备屏幕）
  --no-device-heal      不在设备上装「SSH 登录即自愈」脚本
  --no-boot-service     不在设备上装「开机自愈」oneshot 服务
  --no-tz               不碰设备时区
  --tz ZONE             指定要设置的时区，如 Asia/Hong_Kong（会强制覆盖）
  --dry-run             打印将要执行的动作，但不真正落盘
  -v, --verbose         打印设备端原始输出（排错用）
  --forget-known-hosts  清掉本脚本记录的设备主机密钥缓存
  -h, --help            显示本帮助
  --version             显示版本

${B}密码${R}
  优先用 SSH 公钥免密（先跑一次 ${B}--install-key${R}）。否则按这个顺序取密码：
    1) 环境变量  RM_PASSWORD='xxxxxx' $PROG
    2) 交互式提示（输入不回显）
  ${B}-p 会把密码暴露在进程列表里，所以不推荐。${R}
  设备密码在：设置 → 关于 → 下滑到 Password 那一行。

${B}为什么要这么修${R}
  reMarkable 的 OTA 只保留 /home，/etc 会被整块重置。KOReader 本体没事，
  丢的是 /etc/systemd/system 下那两个服务的注册。本脚本把它们补回去，
  并在设备上留下「登录即自愈 / 开机自愈」的钩子，减少下次再犯的成本。

${B}配置文件（可选）${R}
  ~/.config/rm-koreader-heal/config      （普通 shell 赋值，用来省掉每次都敲参数）
    TZ_REQUESTED=Asia/Hong_Kong   # 固定设备时区；默认 __AUTO__ = 跟随本机 Mac
    WATCH_INTERVAL=120            # --watch 的检查间隔
    RM_HOST=192.168.1.42          # 固定设备地址
    NO_COLOR=1                    # 关掉彩色输出

${B}退出码${R}
  0 成功 / 一切正常    1 用法或环境错误    2 找不到设备
  3 鉴权失败          4 设备上没找到 KOReader 目录
EOF
}

# ---------- 参数解析 ---------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check|--status)    MODE="check" ;;
      --host)              shift; [ $# -gt 0 ] || die "--host 需要一个地址"; RM_HOST="$1" ;;
      --host=*)            RM_HOST="${1#*=}" ;;
      --user)              shift; [ $# -gt 0 ] || die "--user 需要一个用户名"; RM_USER="$1" ;;
      --user=*)            RM_USER="${1#*=}" ;;
      --port)              shift; [ $# -gt 0 ] || die "--port 需要一个端口号"; RM_PORT="$1" ;;
      --port=*)            RM_PORT="${1#*=}" ;;
      --scan)              DO_SCAN=1 ;;
      --watch)             WATCH=1 ;;
      --watch=*)           WATCH=1; WATCH_INTERVAL="${1#*=}" ;;
      --install-key)       INSTALL_KEY=1 ;;
      --start-koreader)    START_KORADER=1 ;;
      --no-device-heal)    INSTALL_DEVICE_HEAL=0 ;;
      --no-boot-service)   INSTALL_BOOT_SERVICE=0 ;;
      --no-tz)             TZ_REQUESTED=""; TZ_MODE="off" ;;
      --tz)                shift; [ $# -gt 0 ] || die "--tz 需要一个时区名"; TZ_REQUESTED="$1"; TZ_MODE="force" ;;
      --tz=*)              TZ_REQUESTED="${1#*=}"; TZ_MODE="force" ;;
      --dry-run)           DRY_RUN=1 ;;
      -v|--verbose)        VERBOSE=1 ;;
      --forget-known-hosts) RESET_KNOWNS=1 ;;
      -p|--password)       shift; [ $# -gt 0 ] || die "-p 需要密码"; PASSWORD="$1" ;;
      -p*)                 PASSWORD="${1#-p}" ;;
      -h|--help)           usage; exit 0 ;;
      --version)           printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      *)                   printf '未知选项: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done

  case "$WATCH_INTERVAL" in
    ''|*[!0-9]*) die "--watch 的间隔必须是正整数秒" ;;
  esac
  case "$RM_PORT" in
    ''|*[!0-9]*) die "--port 必须是数字" ;;
  esac
}

# ---------- 平台小工具 -------------------------------------------------------
port_open() {
  nc -z -G 2 -w 2 "$1" "$RM_PORT" >/dev/null 2>&1
}

# 读 SSH 服务端 banner，用来确认对面是 dropbear（reMarkable 用的就是它）
ssh_banner() {
  ( sleep 1 ) | nc -w 2 "$1" "$RM_PORT" 2>/dev/null | head -n 1
}

is_dropbear() {
  case "$(ssh_banner "$1")" in
    *dropbear*|*Dropbear*|*DROPBEAR*) return 0 ;;
    *) return 1 ;;
  esac
}

# USB 直连地址是 USB gadget 内网，端口开了就基本可以确定是设备
is_usb_addr() {
  case "$1" in 10.11.99.*) return 0 ;; *) return 1 ;; esac
}

local_timezone() {
  local link
  link="$(readlink /etc/localtime 2>/dev/null)"
  case "$link" in
    *zoneinfo/*) printf '%s' "${link##*zoneinfo/}" ;;
    *) printf '' ;;
  esac
}

# 解析出要下发给设备的目标时区（空 = 不动时区）
resolve_tz() {
  if [ "$TZ_MODE" = "off" ]; then
    printf ''
  elif [ "$TZ_REQUESTED" = "__AUTO__" ]; then
    local_timezone
  else
    printf '%s' "$TZ_REQUESTED"
  fi
}

# ---------- 设备发现 ---------------------------------------------------------
discover_host() {
  local h

  # 1) 显式指定
  if [ -n "$RM_HOST" ]; then
    printf '%s' "$RM_HOST"; return 0
  fi

  # 2) 上次成功的地址
  if [ -f "$HOST_CACHE_FILE" ]; then
    h="$(tr -d ' \r\n' < "$HOST_CACHE_FILE")"
    if [ -n "$h" ] && port_open "$h" && is_dropbear "$h"; then
      printf '%s' "$h"; return 0
    fi
  fi

  # 3) USB 直连
  for h in $USB_CANDIDATES; do
    if port_open "$h"; then
      printf '%s' "$h"; return 0
    fi
  done

  # 4) Bonjour / mDNS（尽力而为）
  if command -v dns-sd >/dev/null 2>&1; then
    for h in remarkable.local rm.local; do
      if port_open "$h" 2>/dev/null; then
        printf '%s' "$h"; return 0
      fi
    done
  fi

  # 5) 扫描当前子网（开销大，只在明确要求 / watch 的稀疏轮次里做）
  if [ "$DO_SCAN" = "1" ] || [ "$SCAN_OK" = "1" ]; then
    h="$(scan_subnet)"
    if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
  fi

  return 1
}

scan_subnet() {
  local iface ip base i found="" hits="$CACHE_DIR/scan.hits"
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -n 1)"
  [ -n "${iface:-}" ] || return 0
  ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  [ -n "${ip:-}" ] || return 0
  base="${ip%.*}"

  printf '      %s·%s 正在扫描 %s.0/24 找设备…\n' "$DIM" "$R" "$base" >&2
  rm -f "$hits" 2>/dev/null

  local running=0
  for i in $(seq 1 254); do
    (
      if port_open "$base.$i" && is_dropbear "$base.$i"; then
        printf '%s\n' "$base.$i" >> "$hits"
      fi
    ) &
    running=$((running + 1))
    if [ "$running" -ge 32 ]; then wait; running=0; fi
  done
  wait

  [ -f "$hits" ] && { found="$(head -n 1 "$hits")"; rm -f "$hits"; }
  [ -n "$found" ] && printf '%s' "$found"
}

cache_host() {
  mkdir -p "$CACHE_DIR" 2>/dev/null
  printf '%s\n' "$1" > "$HOST_CACHE_FILE" 2>/dev/null
}

# ---------- SSH 基建 ---------------------------------------------------------
SSH_OPTS=""
build_ssh_opts() {
  mkdir -p "$CACHE_DIR" 2>/dev/null
  if [ "$RESET_KNOWNS" = "1" ]; then
    rm -f "$KNOWN_HOSTS_FILE" 2>/dev/null
    RESET_KNOWNS=0
    warn "已清除主机密钥缓存，稍后会重新学习"
  fi
  SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS_FILE -o ConnectTimeout=10 -o ServerAliveInterval=5 -o NumberOfPasswordPrompts=1"
  [ -f "$KEY_PATH" ] && SSH_OPTS="$SSH_OPTS -i $KEY_PATH"
}

ASKPASS_FILE=""
setup_password_askpass() {
  # 密码通过环境变量交给 askpass 小程序，临时文件里**不含密码**
  ASKPASS_FILE="$(mktemp -t rm-koreader-heal-askpass)"
  TMP_FILES="$TMP_FILES $ASKPASS_FILE"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$RMK_HEAL_PW"\n'
  } > "$ASKPASS_FILE"
  chmod 700 "$ASKPASS_FILE"
  export RMK_HEAL_PW="$PASSWORD"
  export SSH_ASKPASS="$ASKPASS_FILE"
  export SSH_ASKPASS_REQUIRE=force   # OpenSSH >= 8.4（macOS 12+）
  export DISPLAY="${DISPLAY:-:0}"    # 给老版本 OpenSSH 的旧规则兜底
}

prompt_password() {
  [ -n "$PASSWORD" ] && return 0
  [ "$PASSWORD_FROM_ENV" = "1" ] && return 0
  if [ ! -t 0 ]; then
    die "需要设备密码：请设置 RM_PASSWORD 环境变量，或在终端里交互运行以手工输入"
  fi
  printf '      请输入 reMarkable 的 root 密码（设置 → 关于 → Password，输入不回显）: ' >&2
  local pw
  stty -echo 2>/dev/null
  IFS= read -r pw
  stty echo 2>/dev/null
  printf '\n' >&2
  [ -n "$pw" ] || die "密码为空"
  PASSWORD="$pw"
}

# 远端跑一条命令（stdin 从 /dev/null，确保走 askpass 而不是等 tty）
ssh_run() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -p "$RM_PORT" "$RM_USER@$DEV_HOST" "$@" < /dev/null
}

# 把本地脚本 scp 到设备再执行（脚本末尾自删）。避免多行管道与引号地狱。
ssh_run_script() {
  local local_script="$1"; shift
  local remote="/tmp/rmk-heal.$$.sh"
  # shellcheck disable=SC2086
  if ! scp -q $SSH_OPTS -P "$RM_PORT" "$local_script" "$RM_USER@$DEV_HOST:$remote" < /dev/null; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -p "$RM_PORT" "$RM_USER@$DEV_HOST" "rm -f $remote" < /dev/null >/dev/null 2>&1
    return 90
  fi
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -p "$RM_PORT" "$RM_USER@$DEV_HOST" "$* sh $remote" < /dev/null
}

# ---------- 设备端修复脚本（真正干活的部分）----------------------------------
# 注意：整段用 <<'PAYLOAD' 写入，本地不做任何展开；里面嵌套的 heredoc 同理。
build_payload() {
  cat > "$1" <<'PAYLOAD'
#!/bin/sh
# ---- 在 reMarkable 设备上运行；由 Mac 侧脚本 scp 进来后执行 -------------------
KO_DIR="${KO_DIR:-/home/root/koreader}"
TZ_TARGET="${TZ_TARGET:-}"
TZ_MODE="${TZ_MODE:-auto}"
DRY="${DRY:-0}"
FIX_DEVICE_HEAL="${FIX_DEVICE_HEAL:-1}"
INSTALL_BOOT="${INSTALL_BOOT:-0}"

run() {
  if [ "$DRY" = "1" ]; then
    echo "WOULD: $*"
    return 0
  fi
  "$@"
}

# ---- 0. 前置检查 ------------------------------------------------------------
if [ ! -d "$KO_DIR" ]; then
  echo "MARK:KO_DIR_MISSING"
  echo "RESULT:KO_DIR_MISSING"
  exit 10
fi
echo "MARK:KO_DIR_OK"

# 根分区余量（只有 ~228M，常年在 90% 以上）
set -- $(df -k / 2>/dev/null | tail -n 1)
echo "STATE:root_avail_kb=${4:-unknown}"

CHANGED=0

# ---- 1. systemd 服务注册（核心）--------------------------------------------
for u in koreader.service button-listen.service; do
  dst="/etc/systemd/system/$u"
  if [ -f "$dst" ]; then
    echo "UNIT:present:$u"
    continue
  fi
  src="$KO_DIR/$u"
  if [ -f "$src" ]; then
    if run cp -f "$src" "$dst" 2>/dev/null; then
      echo "UNIT:installed:$u"; CHANGED=1
    else
      echo "UNIT:failed:$u"
    fi
    continue
  fi
  # KOReader 目录里没有模板（被清过 / 换过装法）→ 用内置模板兜底
  if [ "$DRY" = "1" ]; then
    echo "WOULD: write $dst (built-in template)"
    echo "UNIT:installed:$u"; CHANGED=1
    continue
  fi
  case "$u" in
    koreader.service)
      cat > "$dst" <<'UNIT_KOREADER'
[Unit]
Description=KOReader
StartLimitIntervalSec=600
StartLimitBurst=4
After=home.mount
After=xochitl.service
Conflicts=xochitl.service
OnFailure=xochitl.service

[Service]
ExecStart=/home/root/koreader/koreader.sh
ExecStopPost=/bin/false
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_KOREADER
      echo "UNIT:installed:$u"; CHANGED=1
      ;;
    button-listen.service)
      cat > "$dst" <<'UNIT_BUTTON'
[Unit]
Description=KOReader Button Listener
StartLimitIntervalSec=600
StartLimitBurst=4
After=home.mount

[Service]
ExecStart=/home/root/koreader/button-listen
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT_BUTTON
      echo "UNIT:installed:$u"; CHANGED=1
      ;;
  esac
done

if [ "$CHANGED" = "1" ]; then
  run systemctl daemon-reload 2>/dev/null && echo "MARK:DAEMON_RELOADED"
fi

# button-listen 必须常驻；koreader.service 故意不 enable（平时靠长按中键唤起）
if [ -f /etc/systemd/system/button-listen.service ]; then
  if [ "$(systemctl is-enabled button-listen.service 2>&1)" != "enabled" ]; then
    if [ "$DRY" = "1" ]; then echo "WOULD: systemctl enable button-listen.service"
    else systemctl enable button-listen.service >/dev/null 2>&1 && echo "MARK:BTN_ENABLED"; fi
  fi
  if ! systemctl is-active --quiet button-listen.service 2>/dev/null; then
    if [ "$DRY" = "1" ]; then echo "WOULD: systemctl start button-listen.service"
    else systemctl start button-listen.service >/dev/null 2>&1; fi
  fi
fi

# ---- 2. 设备侧「SSH 登录即自愈」--------------------------------------------
RS="$KO_DIR/restore-services.sh"
if [ "$FIX_DEVICE_HEAL" = "1" ]; then
  if [ ! -f "$RS" ]; then
    if [ "$DRY" = "1" ]; then
      echo "WOULD: write $RS"
      echo "DEVHEAL:would_write"
    else
      cat > "$RS" <<'RESTORE_EOF'
#!/bin/sh
# reMarkable OTA 会重置 /etc，导致自定义 systemd 服务丢失。
# 本脚本幂等：仅当服务文件缺失时，从 /home/root/koreader 重新注册。
[ -d /home/root/koreader ] || exit 0
if [ ! -f /etc/systemd/system/button-listen.service ] || [ ! -f /etc/systemd/system/koreader.service ]; then
    cp -f /home/root/koreader/koreader.service      /etc/systemd/system/koreader.service 2>/dev/null
    cp -f /home/root/koreader/button-listen.service /etc/systemd/system/button-listen.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now button-listen.service 2>/dev/null
    echo "[koreader] systemd services re-registered (post-OTA self-heal)"
fi
RESTORE_EOF
      chmod 755 "$RS"
      echo "DEVHEAL:written"
    fi
  else
    echo "DEVHEAL:present"
  fi
  if [ -f "$RS" ] && [ ! -x "$RS" ]; then run chmod 755 "$RS"; fi

  if grep -q "restore-services.sh" /home/root/.bashrc 2>/dev/null; then
    echo "BASHRC:present"
  else
    if [ "$DRY" = "1" ]; then
      echo "WOULD: append hook to /home/root/.bashrc"
      echo "BASHRC:would_add"
    else
      printf '\n# KOReader post-OTA self-heal (rm-koreader-heal)\n[ -x /home/root/koreader/restore-services.sh ] && /home/root/koreader/restore-services.sh >/dev/null 2>&1\n' >> /home/root/.bashrc
      echo "BASHRC:added"
    fi
  fi
else
  if [ -f "$RS" ]; then echo "DEVHEAL:present"; else echo "DEVHEAL:absent"; fi
  if grep -q "restore-services.sh" /home/root/.bashrc 2>/dev/null; then echo "BASHRC:present"; else echo "BASHRC:absent"; fi
fi

# ---- 3. 开机自愈 oneshot（只管普通重启；OTA 会把它自己也清掉）-------------
if [ "$INSTALL_BOOT" = "1" ]; then
  if [ ! -f "$KO_DIR/boot-restore.sh" ]; then
    if [ "$DRY" = "1" ]; then
      echo "WOULD: write $KO_DIR/boot-restore.sh"
    else
      cat > "$KO_DIR/boot-restore.sh" <<'BOOT_EOF'
#!/bin/sh
# 开机自恢复钩子 —— 每次启动调用 restore-services.sh，幂等。
# 注意：本脚本在 /home（OTA 保留），但调用它的 systemd unit 在 /etc（OTA 会清）。
LOG=/home/root/koreader/boot-restore.log
{
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') boot-restore start | $(cat /usr/share/remarkable/update.conf 2>/dev/null) ====="
    /home/root/koreader/restore-services.sh
    echo "----- rc=$? | button-listen=$(systemctl is-enabled button-listen.service 2>&1)/$(systemctl is-active button-listen.service 2>&1) -----"
} >> "$LOG" 2>&1
if [ -f "$LOG" ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
fi
exit 0
BOOT_EOF
      chmod 755 "$KO_DIR/boot-restore.sh"
    fi
  fi
  if [ ! -f "$KO_DIR/koreader-restore.service" ]; then
    if [ "$DRY" = "1" ]; then
      echo "WOULD: write $KO_DIR/koreader-restore.service"
    else
      cat > "$KO_DIR/koreader-restore.service" <<'BOOTSVC_EOF'
[Unit]
Description=KOReader service self-restore (rm-koreader-heal)
Documentation=file:/home/root/koreader/boot-restore.log
After=home.mount
RequiresMountsFor=/home
Before=xochitl.service
ConditionPathExists=/home/root/koreader/boot-restore.sh

[Service]
Type=oneshot
ExecStart=/home/root/koreader/boot-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BOOTSVC_EOF
    fi
  fi
  if [ -f "$KO_DIR/boot-restore.sh" ] && [ -f "$KO_DIR/koreader-restore.service" ] && [ "$DRY" != "1" ]; then
    cp -f "$KO_DIR/koreader-restore.service" /etc/systemd/system/koreader-restore.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    systemctl enable koreader-restore.service >/dev/null 2>&1
  fi
  if [ -f /etc/systemd/system/koreader-restore.service ]; then
    if [ "$(systemctl is-enabled koreader-restore.service 2>&1)" = "enabled" ]; then
      echo "BOOT:enabled"
    else
      echo "BOOT:present"
    fi
  else
    echo "BOOT:absent"
  fi
else
  if [ -f /etc/systemd/system/koreader-restore.service ]; then echo "BOOT:present"; else echo "BOOT:absent"; fi
fi

# ---- 4. 时区（OTA 会重置回 UTC）--------------------------------------------
# auto 模式：只在设备时区被重置（UTC/空）时才补，不覆盖用户自己设过的时区。
if [ -n "$TZ_TARGET" ]; then
  cur="$(cat /etc/timezone 2>/dev/null | tr -d ' \r\n')"
  if [ "$cur" = "$TZ_TARGET" ]; then
    echo "TZ:ok:$cur"
  elif [ "$TZ_MODE" = "auto" ] && [ -n "$cur" ] && [ "$cur" != "UTC" ] && [ "$cur" != "Universal" ]; then
    echo "TZ:kept:$cur"
  else
    if [ "$DRY" = "1" ]; then
      echo "WOULD: set timezone to $TZ_TARGET"
    else
      timedatectl set-timezone "$TZ_TARGET" 2>/dev/null
      printf '%s\n' "$TZ_TARGET" > /etc/timezone 2>/dev/null
    fi
    echo "TZ:set:$TZ_TARGET"; CHANGED=1
  fi
else
  echo "TZ:skipped"
fi

# ---- 5. 复检 --------------------------------------------------------------
echo "STATE:button_listen=$(systemctl is-enabled button-listen.service 2>&1)/$(systemctl is-active button-listen.service 2>&1)"
echo "STATE:koreader_unit=$([ -f /etc/systemd/system/koreader.service ] && echo present || echo missing)"
echo "STATE:btn_procs=$(ps 2>/dev/null | grep -c '[b]utton-listen')"
echo "STATE:xochitl=$(systemctl is-active xochitl.service 2>&1)"
echo "STATE:machine=$(cat /sys/devices/soc0/machine 2>/dev/null)"
echo "STATE:version=$(sed -n 's/^REMARKABLE_RELEASE_VERSION=//p' /usr/share/remarkable/update.conf 2>/dev/null | head -n 1)"
echo "STATE:date=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
echo "STATE:tz=$(cat /etc/timezone 2>/dev/null | tr -d ' \r\n')"
echo "RESULT:OK changed=$CHANGED"

rm -f "$0" 2>/dev/null
exit 0
PAYLOAD
}

# ---------- 解析设备输出 -----------------------------------------------------
parse_payload_output() {
  STATE_MACHINE=""; STATE_VERSION=""; STATE_BTN=""; STATE_BTN_PROCS=""
  STATE_XOCHITL=""; STATE_TZ=""; STATE_ROOT_KB=""; STATE_DATE=""
  KO_DIR_OK=0; RESULT_LINE=""
  UNIT_PRESENT=""; UNIT_MISSING=""; UNIT_INSTALLED=""; UNIT_FAILED=""
  DEVHEAL=""; BASHRC=""; BOOT=""; TZ_ACTION=""; DAEMON_RELOADED=0

  local pf line
  new_tmp; pf="$TMPF"
  printf '%s\n' "$1" > "$pf"

  while IFS= read -r line; do
    case "$line" in
      MARK:KO_DIR_OK)          KO_DIR_OK=1 ;;
      MARK:KO_DIR_MISSING)     KO_DIR_OK=0 ;;
      MARK:DAEMON_RELOADED)    DAEMON_RELOADED=1 ;;
      MARK:BTN_ENABLED)        : ;;
      STATE:button_listen=*)   STATE_BTN="${line#STATE:button_listen=}" ;;
      STATE:btn_procs=*)       STATE_BTN_PROCS="${line#STATE:btn_procs=}" ;;
      STATE:xochitl=*)         STATE_XOCHITL="${line#STATE:xochitl=}" ;;
      STATE:machine=*)         STATE_MACHINE="${line#STATE:machine=}" ;;
      STATE:version=*)         STATE_VERSION="${line#STATE:version=}" ;;
      STATE:date=*)            STATE_DATE="${line#STATE:date=}" ;;
      STATE:tz=*)              STATE_TZ="${line#STATE:tz=}" ;;
      STATE:root_avail_kb=*)   STATE_ROOT_KB="${line#STATE:root_avail_kb=}" ;;
      UNIT:present:*)          UNIT_PRESENT="$UNIT_PRESENT ${line#UNIT:present:}" ;;
      UNIT:missing:*)          UNIT_MISSING="$UNIT_MISSING ${line#UNIT:missing:}" ;;
      UNIT:installed:*)        UNIT_INSTALLED="$UNIT_INSTALLED ${line#UNIT:installed:}" ;;
      UNIT:failed:*)           UNIT_FAILED="$UNIT_FAILED ${line#UNIT:failed:}" ;;
      DEVHEAL:*)               DEVHEAL="${line#DEVHEAL:}" ;;
      BASHRC:*)                BASHRC="${line#BASHRC:}" ;;
      BOOT:*)                  BOOT="${line#BOOT:}" ;;
      TZ:set:*)                TZ_ACTION="set:${line#TZ:set:}" ;;
      TZ:ok:*)                 TZ_ACTION="ok:${line#TZ:ok:}" ;;
      TZ:kept:*)               TZ_ACTION="kept:${line#TZ:kept:}" ;;
      TZ:skipped)              TZ_ACTION="skipped" ;;
      RESULT:*)                RESULT_LINE="${line#RESULT:}" ;;
    esac
  done < "$pf"
}

# 判断设备是否健康（不需要修）
is_healthy() {
  [ "$KO_DIR_OK" = "1" ] || return 1
  case "$STATE_BTN" in enabled/active) ;; *) return 1 ;; esac
  [ -z "$UNIT_MISSING" ] || return 1
  [ -z "$UNIT_FAILED" ]  || return 1
  if [ "$INSTALL_DEVICE_HEAL" = "1" ]; then
    case "$DEVHEAL" in absent|would_write) return 1 ;; esac
    case "$BASHRC"  in absent|would_add)   return 1 ;; esac
  fi
  case "$TZ_ACTION" in set:*) return 1 ;; esac
  return 0
}

describe_host_kind() {
  if is_usb_addr "$DEV_HOST"; then printf 'USB'; else printf 'Wi-Fi'; fi
}

# ---------- 一次完整流程 -----------------------------------------------------
run_once() {
  local payload="" out="" pre="" act="" fix_dev="$INSTALL_DEVICE_HEAL" boot="$INSTALL_BOOT_SERVICE"

  rm -f "$CACHE_DIR/scan.hits" 2>/dev/null

  printf '\n%s%s %s%s\n' "$B" "$PROG" "$VERSION" "$R"
  hr

  # ---- 1. 找设备
  printf '  [1/5] 发现设备\n'
  DEV_HOST="$(discover_host)" || true
  if [ -z "$DEV_HOST" ]; then
    no "没找到可达的 reMarkable"
    say "      排查建议："
    say "        · USB 直连：插上后等几秒再试（dropbear 起来要时间）"
    say "        · Wi-Fi：用 --host <设备IP> 指定，或加 --scan 扫本机子网"
    return 2
  fi
  ok "$DEV_HOST  ${DIM}($(describe_host_kind))${R}"

  # ---- 2. 连接与鉴权
  printf '  [2/5] 连接与鉴权\n'
  build_ssh_opts
  pre="$(ssh_run 'echo READY' 2>&1)"
  if ! printf '%s' "$pre" | grep -q READY; then
    prompt_password
    setup_password_askpass
    pre="$(ssh_run 'echo READY' 2>&1)"
    if ! printf '%s' "$pre" | grep -q READY; then
      no "SSH 登录失败"
      case "$pre" in
        *"Permission denied"*)            say "      密码不对。设备上「设置 → 关于」可看当前密码。" ;;
        *"Host key verification failed"*) say "      主机密钥变了，可加 --forget-known-hosts 重试。" ;;
        *) printf '%s\n' "$pre" | head -n 3 | sed 's/^/      | /' ;;
      esac
      return 3
    fi
    ok "已连接 ${DIM}(密码认证)${R}"
  else
    ok "已连接 ${DIM}(公钥免密)${R}"
  fi
  cache_host "$DEV_HOST"

  # 解析时区目标（auto = 跟随本机 Mac，但只补「被重置」的情况）
  RESOLVED_TZ="$(resolve_tz)"

  if [ "$MODE" = "check" ]; then
    fix_dev=0; boot=0
  fi

  # ---- 3. 体检（+ 修复）
  printf '  [3/5] 体检%s\n' "$([ "$MODE" = "check" ] && printf '' || printf ' + 修复')"
  new_tmp; payload="$TMPF"
  build_payload "$payload"

  local dry=0
  [ "$MODE" = "check" ] && dry=1
  [ "$DRY_RUN" = "1" ] && dry=1
  EFFECTIVE_DRY="$dry"

  out="$(ssh_run_script "$payload" \
      "KO_DIR='$KO_DIR' TZ_TARGET='$RESOLVED_TZ' TZ_MODE='$TZ_MODE' DRY='$dry' FIX_DEVICE_HEAL='$fix_dev' INSTALL_BOOT='$boot'" 2>&1)" || true

  if [ "$VERBOSE" = "1" ]; then
    say "      ${DIM}--- 设备端原始输出 ---${R}"
    printf '%s\n' "$out" | sed 's/^/      | /'
    say "      ${DIM}--- end ---${R}"
  fi

  parse_payload_output "$out"

  if [ "$KO_DIR_OK" != "1" ]; then
    no "设备上没找到 KOReader 目录 $KO_DIR"
    say "      这台设备要么还没装 KOReader，要么装法被改过。"
    say "      装法见 README 的「先装 KOReader」一节。"
    return 4
  fi

  ok "KOReader 本体    $KO_DIR"
  local k
  for k in $UNIT_PRESENT;   do ok "服务已就位      $k"; done
  for k in $UNIT_MISSING;   do no "服务缺失        $k  ${DIM}← 升级后打不开就是它${R}"; done
  [ -n "$STATE_ROOT_KB" ] && [ "$STATE_ROOT_KB" != "unknown" ] && \
    bullet "根分区可用      $((STATE_ROOT_KB / 1024)) MB  ${DIM}(系统盘很小，属正常)${R}"
  [ -n "$STATE_MACHINE" ] && bullet "设备型号        $STATE_MACHINE"
  [ -n "$STATE_VERSION" ] && bullet "系统版本        $STATE_VERSION"
  [ -n "$STATE_XOCHITL" ] && bullet "原厂阅读器      xochitl $STATE_XOCHITL"

  # ---- 4. 修复动作
  printf '  [4/5] %s\n' "$([ "$MODE" = "check" ] && printf '修复（--check 模式，已跳过）' || printf '修复')"
  if [ -n "$UNIT_INSTALLED" ]; then
    for k in $UNIT_INSTALLED; do
      if [ "$EFFECTIVE_DRY" = "1" ]; then bullet "需要注册 $k"; else ok "注册 $k"; fi
    done
  else
    bullet "服务注册无需变动"
  fi
  if [ "$DAEMON_RELOADED" = "1" ]; then
    if [ "$EFFECTIVE_DRY" = "1" ]; then bullet "需要 systemctl daemon-reload"; else ok "systemctl daemon-reload"; fi
  fi
  for k in $UNIT_FAILED; do warn "注册失败：$k（根分区可能已满）"; done
  case "$DEVHEAL" in
    written)     ok "写入设备侧自愈脚本 restore-services.sh" ;;
    would_write) bullet "需要写入设备侧自愈脚本（dry-run）" ;;
    present)     bullet "设备侧自愈脚本已在" ;;
    *)           bullet "未安装设备侧自愈脚本" ;;
  esac
  case "$BASHRC" in
    added)     ok "写入 .bashrc 登录钩子" ;;
    would_add) bullet "需要写入 .bashrc 登录钩子（dry-run）" ;;
    present)   bullet ".bashrc 登录钩子已在" ;;
    *)         bullet "未安装 .bashrc 登录钩子" ;;
  esac
  case "$BOOT" in
    enabled) ok "开机自愈服务已 enabled" ;;
    present) bullet "开机自愈服务已存在" ;;
    *)       bullet "未安装开机自愈服务" ;;
  esac
  case "$TZ_ACTION" in
    set:*)
      if [ "$EFFECTIVE_DRY" = "1" ]; then bullet "需要恢复时区 → ${TZ_ACTION#set:}"
      else ok "恢复时区 → ${TZ_ACTION#set:}"; fi ;;
    ok:*)    bullet "时区已是 ${TZ_ACTION#ok:}" ;;
    kept:*)  bullet "时区保持 ${TZ_ACTION#kept:}（未被重置，不动它）" ;;
    skipped) bullet "未改动时区（--no-tz）" ;;
  esac
  if [ "$STATE_BTN" = "enabled/active" ]; then
    ok "button-listen  $STATE_BTN  ${DIM}(长按中键可唤起 KOReader)${R}"
  elif [ -n "$UNIT_MISSING" ]; then
    no "button-listen  服务缺失（原因见上）"
  else
    warn "button-listen 状态异常：$STATE_BTN"
  fi
  [ -n "$STATE_BTN_PROCS" ] && [ "$STATE_BTN_PROCS" != "0" ] && bullet "监听进程数      $STATE_BTN_PROCS"
  [ -n "$STATE_TZ" ]   && bullet "设备时区        $STATE_TZ"
  [ -n "$STATE_DATE" ] && bullet "设备时间        $STATE_DATE"

  # ---- 5. 可选启动 / 复检
  if [ "$START_KORADER" = "1" ] && [ "$MODE" != "check" ] && [ "$DRY_RUN" != "1" ]; then
    printf '  [5/5] 启动 KOReader\n'
    ssh_run 'systemctl start koreader.service' >/dev/null 2>&1 || true
    sleep 8
    act="$(ssh_run 'systemctl is-active koreader.service' 2>/dev/null)"
    if [ "$act" = "active" ]; then ok "KOReader 已拉起"; else warn "KOReader 状态：$act"; fi
  else
    printf '  [5/5] 复检\n'
    if [ "$MODE" = "check" ]; then
      if is_healthy; then ok "一切正常，无需修复"; else warn "存在需要修复的项（去掉 --check 即会自动修好）"; fi
    else
      ok "完成 — ${RESULT_LINE:-OK}"
    fi
  fi

  hr
  if [ "$MODE" = "check" ]; then
    if is_healthy; then
      say "${GRN}${B}设备健康${R} — 没发现需要修复的问题。"
    else
      say "${YEL}${B}需要修复${R} — 去掉 --check 重跑一次就会自动修好。"
    fi
  elif [ "$DRY_RUN" = "1" ]; then
    say "${CYA}${B}dry-run 结束${R} — 上面列的是「将要执行」的动作，设备实际未被改动。"
  else
    case "$RESULT_LINE" in
      *changed=1*)
        say "${GRN}${B}修复完成${R} — 到设备上${B}长按中键约 3 秒${R}即可唤起 KOReader。"
        say "${DIM}想退回原厂界面：KOReader 里菜单 → 退出，或长按电源重启。${R}" ;;
      *)
        say "${GRN}${B}修复完成${R} — 本次无需改动（幂等空跑）。" ;;
    esac
  fi
  say ""
  return 0
}

# ---------- 装公钥 -----------------------------------------------------------
do_install_key() {
  printf '\n%s%s %s — 安装 SSH 公钥%s\n' "$B" "$PROG" "$VERSION" "$R"
  hr

  DEV_HOST="$(discover_host)" || true
  if [ -z "$DEV_HOST" ]; then no "没找到可达的 reMarkable"; return 2; fi
  ok "设备 $DEV_HOST"

  if [ ! -f "$KEY_PATH" ]; then
    mkdir -p "$(dirname "$KEY_PATH")"
    ssh-keygen -t ed25519 -N '' -C "rm-koreader-heal@$(hostname -s)" -f "$KEY_PATH" >/dev/null 2>&1 \
      || die "生成密钥失败（$KEY_PATH）"
    chmod 600 "$KEY_PATH"; chmod 644 "$KEY_PATH.pub"
    ok "已生成专用密钥"
    bullet "$KEY_PATH"
  else
    bullet "复用已有密钥 $KEY_PATH"
  fi

  build_ssh_opts
  if ! ssh_run 'echo READY' >/dev/null 2>&1; then
    prompt_password
    setup_password_askpass
    ssh_run 'echo READY' >/dev/null 2>&1 || die "SSH 登录失败，无法安装公钥"
  fi
  cache_host "$DEV_HOST"

  local pub
  pub="$(cat "$KEY_PATH.pub")"
  ssh_run "mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh && touch /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys && { grep -qF '$pub' /home/root/.ssh/authorized_keys || printf '%s\n' '$pub' >> /home/root/.ssh/authorized_keys; } && echo KEY_DONE" >/dev/null 2>&1

  local verify
  verify="$(ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
              -o ConnectTimeout=10 -i "$KEY_PATH" -o IdentitiesOnly=yes \
              -p "$RM_PORT" "$RM_USER@$DEV_HOST" 'echo KEYOK' < /dev/null 2>&1)"
  hr
  if printf '%s' "$verify" | grep -q KEYOK; then
    ok "${GRN}公钥安装成功${R} — 以后运行本脚本不再需要密码"
    bullet "私钥 $KEY_PATH ${DIM}(别外传)${R}"
    bullet "${DIM}公钥在 /home 分区，OTA 升级后依然有效${R}"
    return 0
  fi
  no "公钥写入后验证失败，请再跑一次，或检查设备 /home/root/.ssh/authorized_keys"
  return 1
}

# ---------- watch ------------------------------------------------------------
do_watch() {
  printf '\n%s%s %s — 守护模式%s\n' "$B" "$PROG" "$VERSION" "$R"
  say "${DIM}每 ${WATCH_INTERVAL}s 检查一次；设备一上线、或服务又缺失，就自动修复。Ctrl-C 退出。${R}"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
      die "已经有一个 $PROG --watch 在跑了（PID $(cat "$LOCK_DIR/pid")）"
    fi
    rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR" 2>/dev/null
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"; cleanup; exit 0' EXIT INT TERM

  local n=0 auth_host="" payload="" out="" tz="" rc=0 sess="" 
  while :; do
    n=$((n + 1))
    SCAN_OK=0
    if [ "$n" -eq 1 ] || [ $((n % 5)) -eq 1 ]; then SCAN_OK=1; fi

    DEV_HOST="$(discover_host)" || true
    if [ -z "$DEV_HOST" ]; then
      [ "$n" -eq 1 ] && warn "还没发现设备，继续等…"
      sleep "$WATCH_INTERVAL"
      continue
    fi

    # ---- 建立会话（首次连接，或换了地址才重做一次）----
    # 注意：这里必须调 build_ssh_opts，否则 SSH_OPTS 为空、不会带上
    # 专用密钥与 HostKey 策略，鉴权会静默失败。
    if [ "$DEV_HOST" != "$auth_host" ]; then
      build_ssh_opts
      sess="公钥免密"
      if ! ssh_run 'echo READY' >/dev/null 2>&1; then
        if [ -z "$PASSWORD" ] && [ ! -t 0 ]; then
          warn "$DEV_HOST 需要密码但无法交互输入；请先跑 --install-key，或设置 RM_PASSWORD"
          sleep "$WATCH_INTERVAL"; continue
        fi
        prompt_password
        setup_password_askpass
        if ! ssh_run 'echo READY' >/dev/null 2>&1; then
          warn "登录 $DEV_HOST 失败，${WATCH_INTERVAL}s 后重试"
          sleep "$WATCH_INTERVAL"; continue
        fi
        sess="密码认证"
      fi
      cache_host "$DEV_HOST"
      auth_host="$DEV_HOST"
      say "  ${GRN}设备上线：$DEV_HOST${R}  ${DIM}($sess)${R}"
    fi

    # ---- 体检（只读）----
    tz="$(resolve_tz)"
    RESOLVED_TZ="$tz"
    new_tmp; payload="$TMPF"
    build_payload "$payload"
    rc=0
    out="$(ssh_run_script "$payload" \
        "KO_DIR='$KO_DIR' TZ_TARGET='$tz' TZ_MODE='$TZ_MODE' DRY='1' FIX_DEVICE_HEAL='0' INSTALL_BOOT='0'" 2>&1)" || rc=$?
    if [ "$rc" != "0" ]; then
      warn "设备检查失败 (rc=$rc)，${WATCH_INTERVAL}s 后重试"
      auth_host=""          # 下次重建会话
      sleep "$WATCH_INTERVAL"; continue
    fi
    if [ "$VERBOSE" = "1" ]; then printf '%s\n' "$out" | sed 's/^/      | /'; fi

    parse_payload_output "$out"

    # ---- 发现异常就修（修完下一轮复检自然变健康）----
    if [ "$KO_DIR_OK" = "1" ] && ! is_healthy; then
      say "  ${YEL}检测到服务缺失 / 时区被重置，开始自动修复…${R}"
      run_once
      auth_host=""          # 修复后重建会话，顺带让"设备上线"重新播报
    fi

    sleep "$WATCH_INTERVAL"
  done
}

# ---------- 主流程 -----------------------------------------------------------
main() {
  parse_args "$@"
  mkdir -p "$CACHE_DIR" 2>/dev/null

  if [ "$INSTALL_KEY" = "1" ]; then
    do_install_key
    exit $?
  fi
  if [ "$WATCH" = "1" ]; then
    do_watch
    exit 0
  fi
  run_once
  exit $?
}

main "$@"
