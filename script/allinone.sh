#!/usr/bin/env bash
# allinone.sh — 多协议代理统一管理脚本
SCRIPT_VERSION="5.85.5"
set -uo pipefail

# ═══════════════════════════════════════════════════════════════
#  颜色（必须在一切输出之前定义，BANNER 会引用）
# ═══════════════════════════════════════════════════════════════
R=$'\033[31m'
G=$'\033[32m'
Y=$'\033[33m'
B=$'\033[34m'
C=$'\033[36m'
BD=$'\033[1m'
NC=$'\033[0m'

SCRIPT_CHANNEL_FILE="/etc/sing-box/.aio_channel"
_aio_channel() {
  local f=$SCRIPT_CHANNEL_FILE
  [[ -f "$f" ]] && cat "$f" || echo "stable"
}
_aio_branch() {
  [[ "$(_aio_channel)" == "beta" ]] && echo "dev" || echo "main"
}

# ═══════════════════════════════════════════════════════════════
#  Banner（ANSI Shadow 风格，figlet 生成）
# ═══════════════════════════════════════════════════════════════
BANNER="${C} 

   █████╗  ██╗  █████╗  ██████╗ ███╗   ███╗
  ██╔══██╗ ██║ ██╔══██╗ ██╔══██╗████╗ ████║
  ███████║ ██║ ██║  ██║ ██████╔╝██╔████╔██║
  ██╔══██║ ██║ ██║  ██║ ██╔═══╝ ██║╚██╔╝██║
  ██║  ██║ ██║ ╚█████╔╝ ██║     ██║ ╚═╝ ██║
  ╚═╝  ╚═╝ ╚═╝  ╚════╝  ╚═╝     ╚═╝     ╚═╝
  All in One Proxy Manager v5.85.5__CHANNEL__${NC}"

# ═══════════════════════════════════════════════════════════════
#  基础层（工具 / 发行版 / 包管理 / 网络）
# ═══════════════════════════════════════════════════════════════
die() {
  printf "${R}错误：%s${NC}\n" "$*" >&2
  exit 1
}
info() { printf "${G}%s${NC}\n" "$*"; }
warn() { printf "${Y}%s${NC}\n" "$*"; }
_ask() {
  printf "${BD}%s${NC}" "$1"
  read -r "$2"
}

[[ $EUID -ne 0 ]] && die "请以 root 用户或使用 sudo 运行"

# 发行版检测
if [[ -f /etc/alpine-release ]]; then
  D=alpine
elif command -v apt-get &>/dev/null; then
  D=debian
else D=unknown; fi

# shellcheck disable=SC2015  # intentional Alpine/Debian ternary
_pkg_i() { [[ "$D" == "alpine" ]] && apk add --no-cache "$@" || apt-get install -y "$@"; }
# shellcheck disable=SC2015
_pkg_u() { [[ "$D" == "alpine" ]] && apk update || apt-get update; }

_need() {
  local c=$1 p=${2:-$1}
  command -v "$c" &>/dev/null && return 0
  warn "未安装 $c，正在安装..."
  # shellcheck disable=SC2015
  _pkg_u && _pkg_i "$p" || die "$p 安装失败"
}
_need curl
_need_py() { _need python3 python3; }

# 网络检测（缓存）
_NC=""
_net() {
  [[ -n "$_NC" ]] && {
    echo "$_NC"
    return
  }
  local v4=false v6=false
  curl -4 -s --connect-timeout 3 https://api.ipify.org &>/dev/null && v4=true || true
  curl -6 -s --connect-timeout 3 https://api64.ipify.org &>/dev/null && v6=true || true
  $v4 && $v6 && _NC=dual || $v6 && _NC=ipv6 || $v4 && _NC=ipv4 || _NC=none
  echo "$_NC"
}
_co() { [[ "$(_net)" == "ipv6" ]] && echo "-6" || echo ""; }

# 获取所有可用 IP（v4 和 v6，缓存）
_IPS=""
_get_ips() {
  [[ -n "$_IPS" ]] && {
    echo "$_IPS"
    return
  }
  local v4 v6
  v4=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
  v6=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null || true)
  _IPS="${v4:-} ${v6:-}"
  echo "$_IPS"
}

# 端口冲突检测
_port_in_use() {
  local port=$1
  if command -v ss &>/dev/null; then
    ss -tulnp 2>/dev/null | grep -q ":${port} " && return 0
  elif command -v netstat &>/dev/null; then
    netstat -tulnp 2>/dev/null | grep -q ":${port} " && return 0
  elif [[ -f /proc/net/tcp ]]; then
    grep -q " $(printf '%04X' "$port") " /proc/net/tcp 2>/dev/null && return 0
    grep -q " $(printf '%04X' "$port") " /proc/net/udp 2>/dev/null && return 0
  fi
  return 1
}

# 通用服务管理
_svc() {
  local n=$1 a=$2
  if [[ "$D" == "alpine" ]]; then
    case "$a" in
    enable) rc-update add "$n" default 2>/dev/null || true ;; disable) rc-update del "$n" default 2>/dev/null || true ;;
    start) rc-service "$n" start 2>/dev/null || true ;; stop) rc-service "$n" stop 2>/dev/null || true ;;
    restart) rc-service "$n" restart ;; status) rc-service "$n" status ;;
    is_active) rc-service "$n" status &>/dev/null ;;
    esac
  else
    case "$a" in
    enable) systemctl enable "$n.service" ;; disable) systemctl disable "$n.service" 2>/dev/null || true ;;
    start)
      systemctl daemon-reload
      systemctl start "$n.service" 2>/dev/null || true
      ;;
    stop) systemctl stop "$n.service" 2>/dev/null || true ;; restart)
      systemctl daemon-reload
      systemctl restart "$n.service"
      ;;
    status) systemctl status "$n.service" --no-pager ;; is_active) systemctl is-active --quiet "$n.service" ;;
    esac
  fi
}

# QR 码渲染
_qr() {
  printf "${C}===== 二维码 =====${NC}\n"
  LINK="$1" python3 <<'PYEOF'
import os,sys; d=os.environ['LINK']
def R(m):
 if len(m)%2: m.append([False]*len(m[0]))
 for i in range(0,len(m),2):
  l=''
  for j in range(len(m[0])):
   t,b=m[i][j],m[i+1][j]
   if t and b: l+='\u2588'
   elif t: l+='\u2580'
   elif b: l+='\u2584'
   else: l+=' '
  print(l)
try:
 import qrcode; qr=qrcode.QRCode(border=1); qr.add_data(d); qr.make(fit=True)
 R(qr.get_matrix()); sys.exit(0)
except ImportError: pass
try:
 import segno; segno.make(d,error='m').terminal(compact=True); sys.exit(0)
except ImportError: pass
x='apk add py3-qrcode' if os.path.exists('/etc/alpine-release') else 'apt install python3-qrcode'
print(f'（二维码库未安装，请执行: {x}）',file=sys.stderr)
PYEOF
}

# BBR
set_bbr() {
  printf "${C}===== 设置 BBR =====${NC}\n"
  sysctl net.ipv4.tcp_available_congestion_control &>/dev/null || {
    warn "系统不支持"
    return 1
  }
  local cur
  cur=$(sysctl -n net.ipv4.tcp_congestion_control)
  printf "📋 可用: %s\n⚡ 当前: %s\n" "$(sysctl -n net.ipv4.tcp_available_congestion_control)" "$cur"
  [[ "$cur" == "bbr" ]] && {
    info "✅ 已在使用 BBR"
    return 0
  }
  local c
  _ask "切换为 BBR？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || {
    echo "取消"
    return
  }
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf &&
    sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf ||
    echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
  info "✅ BBR 已启用"
}

# ═══════════════════════════════════════════════════════════════
#  协议共享辅助函数
# ═══════════════════════════════════════════════════════════════

# URL 编码（替代重复的 python3 -c urllib.parse 调用）
_url_enc() {
  python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
}

# 写 OpenRC init 脚本: $1=服务名 $2=描述 $3=配置目录
_write_openrc() {
  cat >"/etc/init.d/$1" <<EOF
#!/sbin/openrc-run
name="$1"; description="$2"
command="/usr/bin/sing-box"; command_args="run -c $3/config.json"
command_background=true; pidfile="/run/$1.pid"
output_log="/var/log/$1.log"; error_log="/var/log/$1.log"
depend() { need net; after firewall; }
EOF
  chmod +x "/etc/init.d/$1"
}

# 写 systemd unit 文件: $1=服务名 $2=描述 $3=配置目录
_write_systemd() {
  cat >"/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$2
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c $3/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}

# 通用协议操作: $1=服务名 $2=显示标签 $3=操作(status/start/stop)
_proto_action() {
  local svc=$1 label=$2 action=$3
  case "$action" in
  status)
    printf "${C}===== %s 状态 =====${NC}\n" "$label"
    _svc "$svc" status || warn "服务未运行"
    ;;
  start)
    _svc "$svc" enable
    _svc "$svc" start
    info "✅ %s 已开启" "$label"
    ;;
  stop)
    _svc "$svc" stop
    _svc "$svc" disable
    info "✅ %s 已停止" "$label"
    ;;
  esac
}

# 通用卸载: $1=服务名 $2=配置目录 $3=init脚本名(同服务名) $4=显示标签
_proto_uninstall() {
  local svc=$1 cfgdir=$2 initname=$3 label=$4
  printf "${C}===== 卸载 %s =====${NC}\n" "$label"
  _svc "$svc" stop
  _svc "$svc" disable
  # shellcheck disable=SC2015
  [[ "$D" == "alpine" ]] && rm -f "/etc/init.d/$initname" || {
    rm -f "/etc/systemd/system/${initname}.service"
    systemctl daemon-reload
  }
  rm -rf "$cfgdir"
  info "✅ 卸载完成"
}

# 端口输入验证循环: $1=默认端口, 输出到变量 port
_ask_port() {
  local default=$1
  while true; do
    _ask "监听端口（默认: ${default}）：" port
    port=${port:-$default}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || {
      warn "端口无效"
      continue
    }
    _port_in_use "$port" && {
      warn "端口 $port 已被占用，请换一个"
      continue
    }
    break
  done
}

# 密码输入验证循环, 输出到变量 pw
_ask_password() {
  while true; do
    printf "${Y}认证密码（留空随机生成）：${NC}"
    read -rsp "" pw
    echo
    if [[ -z "$pw" ]]; then
      pw=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
      info "随机密码: $pw"
      break
    elif [[ ${#pw} -ge 6 ]]; then break; else warn "至少6位"; fi
  done
}

# 检查配置是否已安装: $1=配置文件路径, 输出 "已安装"/"未安装"
_proto_installed() { [[ -f "$1" ]] && echo "已安装" || echo "未安装"; }

# 确保 sing-box 已安装
_ensure_sb() {
  command -v sing-box &>/dev/null || {
    warn "sing-box 未安装，先安装..."
    _sb_fetch_bin
  }
  command -v sing-box &>/dev/null || die "sing-box 安装失败"
}

# ═══════════════════════════════════════════════════════════════
#  更新脚本自身
# ═══════════════════════════════════════════════════════════════
update_self() {
  printf "${C}===== 更新脚本自身 =====${NC}\n"
  local co _br
  co=$(_co)
  _br=$(_aio_branch)
  # shellcheck disable=SC2086  # $co is safe: empty or "-6"
  rver=$(curl $co -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/${_br}/script/allinone.sh" 2>/dev/null | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1) || true
  if [[ "${AIO_AUTO:-}" == "1" && -n "$rver" && "$rver" == "$SCRIPT_VERSION" ]]; then
    info "✅ 已是最新版本 v$SCRIPT_VERSION"
    return 0
  fi
  if [[ -n "$rver" && "$rver" != "$SCRIPT_VERSION" ]]; then
    info "🔖 新版本：v${rver}（当前：v${SCRIPT_VERSION}）"
  fi
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/${_br}/script/allinone.sh"
  local target
  if command -v realpath &>/dev/null; then
    target=$(realpath "${BASH_SOURCE[0]}")
  elif command -v readlink &>/dev/null; then
    target=$(readlink -f "${BASH_SOURCE[0]}")
  else
    target="${BASH_SOURCE[0]}"
  fi
  cp "$target" "${target}.bak" || true
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  echo "从 $url 下载..."
  # shellcheck disable=SC2086  # $co is safe: empty or "-6"
  if curl $co -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
    chmod +x "$tmp"
    mv "$tmp" "$target"
    if [[ "${AIO_AUTO:-}" == "1" ]]; then
      info "✅ 已更新至 $target"
      return 0
    fi
    info "✅ 已更新至 $target，正在重启..."
    rm -f "$tmp"
    exec bash "$target"
  else
    warn "下载失败"
    return 1
  fi
}

# 检查脚本更新（异步，结果缓存到临时文件）
_check_script_update() {
  local f=/tmp/.aio_script_update
  local _br
  _br=$(_aio_branch)
  # shellcheck disable=SC2046
  remote=$(curl $(_co) -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/${_br}/script/allinone.sh" 2>/dev/null | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1) || true
  [[ -z "$remote" || "$remote" == "$SCRIPT_VERSION" ]] && {
    : >"$f"
    return
  }
  echo "$remote" >"$f"
  echo "$remote"
}

# 检查 sing-box 更新（异步，结果缓存到临时文件）
_check_sb_update() {
  local f=/tmp/.aio_sb_update
  local localv
  localv=$(_sb_ver 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || true
  [[ -z "$localv" ]] && {
    : >"$f"
    return
  }
  local remote
  # shellcheck disable=SC2046
  remote=$(curl $(_co) -fsSL --connect-timeout 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1) || true
  [[ -z "$remote" || "$remote" == "$localv" ]] && {
    : >"$f"
    return
  }
  echo "$remote" >"$f"
  echo "$remote"
}

# 切换更新频道
switch_channel() {
  printf "${C}===== 切换更新频道 =====${NC}\n"
  local cur
  cur=$(_aio_channel)
  local br
  br=$(_aio_branch)
  printf "当前频道：${G}%s${NC}（%s 分支）\n" "$cur" "$br"
  printf "  ${Y}1)${NC} 稳定版（main 分支）\n"
  printf "  ${Y}2)${NC} 测试版（dev 分支）\n"
  printf "  ${Y}0)${NC} 返回上一级\n"
  printf "${BD}选择 [0-2]: ${NC}"
  local ch
  read -r ch
  echo
  local new
  case "$ch" in
  1) new="stable" ;;
  2) new="beta" ;;
  *)
    echo "取消"
    return
    ;;
  esac
  [[ "$new" == "$cur" ]] && {
    info "✅ 已在 ${new} 频道"
    return
  }
  mkdir -p /etc/sing-box
  echo "$new" >/etc/sing-box/.aio_channel
  info "✅ 已切换至 ${new} 频道（$(_aio_branch) 分支）"
  local c
  _ask "是否立即更新脚本？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] && update_self
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Vless Reality
# ═══════════════════════════════════════════════════════════════
SBD=/etc/sing-box
SBC="$SBD/config.json"
SBB=sing-box
SBS=sing-box

_sb_ver() {
  command -v "$SBB" &>/dev/null || {
    echo "未安装"
    return
  }
  $SBB version 2>/dev/null | head -1
}

_sb_openrc() {
  cat >/etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"; description="sing-box service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box/config.json"
command_background=true; pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"; error_log="/var/log/sing-box.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box
}

# 仅下载/更新 sing-box 二进制（不重启服务）
_sb_fetch_bin() {
  printf "${C}===== 升级 sing-box 内核 =====${NC}\n"
  local arch
  case "$(uname -m)" in
  x86_64) arch=amd64 ;; x86 | i686 | i386) arch=386 ;; aarch64 | arm64) arch=arm64 ;;
  armv7l) arch=armv7 ;; s390x) arch=s390x ;; *) die "不支持的架构: $(uname -m)" ;;
  esac
  local co
  co=$(_co)
  printf "🌐 网络：%s  架构：%s  发行版：%s\n" "$(_net)" "$arch" "$D"
  local ver
  # shellcheck disable=SC2086  # $co is safe: empty or "-6"
  ver=$(curl $co -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
  [[ -z "$ver" ]] && die "无法获取最新版本号"
  local cur
  cur=$($SBB version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || true
  if [[ -n "$cur" && "$cur" == "$ver" ]]; then
    info "✅ 已是最新版本 v${cur}"
    return 1
  fi
  echo "🔖 新版本：v${ver}（当前：v${cur:-?}）"
  local kb=/usr/bin/sing-box
  [[ -f "$kb" ]] && cp "$kb" "${kb}.bak" || true
  local td
  td=$(mktemp -d)
  if [[ "$D" == "alpine" ]]; then
    # shellcheck disable=SC2086  # $co is safe: empty or "-6"
    curl $co -fL --connect-timeout 30 -o "$td/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.tar.gz" || die "下载失败"
    tar -xzf "$td/sb.tar.gz" -C "$td/"
    install -m 755 "$td/sing-box_${ver}_linux_${arch}/sing-box" /usr/bin/sing-box
  else
    # shellcheck disable=SC2086  # $co is safe: empty or "-6"
    curl $co -fL --connect-timeout 30 -o "$td/sb.deb" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.deb" || die "下载失败"
    dpkg -i "$td/sb.deb" || { apt-get install -f -y && dpkg -i "$td/sb.deb"; } || die "安装失败"
  fi
  rm -rf "$td"
  info "✅ Sing-box: $($SBB version | head -1)"
}

sb_update_bin() {
  _sb_fetch_bin || return 0
  printf "${C}===== 重启已运行服务 =====${NC}\n"
  local _restarted=() _failed=false
  for s in sing-box sing-box-hy2 sing-box-tuic sing-box-at sing-box-ss sing-box-trojan; do
    if _svc "$s" is_active; then
      _svc "$s" restart
      _restarted+=("$s")
      info "✅ 已重启 $s"
    fi
  done
  sleep 2
  for s in "${_restarted[@]}"; do
    if ! _svc "$s" is_active; then
      warn "⚠ $s 重启后未运行，下面是日志："
      _svc "$s" status 2>/dev/null
      journalctl -u "$s" --no-pager -n 15 2>/dev/null || true
      _failed=true
    fi
  done
  if $_failed; then
    warn "检测到服务异常，正在自动回退..."
    if mv /usr/bin/sing-box.bak /usr/bin/sing-box; then info "✅ 已回退内核"; else warn "回退失败"; fi
    for s in "${_restarted[@]}"; do _svc "$s" restart; done
    warn "内核更新后服务异常，已自动回退原版本"
    return 1
  fi
}

sb_derive_pubkey() {
  local cfg=${1:-$SBC}
  [[ -f "$cfg" ]] || {
    warn "config.json 不存在"
    return 1
  }
  _need_py
  local pk
  pk=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c['inbounds'][0]['tls']['reality']['private_key'])" "$cfg")
  PRIV_B64URL="$pk" python3 <<'PYEOF'
import base64,os,subprocess,tempfile,sys
b=os.environ['PRIV_B64URL'].replace('-','+').replace('_','/'); b+='='*(-len(b)%4)
pb=base64.b64decode(b); der=bytes.fromhex("302e020100300506032b656e04220420")+pb
with tempfile.NamedTemporaryFile(suffix='.der',delete=False) as f: f.write(der); t=f.name
try:
 r=subprocess.run(['openssl','pkey','-inform','DER','-in',t,'-pubout','-outform','DER'],capture_output=True)
 if r.returncode!=0: print(r.stderr.decode(),file=sys.stderr); sys.exit(1)
 print(base64.urlsafe_b64encode(r.stdout[-32:]).rstrip(b'=').decode())
finally: os.unlink(t)
PYEOF
}

sb_install() {
  printf "${C}===== 安装 Reality =====${NC}\n"
  local name sni port
  _ask "用户名称（例如 AK-JP-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask "SNI 域名（默认: s0.awsstatic.com）：" sni
  sni=${sni:-s0.awsstatic.com}
  while true; do
    _ask "监听端口（默认: 443）：" port
    port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || {
      warn "端口无效"
      continue
    }
    _port_in_use "$port" && {
      warn "端口 $port 已被占用，请换一个"
      continue
    }
    break
  done
  sb_update_bin
  hash -r
  _need openssl
  local uuid keypair
  uuid=$($SBB generate uuid)
  keypair=$($SBB generate reality-keypair)
  local priv
  priv=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  local sid
  sid=$(openssl rand -hex 8)
  local n
  n=$(_net)
  local dns s
  # shellcheck disable=SC2015
  [[ "$n" == "ipv6" ]] && {
    dns="2606:4700:4700::1111"
    s="prefer_ipv6"
  } || {
    dns="8.8.8.8"
    s="prefer_ipv4"
  }
  mkdir -p "$SBD"
  cat >"$SBC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "dns": {
    "servers": [
      {
        "type": "tls",
        "server": "${dns}",
        "server_port": 853,
        "tls": { "min_version": "1.2" }
      }
    ],
    "strategy": "${s}"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESSReality",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        { "name": "${name}", "uuid": "${uuid}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${sni}", "server_port": 443 },
          "private_key": "${priv}",
          "short_id": "${sid}"
        }
      }
    }
  ],
  "route": {
    "rules": [ { "type": "default", "outbound": "direct" } ]
  },
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  chmod 600 "$SBC"
  [[ "$D" == "alpine" ]] && _sb_openrc
  _svc "$SBS" enable
  _svc "$SBS" restart
  sleep 2
  if _svc "$SBS" is_active; then
    info "✅ 安装完成"
    sb_show_link
  else
    warn "启动失败"
    return 1
  fi
}

sb_status() { _proto_action "$SBS" "Reality" status; }
sb_start() { _proto_action "$SBS" "Reality" start; }
sb_stop() { _proto_action "$SBS" "Reality" stop; }

sb_show_link() {
  printf "${C}===== VLESS Reality 链接 =====${NC}\n"
  [[ -f "$SBC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$SBC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]; r=ib['tls']['reality']
print(ib['users'][0]['name']); print(ib['users'][0]['uuid']); print(ib['tls']['server_name'])
print(r['short_id']); print(ib['listen_port'])
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local name="${L[0]}" uuid="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
  local pk
  pk=$(sb_derive_pubkey)
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "vless://${uuid}@${ip4}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "vless://${uuid}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "vless://${uuid}@${ip4}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  [[ -n "$ip6" ]] && _qr "vless://${uuid}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}-v6"
}

sb_uninstall() {
  printf "${C}===== 卸载 Reality =====${NC}\n"
  _svc "$SBS" stop
  _svc "$SBS" disable
  # shellcheck disable=SC2015
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box || {
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
  }
  rm -rf "$SBD"
  info "✅ 卸载完成"
}
sb_reinstall() {
  sb_uninstall
  sb_install
}

sb_change_sni() {
  printf "${C}===== 更换 SNI =====${NC}\n"
  [[ -f "$SBC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local cs
  cs=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['inbounds'][0]['tls']['server_name'])" "$SBC")
  local ns
  _ask "新 SNI（当前：${cs}）：" ns
  [[ -z "$ns" ]] && {
    warn "已取消"
    return 1
  }
  NEW_SNI="$ns" SBC="$SBC" python3 <<'PYEOF'
import json,os
with open(os.environ['SBC']) as f: c=json.load(f)
c['inbounds'][0]['tls']['server_name']=os.environ['NEW_SNI']
c['inbounds'][0]['tls']['reality']['handshake']['server']=os.environ['NEW_SNI']
with open(os.environ['SBC'],'w',encoding='utf-8') as f: json.dump(c,f,indent=2,ensure_ascii=False)
PYEOF
  if _svc "$SBS" restart; then info "✅ SNI → $ns"; else warn "重启失败"; fi
}

_sb_menu() {
  echo "安装并开启|sb_install"
  echo "查看状态|sb_status"
  echo "显示节点链接|sb_show_link"
  echo "开启服务|sb_start"
  echo "停止服务|sb_stop"
  echo "卸载服务|sb_uninstall"
  echo "重新安装|sb_reinstall"
  echo "更换 SNI|sb_change_sni"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Hysteria 2
# ═══════════════════════════════════════════════════════════════
HYD=/etc/sing-box-hy2
HYC="$HYD/config.json"
HYS=sing-box-hy2

hy_install() {
  printf "${C}===== 安装 Hysteria 2（Sing-box）=====${NC}\n"
  local pw port mu name
  _ask "节点名称（例如 JP-HY-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask_password
  _ask_port 2333
  _ask "伪装网址（默认: https://cn.bing.com/）：" mu
  mu=${mu:-https://cn.bing.com/}
  history -c 2>/dev/null || true
  export HISTFILE="/dev/null"
  _ensure_sb
  _need openssl

  mkdir -p "$HYD"
  printf "${C}生成自签名证书...${NC}\n"
  local _cn
  _cn=$(echo "$mu" | sed 's|^https\?://||; s|[:/].*||')
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$HYD/server.key" -out "$HYD/server.crt" -subj "/CN=${_cn}" -days 3650 || die "证书生成失败"
  chmod 600 "$HYD/server.key"

  cat >"$HYC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        { "name": "${name}", "password": "${pw}" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${HYD}/server.crt",
        "key_path": "${HYD}/server.key"
      },
      "masquerade": "${mu}"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$HYC"

  if [[ "$D" == "alpine" ]]; then _write_openrc "$HYS" "sing-box Hysteria2 service" "$HYD"; else _write_systemd "$HYS" "sing-box Hysteria2 service" "$HYD"; fi
  _svc "$HYS" enable
  _svc "$HYS" restart
  sleep 2
  if _svc "$HYS" is_active; then
    info "✅ 安装完成"
    hy_show_link
  else
    warn "启动失败"
    return 1
  fi
}

hy_status() { _proto_action "$HYS" "Hysteria 2" status; }
hy_start() { _proto_action "$HYS" "Hysteria 2" start; }
hy_stop() { _proto_action "$HYS" "Hysteria 2" stop; }

hy_show_link() {
  printf "${C}===== Hysteria 2 链接 =====${NC}\n"
  [[ -f "$HYC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$HYC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local pw="${L[0]}" port="${L[1]}" nm="${L[2]}"
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -z "$nm" ]] && nm="Hysteria2"
  local en
  en=$(_url_enc "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "hysteria2://${pw}@${ip4}:${port}?insecure=1#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "hysteria2://${pw}@[${ip6}]:${port}?insecure=1#${en}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "hysteria2://${pw}@${ip4}:${port}?insecure=1#${en}"
  [[ -n "$ip6" ]] && _qr "hysteria2://${pw}@[${ip6}]:${port}?insecure=1#${en}-v6"
}

hy_uninstall() { _proto_uninstall "$HYS" "$HYD" "$HYS" "Hysteria 2"; }
hy_reinstall() {
  hy_uninstall
  hy_install
}

_hy_menu() {
  echo "安装并开启|hy_install"
  echo "查看状态|hy_status"
  echo "显示节点链接|hy_show_link"
  echo "开启服务|hy_start"
  echo "停止服务|hy_stop"
  echo "卸载服务|hy_uninstall"
  echo "重新安装|hy_reinstall"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：TUIC
# ═══════════════════════════════════════════════════════════════
TUID=/etc/sing-box-tuic
TUIC="$TUID/config.json"
TUIS=sing-box-tuic

tuic_install() {
  printf "${C}===== 安装 TUIC（Sing-box）=====${NC}\n"
  local pw port sni name
  _ask "节点名称（例如 JP-TUIC-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask_password
  _ask_port 8443
  _ask "TLS 域名（默认: bing.com）：" sni
  sni=${sni:-bing.com}
  history -c 2>/dev/null || true
  export HISTFILE="/dev/null"
  _ensure_sb
  _need openssl

  local uuid
  uuid=$(sing-box generate uuid)
  mkdir -p "$TUID"
  printf "${C}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$TUID/server.key" -out "$TUID/server.crt" -subj "/CN=${sni}" -days 3650 || die "证书生成失败"
  chmod 600 "$TUID/server.key"

  cat >"$TUIC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "name": "${name}",
          "uuid": "${uuid}",
          "password": "${pw}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "alpn": ["h3"],
        "certificate_path": "${TUID}/server.crt",
        "key_path": "${TUID}/server.key"
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$TUIC"

  if [[ "$D" == "alpine" ]]; then _write_openrc "$TUIS" "sing-box TUIC service" "$TUID"; else _write_systemd "$TUIS" "sing-box TUIC service" "$TUID"; fi
  _svc "$TUIS" enable
  _svc "$TUIS" restart
  sleep 2
  if _svc "$TUIS" is_active; then
    info "✅ 安装完成"
    tuic_show_link
  else
    warn "启动失败"
    return 1
  fi
}

tuic_status() { _proto_action "$TUIS" "TUIC" status; }
tuic_start() { _proto_action "$TUIS" "TUIC" start; }
tuic_stop() { _proto_action "$TUIS" "TUIC" stop; }

tuic_show_link() {
  printf "${C}===== TUIC 链接 =====${NC}\n"
  [[ -f "$TUIC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$TUIC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['uuid']); print(ib['users'][0]['password']); print(ib['tls']['server_name'])
print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local uuid="${L[0]}" pw="${L[1]}" sni="${L[2]}" port="${L[3]}" nm="${L[4]}"
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -z "$nm" ]] && nm="TUIC-${sni}"
  local en
  en=$(_url_enc "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "tuic://${uuid}:${pw}@${ip4}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "tuic://${uuid}:${pw}@[${ip6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "tuic://${uuid}:${pw}@${ip4}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}"
  [[ -n "$ip6" ]] && _qr "tuic://${uuid}:${pw}@[${ip6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}-v6"
}

tuic_uninstall() { _proto_uninstall "$TUIS" "$TUID" "$TUIS" "TUIC"; }
tuic_reinstall() {
  tuic_uninstall
  tuic_install
}

_tuic_menu() {
  echo "安装并开启|tuic_install"
  echo "查看状态|tuic_status"
  echo "显示节点链接|tuic_show_link"
  echo "开启服务|tuic_start"
  echo "停止服务|tuic_stop"
  echo "卸载服务|tuic_uninstall"
  echo "重新安装|tuic_reinstall"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：AnyTLS Reality
# ═══════════════════════════════════════════════════════════════
ATD=/etc/sing-box-at
ATC="$ATD/config.json"
ATS=sing-box-at

at_install() {
  printf "${C}===== 安装 AnyTLS (Reality) =====${NC}\n"
  local port sni name
  _ask "节点名称（例如 JP-AT-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask_port 443
  _ask "SNI 域名（默认: yahoo.com）：" sni
  sni=${sni:-yahoo.com}
  _ensure_sb
  _need openssl

  mkdir -p "$ATD"
  local password
  password=$(openssl rand -base64 16)
  local keypair
  keypair=$(sing-box generate reality-keypair)
  local priv
  priv=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  local sid
  sid=$(openssl rand -hex 8)

  cat >"$ATC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "name": "${name}",
          "password": "${password}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${sni}", "server_port": 443 },
          "private_key": "${priv}",
          "short_id": "${sid}"
        }
      }
    }
  ],
  "route": {
    "final": "direct"
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$ATC"

  if [[ "$D" == "alpine" ]]; then _write_openrc "$ATS" "sing-box AnyTLS service" "$ATD"; else _write_systemd "$ATS" "sing-box AnyTLS service" "$ATD"; fi
  _svc "$ATS" enable
  _svc "$ATS" restart
  sleep 2
  if _svc "$ATS" is_active; then
    info "✅ 安装完成"
    at_show_link
  else
    warn "启动失败"
    return 1
  fi
}

at_status() { _proto_action "$ATS" "AnyTLS" status; }
at_start() { _proto_action "$ATS" "AnyTLS" start; }
at_stop() { _proto_action "$ATS" "AnyTLS" stop; }

at_show_link() {
  printf "${C}===== AnyTLS 配置 =====${NC}\n"
  [[ -f "$ATC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$ATC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['users'][0].get('name',''))
print(ib['tls']['server_name']); print(ib['tls']['reality']['short_id']); print(ib['listen_port'])
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local pwd="${L[0]}" nm="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
  local pk
  pk=$(sb_derive_pubkey "$ATC")
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -z "$nm" ]] && nm="AnyTLS-${sni}"
  local en
  en=$(_url_enc "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "anytls://${pwd}@${ip4}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "anytls://${pwd}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "anytls://${pwd}@${ip4}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}"
  [[ -n "$ip6" ]] && _qr "anytls://${pwd}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}-v6"

  printf "${C}===== Sing-box 客户端参考配置 =====${NC}\n"
  cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${ip4:-${ip6}}",
  "server_port": ${port},
  "password": "${pwd}",
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "insecure": false,
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${pk}",
      "short_id": "${sid}"
    }
  }
}
EOF
}

at_uninstall() { _proto_uninstall "$ATS" "$ATD" "$ATS" "AnyTLS"; }
at_reinstall() {
  at_uninstall
  at_install
}

_at_menu() {
  echo "安装并开启|at_install"
  echo "查看状态|at_status"
  echo "显示节点链接|at_show_link"
  echo "开启服务|at_start"
  echo "停止服务|at_stop"
  echo "卸载服务|at_uninstall"
  echo "重新安装|at_reinstall"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Shadowsocks
# ═══════════════════════════════════════════════════════════════
SSD=/etc/sing-box-ss
SSC="$SSD/config.json"
SSS=sing-box-ss

ss_install() {
  printf "${C}===== 安装 Shadowsocks（Sing-box）=====${NC}\n"
  local port name
  _ask "节点名称（例如 JP-SS-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask_port 8388
  _ensure_sb

  mkdir -p "$SSD"
  local password
  password=$(sing-box generate rand --base64 16)

  cat >"$SSC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${password}",
      "users": [
        {
          "name": "${name}",
          "password": "${password}"
        }
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$SSC"

  if [[ "$D" == "alpine" ]]; then _write_openrc "$SSS" "sing-box Shadowsocks service" "$SSD"; else _write_systemd "$SSS" "sing-box Shadowsocks service" "$SSD"; fi
  _svc "$SSS" enable
  _svc "$SSS" restart
  sleep 2
  if _svc "$SSS" is_active; then
    info "✅ 安装完成"
    ss_show_link
  else
    warn "启动失败"
    return 1
  fi
}

ss_status() { _proto_action "$SSS" "Shadowsocks" status; }
ss_start() { _proto_action "$SSS" "Shadowsocks" start; }
ss_stop() { _proto_action "$SSS" "Shadowsocks" stop; }

ss_show_link() {
  printf "${C}===== Shadowsocks 链接 =====${NC}\n"
  [[ -f "$SSC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$SSC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['password']); print(ib['listen_port']); print(ib['method'])
u=ib.get('users',[{}]); print(u[0].get('name',''))
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local pwd="${L[0]}" port="${L[1]}" method="${L[2]}" nm="${L[3]}"
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -z "$nm" ]] && nm="Shadowsocks"
  local en
  en=$(_url_enc "$nm")
  local ss_enc
  ss_enc=$(printf "%s:%s" "$method" "$pwd" | openssl base64 -A)
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "ss://${ss_enc}@${ip4}:${port}#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "ss://${ss_enc}@[${ip6}]:${port}#${en}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "ss://${ss_enc}@${ip4}:${port}#${en}"
  [[ -n "$ip6" ]] && _qr "ss://${ss_enc}@[${ip6}]:${port}#${en}-v6"
}

ss_uninstall() { _proto_uninstall "$SSS" "$SSD" "$SSS" "Shadowsocks"; }
ss_reinstall() {
  ss_uninstall
  ss_install
}

_ss_menu() {
  echo "安装并开启|ss_install"
  echo "查看状态|ss_status"
  echo "显示节点链接|ss_show_link"
  echo "开启服务|ss_start"
  echo "停止服务|ss_stop"
  echo "卸载服务|ss_uninstall"
  echo "重新安装|ss_reinstall"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Trojan
# ═══════════════════════════════════════════════════════════════
TRD=/etc/sing-box-trojan
TRC="$TRD/config.json"
TRS=sing-box-trojan

tr_install() {
  printf "${C}===== 安装 Trojan（Sing-box）=====${NC}\n"
  local pw port sni name
  _ask "节点名称（例如 JP-TR-100G）：" name
  [[ -z "$name" ]] && die "名称不能为空"
  _ask_password
  _ask_port 443
  _ask "TLS 域名：" sni
  [[ -z "$sni" ]] && die "域名不能为空"
  history -c 2>/dev/null || true
  export HISTFILE="/dev/null"
  _ensure_sb
  _need openssl

  mkdir -p "$TRD"
  local cert_type
  printf "${C}证书类型：${NC}\n"
  printf "  ${Y}1)${NC} 自签名证书（快速，无需额外配置，客户端需跳过验证）\n"
  printf "  ${Y}2)${NC} Let's Encrypt（需：域名解析到本机 + 80 端口开放 + 非 NAT/内网）\n"
  while true; do
    printf "${BD}选择 [1-2]: ${NC}"
    read -r cert_type
    echo
    # shellcheck disable=SC2015
    [[ "$cert_type" == "1" || "$cert_type" == "2" ]] && break || warn "无效选项"
  done

  local use_le=0
  if [[ "$cert_type" == "2" ]]; then
    local port_le
    for port_le in 80 8080; do
      if ! _port_in_use $port_le; then break; fi
      port_le=""
    done
    if [[ -z "$port_le" ]]; then
      warn "80 和 8080 端口均被占用，Let's Encrypt 申请需要 80 端口"
      local c
      _ask "回退使用自签名证书？(y/n): " c
      [[ "$c" =~ ^[Yy]$ ]] || {
        info "已取消安装"
        return 1
      }
    else
      use_le=1
      printf "${C}sing-box 将自动申请 Let's Encrypt 证书（使用端口 ${port_le:-80}）${NC}\n"
    fi
  fi

  if [[ "$use_le" == "1" ]]; then
    echo "1" >"$TRD/.use_le"
    tr_write_config "$sni" "$port" "$name" "$pw" "le"
    if [[ "$D" == "alpine" ]]; then _write_openrc "$TRS" "sing-box Trojan service" "$TRD"; else _write_systemd "$TRS" "sing-box Trojan service" "$TRD"; fi
    _svc "$TRS" enable
    _svc "$TRS" restart
    sleep 2
    local acme_ok=0
    for i in $(seq 1 30); do
      sleep 2
      if _svc "$TRS" is_active 2>/dev/null && [[ -n "$(ls -A "$TRD/tls" 2>/dev/null)" ]]; then
        acme_ok=1
        break
      fi
    done
    if [[ "$acme_ok" == "1" ]]; then
      printf "${G}✅ Let's Encrypt 证书申请成功${NC}\n"
      echo "1" >"$TRD/.use_le"
      info "✅ 安装完成"
      tr_show_link
      return 0
    fi
    warn "ACME 申请失败（频率限制/域名未解析/端口不可达），回退自签名..."
    use_le=0
  fi

  printf "${C}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$TRD/server.key" -out "$TRD/server.crt" -subj "/CN=${sni}" -days 3650 || die "证书生成失败"
  chmod 600 "$TRD/server.key"
  echo "0" >"$TRD/.use_le"
  tr_write_config "$sni" "$port" "$name" "$pw" "self"

  if [[ "$D" == "alpine" ]]; then _write_openrc "$TRS" "sing-box Trojan service" "$TRD"; else _write_systemd "$TRS" "sing-box Trojan service" "$TRD"; fi
  _svc "$TRS" enable
  _svc "$TRS" restart
  sleep 2
  if _svc "$TRS" is_active; then
    info "✅ 安装完成"
    tr_show_link
  else
    warn "启动失败"
    return 1
  fi
}

tr_write_config() {
  local sni=$1 port=$2 name=$3 pw=$4 mode=$5
  if [[ "$mode" == "le" ]]; then
    cat >"$TRC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        { "name": "${name}", "password": "${pw}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "acme": {
          "domain": ["${sni}"],
          "data_directory": "${TRD}/tls"
        }
      },
      "multiplex": { "enabled": true }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  else
    cat >"$TRC" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        { "name": "${name}", "password": "${pw}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "certificate_path": "${TRD}/server.crt",
        "key_path": "${TRD}/server.key"
      },
      "multiplex": { "enabled": true }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  fi
  chmod 600 "$TRC"
}

tr_status() { _proto_action "$TRS" "Trojan" status; }
tr_start() { _proto_action "$TRS" "Trojan" start; }
tr_stop() { _proto_action "$TRS" "Trojan" stop; }

tr_show_link() {
  printf "${C}===== Trojan 链接 =====${NC}\n"
  [[ -f "$TRC" ]] || {
    warn "配置文件不存在"
    return 1
  }
  _need_py
  local f
  f=$(
    python3 - "$TRC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
u=ib['users'][0]; print(u['password']); print(u.get('name',''))
print(ib['tls']['server_name']); print(ib['listen_port'])
PYEOF
  ) || {
    warn "读取失败"
    return 1
  }
  mapfile -t L <<<"$f"
  local pw="${L[0]}" nm="${L[1]}" sni="${L[2]}" port="${L[3]}"
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && {
    warn "无法获取 IP"
    return 1
  }
  [[ -z "$nm" ]] && nm="Trojan-${sni}"
  local en
  en=$(_url_enc "$nm")
  local use_le
  use_le=$(cat "$TRD/.use_le" 2>/dev/null || echo "0")
  local insecure
  [[ "$use_le" != "1" ]] && insecure="allowInsecure=1&"
  local cert_info
  [[ "$use_le" == "1" ]] && cert_info="${G}[Let's Encrypt]${NC}" || cert_info="${Y}[自签名]${NC}"
  printf "%s %s\n" "$cert_info" "链接："
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "trojan://${pw}@${ip4}:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "trojan://${pw}@[${ip6}]:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}-v6"
  echo
  [[ -n "$ip4" ]] && _qr "trojan://${pw}@${ip4}:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}"
  [[ -n "$ip6" ]] && _qr "trojan://${pw}@[${ip6}]:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}-v6"
}

tr_uninstall() { _proto_uninstall "$TRS" "$TRD" "$TRS" "Trojan"; }
tr_reinstall() {
  tr_uninstall
  tr_install
}

_tr_menu() {
  echo "安装并开启|tr_install"
  echo "查看状态|tr_status"
  echo "显示节点链接|tr_show_link"
  echo "开启服务|tr_start"
  echo "停止服务|tr_stop"
  echo "卸载服务|tr_uninstall"
  echo "重新安装|tr_reinstall"
}

# ═══════════════════════════════════════════════════════════════
#  模块注册（新增协议只需加一行 + 实现同模板的模块）
# ═══════════════════════════════════════════════════════════════
# 格式: "id|标题|版本函数"
MODULES=(
  "sb|Reality|_sb_ver"
  "hy|Hysteria2|_sb_ver"
  "tuic|TUIC|_sb_ver"
  "at|AnyTLS|_sb_ver"
  "ss|Shadowsocks|_sb_ver"
  "tr|Trojan|_sb_ver"
)

# ═══════════════════════════════════════════════════════════════
#  服务子菜单（通用）
# ═══════════════════════════════════════════════════════════════
_svc_menu() {
  local id=$1 title=$2 verfn=$3
  while true; do
    printf "\n${C}===== %s (%s) =====${NC}\n" "$title" "$($verfn)"
    local i=1
    local -a callbacks=()
    while IFS='|' read -r lb cb; do
      [[ -z "$lb" ]] && continue
      printf "  ${Y}%2d)${NC} %s\n" "$i" "$lb"
      callbacks+=("$cb")
      ((i++))
    done < <("_${id}_menu")
    printf "  ${Y} 0)${NC} 返回上级\n"
    printf "${BD}选择 [0-$((i - 1))]: ${NC}"
    read -r ch
    echo
    [[ "$ch" == "0" ]] && return
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -ge 1 && "$ch" -le ${#callbacks[@]} ]]; then
      ${callbacks[$((ch - 1))]}
    else warn "无效选项"; fi
  done
}

# ═══════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════
_sb_installed() { _proto_installed "$SBC"; }
_hy_installed() { _proto_installed "$HYC"; }
_tuic_installed() { _proto_installed "$TUIC"; }
_at_installed() { _proto_installed "$ATC"; }
_ss_installed() { _proto_installed "$SSC"; }
_tr_installed() { _proto_installed "$TRC"; }

uninstall_all() {
  printf "${C}===== 卸载脚本及所有相关文件 =====${NC}\n"
  local c
  _ask "确认卸载所有协议、二进制和脚本？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || {
    echo "取消"
    return
  }

  sb_uninstall 2>/dev/null || true
  hy_uninstall 2>/dev/null || true
  tuic_uninstall 2>/dev/null || true
  at_uninstall 2>/dev/null || true
  ss_uninstall 2>/dev/null || true
  tr_uninstall 2>/dev/null || true

  rm -f /usr/bin/sing-box /usr/local/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box-tuic.service
  rm -f /etc/systemd/system/sing-box-hy2.service /etc/systemd/system/sing-box-at.service /etc/systemd/system/sing-box-ss.service /etc/systemd/system/sing-box-trojan.service
  rm -f /etc/init.d/sing-box /etc/init.d/sing-box-tuic /etc/init.d/sing-box-hy2 /etc/init.d/sing-box-at /etc/init.d/sing-box-ss /etc/init.d/sing-box-trojan
  systemctl disable --now aio-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/aio-update.service /etc/systemd/system/aio-update.timer
  hash -r 2>/dev/null || true

  rm -f /usr/local/bin/aio
  local sp="${BASH_SOURCE[0]}"
  info "✅ 卸载完成，脚本即将自毁。"
  rm -f "$sp"
  exit 0
}

# ═══════════════════════════════════════════════════════════════
#  Subhatch 上传
# ═══════════════════════════════════════════════════════════════
SUBHATCH_CFG=/etc/sing-box/.subhatch

_collect_node_uris() {
  # 输出格式: proto|name|uri, 每个已安装协议每个 IP 栈各一行
  local ip4 ip6
  read -r ip4 ip6 <<<"$(_get_ips)"

  # Reality
  if [[ -f "$SBC" ]]; then
    local f
    f=$(
      python3 - "$SBC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]; r=ib['tls']['reality']
print(ib['users'][0]['name']); print(ib['users'][0]['uuid']); print(ib['tls']['server_name'])
print(r['short_id']); print(ib['listen_port'])
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local name="${L[0]}" uuid="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
      local pk
      pk=$(sb_derive_pubkey) || true
      if [[ -n "$pk" ]]; then
        local en
        en=$(_url_enc "$name")
        [[ -n "$ip4" ]] && echo "REALITY|${name}|vless://${uuid}@${ip4}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${en}"
        [[ -n "$ip6" ]] && echo "REALITY|${name}-v6|vless://${uuid}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${en}-v6"
      else
        warn "跳过 Reality ${name}: 无法派生公钥 (openssl 可能未安装)"
      fi
    }
  fi

  # Hysteria2
  if [[ -f "$HYC" ]]; then
    local f
    f=$(
      python3 - "$HYC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local pw="${L[0]}" port="${L[1]}" nm="${L[2]}"
      [[ -z "$nm" ]] && nm="Hysteria2"
      local en
      en=$(_url_enc "$nm")
      [[ -n "$ip4" ]] && echo "HY2|${nm}|hysteria2://${pw}@${ip4}:${port}?insecure=1#${en}"
      [[ -n "$ip6" ]] && echo "HY2|${nm}-v6|hysteria2://${pw}@[${ip6}]:${port}?insecure=1#${en}-v6"
    }
  fi

  # TUIC
  if [[ -f "$TUIC" ]]; then
    local f
    f=$(
      python3 - "$TUIC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['uuid']); print(ib['users'][0]['password']); print(ib['tls']['server_name'])
print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local uuid="${L[0]}" pw="${L[1]}" sni="${L[2]}" port="${L[3]}" nm="${L[4]}"
      [[ -z "$nm" ]] && nm="TUIC-${sni}"
      local en
      en=$(_url_enc "$nm")
      [[ -n "$ip4" ]] && echo "TUIC|${nm}|tuic://${uuid}:${pw}@${ip4}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}"
      [[ -n "$ip6" ]] && echo "TUIC|${nm}-v6|tuic://${uuid}:${pw}@[${ip6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}-v6"
    }
  fi

  # AnyTLS
  if [[ -f "$ATC" ]]; then
    local f
    f=$(
      python3 - "$ATC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['users'][0].get('name',''))
print(ib['tls']['server_name']); print(ib['tls']['reality']['short_id']); print(ib['listen_port'])
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local pwd="${L[0]}" nm="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
      local pk
      pk=$(sb_derive_pubkey "$ATC") || true
      if [[ -n "$pk" ]]; then
        [[ -z "$nm" ]] && nm="AnyTLS-${sni}"
        local en
        en=$(_url_enc "$nm")
        [[ -n "$ip4" ]] && echo "AT|${nm}|anytls://${pwd}@${ip4}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}"
        [[ -n "$ip6" ]] && echo "AT|${nm}-v6|anytls://${pwd}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}-v6"
      else
        warn "跳过 AnyTLS ${nm:-AnyTLS-${sni}}: 无法派生公钥"
      fi
    }
  fi

  # Shadowsocks
  if [[ -f "$SSC" ]]; then
    local f
    f=$(
      python3 - "$SSC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['password']); print(ib['listen_port']); print(ib['method'])
u=ib.get('users',[{}]); print(u[0].get('name',''))
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local pwd="${L[0]}" port="${L[1]}" method="${L[2]}" nm="${L[3]}"
      [[ -z "$nm" ]] && nm="Shadowsocks"
      local en
      en=$(_url_enc "$nm")
      local ss_enc
      ss_enc=$(python3 -c "import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())" "$method:$pwd" 2>/dev/null || true)
      [[ -n "$ss_enc" ]] && {
        [[ -n "$ip4" ]] && echo "SS|${nm}|ss://${ss_enc}@${ip4}:${port}#${en}"
        [[ -n "$ip6" ]] && echo "SS|${nm}-v6|ss://${ss_enc}@[${ip6}]:${port}#${en}-v6"
      }
    }
  fi

  # Trojan
  if [[ -f "$TRC" ]]; then
    local f
    f=$(
      python3 - "$TRC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
u=ib['users'][0]; print(u['password']); print(u.get('name',''))
print(ib['tls']['server_name']); print(ib['listen_port'])
PYEOF
    ) && {
      mapfile -t L <<<"$f"
      local pw="${L[0]}" nm="${L[1]}" sni="${L[2]}" port="${L[3]}"
      [[ -z "$nm" ]] && nm="Trojan-${sni}"
      local en
      en=$(_url_enc "$nm")
      local insecure=""
      [[ "$(cat "$TRD/.use_le" 2>/dev/null || echo 0)" != "1" ]] && insecure="allowInsecure=1&"
      [[ -n "$ip4" ]] && echo "TJ|${nm}|trojan://${pw}@${ip4}:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}"
      [[ -n "$ip6" ]] && echo "TJ|${nm}-v6|trojan://${pw}@[${ip6}]:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}-v6"
    }
  fi
}

_subhatch_upload() {
  printf "${C}===== 上传链接到 Subhatch =====${NC}\n"
  _need_py
  _need curl

  # 读取/询问 subhatch 配置
  local SH_URL="" SH_TOKEN="" NEED_PROMPT=1
  if [[ -f "$SUBHATCH_CFG" ]]; then
    # shellcheck source=/dev/null
    source "$SUBHATCH_CFG" 2>/dev/null || true
  fi
  if [[ -n "$SH_URL" && -n "$SH_TOKEN" ]]; then
    printf "${G}已保存: %s | Token: ***${NC}\n" "$SH_URL"
    local use_saved
    _ask "沿用已保存配置？[Y/n]" use_saved
    [[ "${use_saved,,}" != "n" ]] && {
      info "沿用已保存的 Subhatch 配置"
      NEED_PROMPT=0
    }
  fi
  if [[ "$NEED_PROMPT" == "1" ]]; then
    _ask "Subhatch 地址（如 https://sub.example.com）：" SH_URL
    [[ -z "$SH_URL" ]] && {
      warn "已取消"
      return 1
    }
    SH_URL="${SH_URL%/}"
    _ask "Upload Token：" SH_TOKEN
    [[ -z "$SH_TOKEN" ]] && {
      warn "已取消"
      return 1
    }
    local save
    _ask "保存配置以便下次使用？[Y/n]" save
    [[ "${save,,}" != "n" ]] && printf '# WARNING: token stored as plaintext (chmod 600 enforced)\nSH_URL=%q\nSH_TOKEN=%q\n' "$SH_URL" "$SH_TOKEN" >"$SUBHATCH_CFG" && chmod 600 "$SUBHATCH_CFG"
  fi

  # 收集本地链接
  info "正在收集已安装的节点链接..."
  local links=() labels=() uris=()
  while IFS='|' read -r proto label uri; do
    [[ -z "$uri" ]] && continue
    links+=("$proto|$label|$uri")
    labels+=("$label")
    uris+=("$uri")
  done < <(_collect_node_uris)

  if [[ ${#uris[@]} -eq 0 ]]; then
    warn "没有已安装的节点链接"
    return 1
  fi

  # 显示选择菜单
  printf "\n${BD}${B}可上传的节点：${NC}\n"
  local i
  for ((i = 0; i < ${#uris[@]}; i++)); do
    local proto="${links[$i]%%|*}"
    printf "  ${Y}%2d)${NC} [${G}%s${NC}] %s\n" "$((i + 1))" "$proto" "${labels[$i]}"
  done
  printf "  ${Y} a)${NC} 全部 (%d 个)\n" "${#uris[@]}"
  printf "  ${Y} 0)${NC} 返回\n"
  printf "${BD}选择（空格分隔多个）: ${NC}"
  read -r sel
  echo

  [[ "$sel" == "0" ]] && return 0

  local selected=()
  if [[ "${sel,,}" == "a" ]]; then
    selected=("${uris[@]}")
  else
    for s in $sel; do
      [[ "$s" =~ ^[0-9]+$ && $s -ge 1 && $s -le ${#uris[@]} ]] && selected+=("${uris[$((s - 1))]}")
    done
  fi

  if [[ ${#selected[@]} -eq 0 ]]; then
    warn "未选择任何节点"
    return 1
  fi

  # 调用 POST /api/upload?token= — 服务端自动去重、处理重名、增量追加
  info "正在上传到 ${SH_URL}..."
  local nodes_json resp
  nodes_json=$(python3 -c "import json,sys;print(json.dumps(sys.argv[1:]))" "${selected[@]}") || {
    warn "生成 JSON 失败"
    return 1
  }
  resp=$(curl -s --connect-timeout 10 -w '\n%{http_code}' -X POST "${SH_URL}?token=${SH_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"nodes\":$nodes_json}" 2>&1) || {
    warn "上传失败: 网络连接错误"
    return 1
  }
  local http_code
  http_code=$(tail -1 <<<"$resp")
  resp=$(head -n -1 <<<"$resp")
  if [[ "$http_code" != "200" ]]; then
    warn "上传失败 (HTTP ${http_code}): ${resp}"
    return 1
  fi

  local added dupes
  added=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('added',0))" "$resp" 2>/dev/null || echo 0)
  dupes=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('dupes',0))" "$resp" 2>/dev/null || echo 0)
  info "✅ 上传完成（新增 ${added}，去重跳过 ${dupes}）"
}

# ═══════════════════════════════════════════════════════════════
#  DEV 功能
# ═══════════════════════════════════════════════════════════════
dev_auto_update() {
  printf "${C}===== DEV 自动更新 =====${NC}\n"
  local _err=0

  echo
  info "📦 更新内核..."
  if (sb_update_bin); then
    info "✅ 内核更新完成"
  else
    warn "内核更新失败"
    if [[ -f /usr/bin/sing-box.bak ]]; then
      if mv /usr/bin/sing-box.bak /usr/bin/sing-box; then
        info "✅ 已从备份回退内核"
      else
        warn "回退失败，请手动 mv /usr/bin/sing-box.bak /usr/bin/sing-box"
        _err=1
      fi
    else
      warn "无备份可回退"
      _err=1
    fi
  fi

  # 安装/刷新 systemd 定时器（必须在脚本更新之前，因为 update_self 会 exec）
  echo
  info "⏰ 刷新自动更新定时器..."
  _write_timer_units
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now aio-update.timer 2>/dev/null || true
  info "✅ 定时器已就绪（每天自动更新）"

  echo
  info "📜 更新脚本..."
  update_self || _err=1
  return $_err
}

_write_timer_units() {
  [[ "$D" == "alpine" ]] && return 0
  cat >/etc/systemd/system/aio-update.service <<'EOF'
[Unit]
Description=AIO auto-update script and kernel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/aio --auto-update
StandardOutput=journal
StandardError=journal
SyslogIdentifier=aio-update
EOF
  cat >/etc/systemd/system/aio-update.timer <<'EOF'
[Unit]
Description=AIO auto-update timer (daily)

[Timer]
OnCalendar=*-*-* 08:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

ecs_install() {
  printf "${C}===== 安装 ECS 测评工具 =====${NC}\n"
  local bin
  bin=$(command -v goecs 2>/dev/null || true)
  if [[ -n "$bin" ]]; then
    local v
    v=$("$bin" -v 2>/dev/null | head -1 || true)
    info "✅ ECS 已安装: ${bin} ${v:-}"
    printf "${G}使用命令: goecs -l=zh${NC}\n"
    return 0
  fi
  local url="https://raw.githubusercontent.com/oneclickvirt/ecs/master/goecs.sh"
  local tmp=/tmp/goecs.sh
  info "下载安装中..."
  # shellcheck disable=SC2046
  curl $(_co) -fsSL --connect-timeout 15 "$url" -o "$tmp" || die "下载失败"
  chmod +x "$tmp"
  export noninteractive=true
  bash "$tmp" install || {
    rm -f "$tmp"
    die "安装失败"
  }
  rm -f "$tmp"
  bin=$(command -v goecs 2>/dev/null || true)
  [[ -n "$bin" ]] || die "安装失败，请手动安装: curl -L https://raw.githubusercontent.com/oneclickvirt/ecs/master/goecs.sh -o goecs.sh && bash goecs.sh install"
  info "✅ ECS 安装完成"
  printf "${G}使用命令: goecs -l=zh${NC}\n"
}

ecs_uninstall() {
  printf "${C}===== 卸载 ECS 测评工具 =====${NC}\n"
  local bin
  bin=$(command -v goecs 2>/dev/null || true)
  [[ -z "$bin" ]] && {
    info "✅ ECS 未安装"
    return 0
  }
  rm -f "$bin" /usr/local/bin/goecs /usr/bin/goecs
  info "✅ ECS 已卸载"
}

reinstall_install() {
  printf "${C}===== 安装 reinstall 重装脚本 =====${NC}\n"
  local dst=/usr/local/bin/reinstall.sh
  if [[ -f "$dst" ]]; then
    info "✅ reinstall 已安装: $dst"
    printf "${G}使用命令: bash reinstall.sh <系统>${NC}\n"
    return 0
  fi
  local url="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
  info "下载中..."
  # shellcheck disable=SC2046
  curl $(_co) -fsSL --connect-timeout 15 "$url" -o "$dst" || die "下载失败"
  chmod +x "$dst"
  info "✅ reinstall 安装完成"
  printf "${G}使用命令: bash reinstall.sh <系统>${NC}\n"
  printf "${G}示例: bash reinstall.sh debian 12${NC}\n"
}

reinstall_uninstall() {
  printf "${C}===== 卸载 reinstall 重装脚本 =====${NC}\n"
  local dst=/usr/local/bin/reinstall.sh
  # shellcheck disable=SC2015
  [[ -f "$dst" ]] && {
    rm -f "$dst"
    info "✅ reinstall 已卸载"
  } || { info "✅ reinstall 未安装"; }
}

server_init() {
  printf "${C}===== 一键开荒 =====${NC}\n"
  [[ "$D" != "debian" ]] && {
    warn "仅支持 Debian/Ubuntu 系统"
    return 1
  }
  local c
  _ask "将执行: apt update/upgrade + 基础包 + BBR。继续？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || {
    echo "取消"
    return
  }

  info "正在 apt update..."
  apt update || die "apt update 失败"

  info "正在 apt upgrade..."
  DEBIAN_FRONTEND=noninteractive apt upgrade -y || warn "apt upgrade 失败，继续..."

  info "安装基础工具: sudo nano vim openssl curl neofetch"
  DEBIAN_FRONTEND=noninteractive apt install -y sudo nano vim openssl curl neofetch || warn "部分包安装失败"

  if grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
    sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
  else
    echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
  fi
  sysctl -p /etc/sysctl.conf 2>/dev/null || true
  local cur
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  info "✅ 开荒完成（拥塞控制: ${cur:-未知}）"
}

ssh_key_setup() {
  printf "${C}===== 更换为密钥登录 =====${NC}\n"
  local c
  _ask "将生成密钥对、写入 authorized_keys、关闭密码登录。继续？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || {
    echo "取消"
    return
  }

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  local keyfile=/root/.ssh/id_rsa
  if [[ -f "$keyfile" ]]; then
    printf "${Y}密钥 $keyfile 已存在${NC}\n"
    printf "私钥: %s  公钥: %s.pub\n" "$keyfile" "$keyfile"
    printf "${R}警告: 勿关闭当前会话，请确认已持有对应私钥${NC}\n"
    return 0
  fi
  ssh-keygen -t rsa -b 4096 -f "$keyfile" -N "" -q || die "密钥生成失败"
  chmod 600 "$keyfile"

  if ! grep -q -f "${keyfile}.pub" /root/.ssh/authorized_keys 2>/dev/null; then
    cat "${keyfile}.pub" >>/root/.ssh/authorized_keys
    info "公钥已写入 authorized_keys"
  else
    info "公钥已存在于 authorized_keys"
  fi
  chmod 600 /root/.ssh/authorized_keys

  local sshd_cfg=/etc/ssh/sshd_config
  [[ -f "$sshd_cfg" ]] || {
    warn "sshd_config 不存在，跳过 SSH 配置"
    return 1
  }
  cp "$sshd_cfg" "${sshd_cfg}.bak"
  sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_cfg"
  sed -i 's/^\s*#\?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_cfg"
  sed -i 's/^\s*#\?\s*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_cfg"
  grep -q "PubkeyAuthentication yes" "$sshd_cfg" || echo "PubkeyAuthentication yes" >>"$sshd_cfg"

  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || warn "SSH 服务重启失败"

  printf "\n${G}私钥内容（请保存到客户端 ~/.ssh/）:${NC}\n"
  cat "$keyfile"
  printf "\n${BD}公钥: %s.pub${NC}\n" "$keyfile"
  printf "${R}警告: 勿关闭当前会话，先在新终端测试密钥登录${NC}\n"
}

_dev_menu() {
  while true; do
    echo
    printf "${BD}${B}DEV 功能：${NC}"
    if systemctl is-active --quiet aio-update.timer 2>/dev/null; then
      printf " ${G}[自动更新已开启]${NC}"
    fi
    printf "\n"
    printf "  ${Y}1)${NC} 一键开荒\n"
    printf "  ${Y}2)${NC} 更换为密钥登录\n"
    printf "  ${Y}3)${NC} 上传到 Subhatch\n"
    printf "  ${Y}4)${NC} 安装 ECS 测评工具\n"
    printf "  ${Y}5)${NC} 卸载 ECS 测评工具\n"
    printf "  ${Y}6)${NC} 安装 reinstall 重装脚本\n"
    printf "  ${Y}7)${NC} 卸载 reinstall 重装脚本\n"
    printf "  ${Y}8)${NC} 开启自动更新\n"
    printf "  ${Y}9)${NC} 关闭自动更新\n"
    printf "  ${Y}10)${NC} 切换更新频道\n"
    printf "  ${Y} 0)${NC} 返回主菜单\n"
    printf "${BD}选择 [0-10]: ${NC}"
    read -r ch
    echo
    case "$ch" in 1)
      server_init
      return
      ;;
    2)
      ssh_key_setup
      return
      ;;
    3)
      _subhatch_upload
      return
      ;;
    4)
      ecs_install
      return
      ;;
    5)
      ecs_uninstall
      return
      ;;
    6)
      reinstall_install
      return
      ;;
    7)
      reinstall_uninstall
      return
      ;;
    8)
      dev_auto_update
      return
      ;;
    9)
      systemctl disable --now aio-update.timer 2>/dev/null || true
      info "✅ 自动更新已关闭"
      return
      ;;
    10)
      switch_channel
      return
      ;;
    0) return ;; *) warn "无效选项" ;; esac
  done
}

# 自动迁移旧 Trojan 服务名 (trajan → trojan)
_migrate_trojan() {
  local migrated=false
  # systemd
  if [[ -f /etc/systemd/system/sing-box-trajan.service ]]; then
    info "检测到旧 Trojan 服务名 (trajan)，正在迁移..."
    _svc sing-box-trajan stop 2>/dev/null || true
    _svc sing-box-trajan disable 2>/dev/null || true
    sed -i 's/sing-box-trajan/sing-box-trojan/g' /etc/systemd/system/sing-box-trajan.service
    mv /etc/systemd/system/sing-box-trajan.service /etc/systemd/system/sing-box-trojan.service
    systemctl daemon-reload
    migrated=true
  fi
  # Alpine
  if [[ -f /etc/init.d/sing-box-trajan ]]; then
    sed -i 's/sing-box-trajan/sing-box-trojan/g' /etc/init.d/sing-box-trajan
    mv /etc/init.d/sing-box-trajan /etc/init.d/sing-box-trojan
    migrated=true
  fi
  # 配置目录
  if [[ -d /etc/sing-box-trajan ]]; then
    mv /etc/sing-box-trajan /etc/sing-box-trojan
    migrated=true
  fi
  if $migrated; then
    info "✅ Trojan 服务已迁移至 trojan"
    if [[ -f /etc/sing-box-trojan/config.json ]]; then
      _svc sing-box-trojan enable
      _svc sing-box-trojan start
    fi
  fi
}

main() {
  _migrate_trojan
  # 自动更新模式（由 systemd timer 触发）
  if [[ "${1:-}" == "--auto-update" ]]; then
    AIO_AUTO=1
    echo "===== $(date +'%F %T') 自动更新开始 ====="
    if dev_auto_update; then
      echo "===== $(date +'%F %T') 自动更新完成 ====="
      exit 0
    else
      echo "===== $(date +'%F %T') 自动更新失败，请检查日志 =====" >&2
      exit 1
    fi
  fi
  # 首次安装软链接，之后直接输入 aio 即可启动
  local _resolved
  _resolved=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
  if [[ ! -L /usr/local/bin/aio ]]; then
    ln -sf "$_resolved" /usr/local/bin/aio && info "✅ 已注册 aio 命令，下次直接输入 aio 启动"
  elif [[ "$(readlink /usr/local/bin/aio)" != "$_resolved" ]]; then
    ln -sf "$_resolved" /usr/local/bin/aio
  fi

  _net >/dev/null || true

  clear
  printf "%b\n" "${BANNER//__CHANNEL__/ [$(_aio_channel)]}"

  local _kv
  _kv=$(_sb_ver)
  _kv=${_kv#sing-box version }
  _kv=${_kv:-未安装}
  printf "${B}内核 sing-box %s | 系统 %s | 网络 %s${NC}\n" "$_kv" "${D:-unknown}" "${_NC:-unknown}"

  # 异步检查更新（后台任务写结果到缓存文件）
  : >/tmp/.aio_script_update
  : >/tmp/.aio_sb_update
  { _check_script_update; } >/dev/null 2>&1 &
  { _check_sb_update; } >/dev/null 2>&1 &
  printf "${B}── 协议 ─────────────────────────────────────${NC}\n"
  printf "  %-13s %s   %-13s %s\n" "Reality:" "$(_sb_installed)" "AnyTLS:" "$(_at_installed)"
  printf "  %-13s %s   %-13s %s\n" "TUIC:" "$(_tuic_installed)" "Hysteria2:" "$(_hy_installed)"
  printf "  %-13s %s   %-13s %s\n" "Shadowsocks:" "$(_ss_installed)" "Trojan:" "$(_tr_installed)"
  printf "${B}─────────────────────────────────────────────${NC}\n"

  while true; do
    # 检查更新提示
    local _scr_new="" _sb_new=""
    [[ -f /tmp/.aio_script_update ]] && _scr_new=$(</tmp/.aio_script_update)
    [[ -f /tmp/.aio_sb_update ]] && _sb_new=$(</tmp/.aio_sb_update)
    [[ -n "$_scr_new" ]] && printf "${G}🎯 脚本有新版本 v%s → 选择「更新脚本」升级${NC}\n" "$_scr_new"
    [[ -n "$_sb_new" ]] && printf "${Y}📦 sing-box 有新版本 v%s → 选择「更新内核」升级${NC}\n" "$_sb_new"

    printf "\n${BD}${B}请选择服务：${NC}\n"
    local idx=1
    for mod in "${MODULES[@]}"; do
      IFS='|' read -r _ title _ <<<"$mod"
      printf "  ${Y}%2d)${NC} %s\n" "$idx" "$title"
      ((idx++))
    done
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "设置BBR"
    local bb=$idx
    ((idx++))
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "更新内核"
    local uk=$idx
    ((idx++))
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "更新脚本"
    local us=$idx
    ((idx++))
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "卸载脚本"
    local ua=$idx
    ((idx++))
    printf "  ${Y}%2d)${NC} %s" "$idx" "DEV功能"
    local dev=$idx
    ((idx++))
    systemctl is-active --quiet aio-update.timer 2>/dev/null && printf " ${G}[自动]${NC}"
    printf "\n"
    printf "  ${Y} 0)${NC} 退出\n"
    printf "${BD}选择 [0-$((idx - 1))]: ${NC}"
    read -r ch
    echo

    if [[ "$ch" == "0" ]]; then
      info "退出。"
      exit 0
    fi

    local sel=$ch found=false
    local mi=1
    for mod in "${MODULES[@]}"; do
      if [[ "$sel" == "$mi" ]]; then
        IFS='|' read -r id title verfn <<<"$mod"
        _svc_menu "$id" "$title" "$verfn"
        found=true
        break
      fi
      ((mi++))
    done
    $found && continue

    if [[ "$sel" == "$bb" ]]; then
      set_bbr
    elif [[ "$sel" == "$uk" ]]; then
      sb_update_bin
    elif [[ "$sel" == "$us" ]]; then
      update_self
    elif [[ "$sel" == "$ua" ]]; then
      uninstall_all
    elif [[ "$sel" == "$dev" ]]; then
      _dev_menu
    else warn "无效选项"; fi
  done
}

main "$@"
