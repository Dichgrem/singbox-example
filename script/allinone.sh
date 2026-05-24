#!/usr/bin/env bash
# allinone.sh — 多协议代理统一管理脚本
SCRIPT_VERSION="5.31.0"
set -uo pipefail

# ═══════════════════════════════════════════════════════════════
#  颜色（必须在一切输出之前定义，BANNER 会引用）
# ═══════════════════════════════════════════════════════════════
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; C=$'\033[36m'; BD=$'\033[1m'; NC=$'\033[0m'

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
     All in One Proxy Manager v5.31.0${NC}"

# ═══════════════════════════════════════════════════════════════
#  基础层（工具 / 发行版 / 包管理 / 网络）
# ═══════════════════════════════════════════════════════════════
die()  { printf "${R}错误：%s${NC}\n" "$*" >&2; exit 1; }
info() { printf "${G}%s${NC}\n" "$*"; }
warn() { printf "${Y}%s${NC}\n" "$*"; }
_ask() { printf "${BD}%s${NC}" "$1"; read -r "$2"; }

[[ $EUID -ne 0 ]] && die "请以 root 用户或使用 sudo 运行"

# 发行版检测
if   [[ -f /etc/alpine-release ]]; then D=alpine
elif command -v apt-get &>/dev/null; then D=debian
else D=unknown; fi

_pkg_i() { [[ "$D" == "alpine" ]] && apk add --no-cache "$@" || apt-get install -y "$@"; }
_pkg_u() { [[ "$D" == "alpine" ]] && apk update || apt-get update; }

_need() {
  local c=$1 p=${2:-$1}
  command -v "$c" &>/dev/null && return 0
  warn "未安装 $c，正在安装..."; _pkg_u && _pkg_i "$p" || die "$p 安装失败"
}
_need curl
_need_py() { _need python3 python3; }

# 网络检测（缓存）
_NC=""
_net() {
  [[ -n "$_NC" ]] && { echo "$_NC"; return; }
  local v4=false v6=false
  curl -4 -s --connect-timeout 3 https://api.ipify.org &>/dev/null && v4=true || true
  curl -6 -s --connect-timeout 3 https://api64.ipify.org &>/dev/null && v6=true || true
  $v4 && $v6 && _NC=dual || $v6 && _NC=ipv6 || $v4 && _NC=ipv4 || _NC=none
  echo "$_NC"
}
_co() { [[ "$(_net)" == "ipv6" ]] && echo "-6" || echo ""; }

# 获取所有可用 IP（v4 和 v6）
_get_ips() {
  local v4 v6
  v4=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
  v6=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null || true)
  echo "${v4:-} ${v6:-}"
}

# 端口冲突检测
_port_in_use() {
  local port=$1
  if command -v ss &>/dev/null; then
    ss -tulnp 2>/dev/null | grep -q ":${port} " && return 0
  elif command -v netstat &>/dev/null; then
    netstat -tulnp 2>/dev/null | grep -q ":${port} " && return 0
  elif [[ -f /proc/net/tcp ]]; then
    grep -q " $(printf '%04X' $port) " /proc/net/tcp 2>/dev/null && return 0
    grep -q " $(printf '%04X' $port) " /proc/net/udp 2>/dev/null && return 0
  fi
  return 1
}

# 通用服务管理
_svc() {
  local n=$1 a=$2
  if [[ "$D" == "alpine" ]]; then
    case "$a" in
      enable)  rc-update add "$n" default 2>/dev/null||true;; disable) rc-update del "$n" default 2>/dev/null||true;;
      start)   rc-service "$n" start 2>/dev/null||true;;           stop)    rc-service "$n" stop 2>/dev/null||true;;
      restart) rc-service "$n" restart;;                            status)  rc-service "$n" status;;
      is_active) rc-service "$n" status &>/dev/null;;
    esac
  else
    case "$a" in
      enable)  systemctl enable "$n.service";;                     disable) systemctl disable "$n.service" 2>/dev/null||true;;
      start)   systemctl daemon-reload; systemctl start "$n.service" 2>/dev/null||true;;
      stop)    systemctl stop "$n.service" 2>/dev/null||true;;     restart) systemctl daemon-reload; systemctl restart "$n.service";;
      status)  systemctl status "$n.service" --no-pager;;          is_active) systemctl is-active --quiet "$n.service";;
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
  sysctl net.ipv4.tcp_available_congestion_control &>/dev/null || { warn "系统不支持"; return 1; }
  local cur=$(sysctl -n net.ipv4.tcp_congestion_control)
  printf "📋 可用: %s\n⚡ 当前: %s\n" "$(sysctl -n net.ipv4.tcp_available_congestion_control)" "$cur"
  [[ "$cur" == "bbr" ]] && { info "✅ 已在使用 BBR"; return 0; }
  local c; _ask "切换为 BBR？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "取消"; return; }
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf \
    && sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf \
    || echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
  info "✅ BBR 已启用"
}

# 更新脚本自身
update_self() {
  printf "${C}===== 更新脚本自身 =====${NC}\n"
  local co=$(_co)
  local rver; rver=$(curl $co -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/allinone.sh" 2>/dev/null | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1) || true
  if [[ -n "$rver" && "$rver" == "$SCRIPT_VERSION" ]]; then
    info "✅ 已是最新版本 v$SCRIPT_VERSION"; return 0
  fi
  [[ -n "$rver" ]] && info "🔖 新版本：v${rver}（当前：v${SCRIPT_VERSION}）"
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/allinone.sh"
  local target
  if command -v realpath &>/dev/null; then
    target=$(realpath "${BASH_SOURCE[0]}")
  elif command -v readlink &>/dev/null; then
    target=$(readlink -f "${BASH_SOURCE[0]}")
  else
    target="${BASH_SOURCE[0]}"
  fi
  cp "$target" "${target}.bak" || true
  local tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  echo "从 $url 下载..."
  if curl $(_co) -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
    chmod +x "$tmp"; mv "$tmp" "$target"
    if [[ "${AIO_AUTO:-}" == "1" ]]; then info "✅ 已更新至 $target"; return 0; fi
    info "✅ 已更新至 $target，正在重启..."; exec bash "$target"
  else warn "下载失败"; return 1; fi
}

# 检查脚本更新（异步，结果缓存到临时文件）
_check_script_update() {
  local f=/tmp/.aio_script_update
  local remote
  remote=$(curl $(_co) -fsSL --connect-timeout 5 https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/allinone.sh 2>/dev/null | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1) || true
  [[ -z "$remote" || "$remote" == "$SCRIPT_VERSION" ]] && { : >"$f"; return; }
  echo "$remote" >"$f"
  echo "$remote"
}

# 检查 sing-box 更新（异步，结果缓存到临时文件）
_check_sb_update() {
  local f=/tmp/.aio_sb_update
  local localv; localv=$(_sb_ver 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || true
  [[ -z "$localv" ]] && { : >"$f"; return; }
  local remote
  remote=$(curl $(_co) -fsSL --connect-timeout 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1) || true
  [[ -z "$remote" || "$remote" == "$localv" ]] && { : >"$f"; return; }
  echo "$remote" >"$f"
  echo "$remote"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Vless Reality
# ═══════════════════════════════════════════════════════════════
SBD=/etc/sing-box; SBC="$SBD/config.json"; SBB=sing-box; SBS=sing-box

_sb_ver() {
  command -v "$SBB" &>/dev/null || { echo "未安装"; return; }
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

sb_update_bin() {
  printf "${C}===== 升级 sing-box 内核 =====${NC}\n"
  local arch; case "$(uname -m)" in
    x86_64) arch=amd64;; x86|i686|i386) arch=386;; aarch64|arm64) arch=arm64;;
    armv7l) arch=armv7;; s390x) arch=s390x;; *) die "不支持的架构: $(uname -m)";;
  esac
  local co=$(_co)
  printf "🌐 网络：%s  架构：%s  发行版：%s\n" "$(_net)" "$arch" "$D"
  local ver=$(curl $co -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null|grep '"tag_name"'|head -1|cut -d'"' -f4|sed 's/^v//') || true
  [[ -z "$ver" ]] && die "无法获取最新版本号"
  local cur; cur=$($SBB version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || true
  if [[ -n "$cur" && "$cur" == "$ver" ]]; then
    info "✅ 已是最新版本 v${cur}"; return 0
  fi
  echo "🔖 新版本：v${ver}（当前：v${cur:-?}）"
  local kb=/usr/bin/sing-box; [[ -f "$kb" ]] && cp "$kb" "${kb}.bak" || true
  local td=$(mktemp -d); trap "rm -rf '$td'" RETURN
  if [[ "$D" == "alpine" ]]; then
    curl $co -fL --connect-timeout 30 -o "$td/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.tar.gz" || die "下载失败"
    tar -xzf "$td/sb.tar.gz" -C "$td/"; install -m 755 "$td/sing-box_${ver}_linux_${arch}/sing-box" /usr/bin/sing-box
  else
    curl $co -fL --connect-timeout 30 -o "$td/sb.deb" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.deb" || die "下载失败"
    dpkg -i "$td/sb.deb" || { apt-get install -f -y && dpkg -i "$td/sb.deb"; } || die "安装失败"
  fi
  info "✅ Sing-box: $($SBB version|head -1)"
  local _restarted=() _failed=false
  for s in sing-box sing-box-hy2 sing-box-tuic sing-box-at sing-box-ss sing-box-trajan; do
    if _svc "$s" is_active; then
      _svc "$s" restart; _restarted+=("$s"); info "✅ 已重启 $s"
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
    mv /usr/bin/sing-box.bak /usr/bin/sing-box && info "✅ 已回退内核" || warn "回退失败"
    for s in "${_restarted[@]}"; do _svc "$s" restart; done
    warn "内核更新后服务异常，已自动回退原版本"; return 1
  fi
}

sb_derive_pubkey() {
  local cfg=${1:-$SBC}
  [[ -f "$cfg" ]] || { warn "config.json 不存在"; return 1; }
  _need_py
  local pk=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c['inbounds'][0]['tls']['reality']['private_key'])" "$cfg") || { warn "读取私钥失败"; return 1; }
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
  _ask "用户名称（例如 AK-JP-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  _ask "SNI 域名（默认: s0.awsstatic.com）：" sni; sni=${sni:-s0.awsstatic.com}
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done
  sb_update_bin; hash -r
  command -v "$SBB" &>/dev/null || die "sing-box 安装失败"
  _need openssl
  local uuid=$($SBB generate uuid) keypair=$($SBB generate reality-keypair)
  local priv=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  local pub=$(awk -F': ' '/PublicKey/{print $2}' <<<"$keypair")
  local sid=$(openssl rand -hex 8)
  local n=$(_net)
  local dns s; [[ "$n" == "ipv6" ]] && { dns="2606:4700:4700::1111"; s="prefer_ipv6"; } || { dns="8.8.8.8"; s="prefer_ipv4"; }
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
  [[ "$D" == "alpine" ]] && _sb_openrc
  _svc "$SBS" enable; _svc "$SBS" restart; sleep 2
  if _svc "$SBS" is_active; then info "✅ 安装完成"; sb_show_link; else warn "启动失败"; return 1; fi
}

sb_status()   { printf "${C}===== Reality 状态 =====${NC}\n"; _svc "$SBS" status || warn "服务未运行"; }
sb_start()    { _svc "$SBS" enable; _svc "$SBS" start; info "✅ Sing-box 已开启"; }
sb_stop()     { _svc "$SBS" stop; _svc "$SBS" disable; info "✅ Sing-box 已停止"; }

sb_show_link() {
  printf "${C}===== VLESS Reality 链接 =====${NC}\n"
  [[ -f "$SBC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$SBC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]; r=ib['tls']['reality']
print(ib['users'][0]['name']); print(ib['users'][0]['uuid']); print(ib['tls']['server_name'])
print(r['short_id']); print(ib['listen_port'])
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local name="${L[0]}" uuid="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
  local pk=$(sb_derive_pubkey) || { warn "公钥推导失败"; return 1; }
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "vless://${uuid}@${ip4}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "vless://${uuid}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}-v6"
  echo; [[ -n "$ip4" ]] && _qr "vless://${uuid}@${ip4}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"; [[ -n "$ip6" ]] && _qr "vless://${uuid}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}-v6"
}

sb_uninstall() {
  printf "${C}===== 卸载 Reality =====${NC}\n"
  _svc "$SBS" stop; _svc "$SBS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box || { rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload; }
  rm -rf "$SBD"; rm -f /usr/bin/sing-box /usr/local/bin/sing-box; info "✅ 卸载完成"
}
sb_reinstall() { sb_uninstall; sb_install; }

sb_change_sni() {
  printf "${C}===== 更换 SNI =====${NC}\n"
  [[ -f "$SBC" ]] || { warn "配置文件不存在"; return 1; }; _need_py
  local cs=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['inbounds'][0]['tls']['server_name'])" "$SBC")
  local ns; _ask "新 SNI（当前：${cs}）：" ns; [[ -z "$ns" ]] && { warn "已取消"; return 1; }
  NEW_SNI="$ns" SBC="$SBC" python3 <<'PYEOF'
import json,os
with open(os.environ['SBC']) as f: c=json.load(f)
c['inbounds'][0]['tls']['server_name']=os.environ['NEW_SNI']
c['inbounds'][0]['tls']['reality']['handshake']['server']=os.environ['NEW_SNI']
with open(os.environ['SBC'],'w',encoding='utf-8') as f: json.dump(c,f,indent=2,ensure_ascii=False)
PYEOF
  _svc "$SBS" restart && info "✅ SNI → $ns" || warn "重启失败"
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
HYD=/etc/sing-box-hy2; HYC="$HYD/config.json"; HYB=sing-box; HYS=sing-box-hy2

_hy_ver() { _sb_ver; }

_hy_openrc() {
  cat >/etc/init.d/sing-box-hy2 <<'EOF'
#!/sbin/openrc-run
name="sing-box-hy2"; description="sing-box Hysteria2 service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box-hy2/config.json"
command_background=true; pidfile="/run/sing-box-hy2.pid"
output_log="/var/log/sing-box-hy2.log"; error_log="/var/log/sing-box-hy2.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box-hy2
}

_hy_systemd() {
  cat >/etc/systemd/system/sing-box-hy2.service <<EOF
[Unit]
Description=sing-box Hysteria2 service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c ${HYD}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}


hy_install() {
  printf "${C}===== 安装 Hysteria 2（Sing-box）=====${NC}\n"
  local pw port mu name
  _ask "节点名称（例如 JP-HY-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  while true; do
    printf "${Y}认证密码（留空随机生成）：${NC}"; read -rsp "" pw; echo
    if [[ -z "$pw" ]]; then pw=$(openssl rand -base64 16|tr -d "=+/"|cut -c1-16); info "随机密码: $pw"; break
    elif [[ ${#pw} -ge 6 ]]; then break; else warn "至少6位"; fi
  done
  while true; do
    _ask "监听端口（默认: 2333）：" port; port=${port:-2333}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done
  _ask "伪装网址（默认: https://cn.bing.com/）：" mu; mu=${mu:-https://cn.bing.com/}
  history -c 2>/dev/null||true; export HISTFILE="/dev/null"

  command -v "$HYB" &>/dev/null || { warn "sing-box 未安装，先安装..."; sb_update_bin; }
  command -v "$HYB" &>/dev/null || die "sing-box 安装失败"
  _need openssl

  mkdir -p "$HYD"
  printf "${C}生成自签名证书...${NC}\n"
  local _cn=$(echo "$mu" | sed 's|^https\?://||; s|[:/].*||')
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$HYD/server.key" -out "$HYD/server.crt" -subj "/CN=${_cn}" -days 3650 || die "证书生成失败"

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

  if [[ "$D" == "alpine" ]]; then _hy_openrc; else _hy_systemd; fi
  _svc "$HYS" enable; _svc "$HYS" restart; sleep 2
  if _svc "$HYS" is_active; then info "✅ 安装完成"; hy_show_link; else warn "启动失败"; return 1; fi
}

hy_status()   { printf "${C}===== Hysteria 2 状态 =====${NC}\n"; _svc "$HYS" status || warn "服务未运行"; }
hy_start()    { _svc "$HYS" enable; _svc "$HYS" start; info "✅ Hysteria 2 已开启"; }
hy_stop()     { _svc "$HYS" stop; _svc "$HYS" disable; info "✅ Hysteria 2 已停止"; }

hy_show_link() {
  printf "${C}===== Hysteria 2 链接 =====${NC}\n"
  [[ -f "$HYC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$HYC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local pw="${L[0]}" port="${L[1]}" nm="${L[2]}"
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -z "$nm" ]] && nm="Hysteria2"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "hysteria2://${pw}@${ip4}:${port}?insecure=1#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "hysteria2://${pw}@[${ip6}]:${port}?insecure=1#${en}-v6"
  echo; [[ -n "$ip4" ]] && _qr "hysteria2://${pw}@${ip4}:${port}?insecure=1#${en}"; [[ -n "$ip6" ]] && _qr "hysteria2://${pw}@[${ip6}]:${port}?insecure=1#${en}-v6"
}

hy_uninstall() {
  printf "${C}===== 卸载 Hysteria 2 =====${NC}\n"
  _svc "$HYS" stop; _svc "$HYS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box-hy2 || { rm -f /etc/systemd/system/sing-box-hy2.service; systemctl daemon-reload; }
  rm -rf "$HYD"; info "✅ 卸载完成"
}
hy_reinstall() { hy_uninstall; hy_install; }

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
TUID=/etc/sing-box-tuic; TUIC="$TUID/config.json"; TUIB=sing-box; TUIS=sing-box-tuic

_tuic_ver() { _sb_ver; }

_tuic_openrc() {
  cat >/etc/init.d/sing-box-tuic <<'EOF'
#!/sbin/openrc-run
name="sing-box-tuic"; description="sing-box TUIC service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box-tuic/config.json"
command_background=true; pidfile="/run/sing-box-tuic.pid"
output_log="/var/log/sing-box-tuic.log"; error_log="/var/log/sing-box-tuic.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box-tuic
}

_tuic_systemd() {
  cat >/etc/systemd/system/sing-box-tuic.service <<EOF
[Unit]
Description=sing-box TUIC service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c ${TUID}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}


tuic_install() {
  printf "${C}===== 安装 TUIC（Sing-box）=====${NC}\n"
  local pw port sni name
  _ask "节点名称（例如 JP-TUIC-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  while true; do
    printf "${Y}认证密码（留空随机生成）：${NC}"; read -rsp "" pw; echo
    if [[ -z "$pw" ]]; then pw=$(openssl rand -base64 16|tr -d "=+/"|cut -c1-16); info "随机密码: $pw"; break
    elif [[ ${#pw} -ge 6 ]]; then break; else warn "至少6位"; fi
  done
  while true; do
    _ask "监听端口（默认: 8443）：" port; port=${port:-8443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done
  _ask "TLS 域名（默认: bing.com）：" sni; sni=${sni:-bing.com}
  history -c 2>/dev/null||true; export HISTFILE="/dev/null"

  command -v "$TUIB" &>/dev/null || { warn "sing-box 未安装，先安装..."; sb_update_bin; }
  command -v "$TUIB" &>/dev/null || die "sing-box 安装失败"
  _need openssl

  local uuid=$($TUIB generate uuid)

  mkdir -p "$TUID"
  printf "${C}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$TUID/server.key" -out "$TUID/server.crt" -subj "/CN=${sni}" -days 3650 || die "证书生成失败"

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

  if [[ "$D" == "alpine" ]]; then _tuic_openrc; else _tuic_systemd; fi
  _svc "$TUIS" enable; _svc "$TUIS" restart; sleep 2
  if _svc "$TUIS" is_active; then info "✅ 安装完成"; tuic_show_link; else warn "启动失败"; return 1; fi
}

tuic_status()   { printf "${C}===== TUIC 状态 =====${NC}\n"; _svc "$TUIS" status || warn "服务未运行"; }
tuic_start()    { _svc "$TUIS" enable; _svc "$TUIS" start; info "✅ TUIC 已开启"; }
tuic_stop()     { _svc "$TUIS" stop; _svc "$TUIS" disable; info "✅ TUIC 已停止"; }

tuic_show_link() {
  printf "${C}===== TUIC 链接 =====${NC}\n"
  [[ -f "$TUIC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$TUIC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['uuid']); print(ib['users'][0]['password']); print(ib['tls']['server_name'])
print(ib['listen_port']); print(ib['users'][0].get('name',''))
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local uuid="${L[0]}" pw="${L[1]}" sni="${L[2]}" port="${L[3]}" nm="${L[4]}"
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -z "$nm" ]] && nm="TUIC-${sni}"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "tuic://${uuid}:${pw}@${ip4}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "tuic://${uuid}:${pw}@[${ip6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}-v6"
  echo; [[ -n "$ip4" ]] && _qr "tuic://${uuid}:${pw}@${ip4}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}"; [[ -n "$ip6" ]] && _qr "tuic://${uuid}:${pw}@[${ip6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1#${en}-v6"
}

tuic_uninstall() {
  printf "${C}===== 卸载 TUIC =====${NC}\n"
  _svc "$TUIS" stop; _svc "$TUIS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box-tuic || { rm -f /etc/systemd/system/sing-box-tuic.service; systemctl daemon-reload; }
  rm -rf "$TUID"; info "✅ 卸载完成"
}
tuic_reinstall() { tuic_uninstall; tuic_install; }

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
ATD=/etc/sing-box-at; ATC="$ATD/config.json"; ATB=sing-box; ATS=sing-box-at

_at_ver() { _sb_ver; }

_at_openrc() {
  cat >/etc/init.d/sing-box-at <<'EOF'
#!/sbin/openrc-run
name="sing-box-at"; description="sing-box AnyTLS service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box-at/config.json"
command_background=true; pidfile="/run/sing-box-at.pid"
output_log="/var/log/sing-box-at.log"; error_log="/var/log/sing-box-at.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box-at
}

_at_systemd() {
  cat >/etc/systemd/system/sing-box-at.service <<EOF
[Unit]
Description=sing-box AnyTLS service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c ${ATD}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}


at_install() {
  printf "${C}===== 安装 AnyTLS (Reality) =====${NC}\n"
  local port sni name
  _ask "节点名称（例如 JP-AT-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done
  _ask "SNI 域名（默认: yahoo.com）：" sni; sni=${sni:-yahoo.com}

  command -v "$ATB" &>/dev/null || { warn "sing-box 未安装，先安装..."; sb_update_bin; }
  command -v "$ATB" &>/dev/null || die "sing-box 安装失败"
  _need openssl

  mkdir -p "$ATD"
  local password=$(openssl rand -base64 16)
  local keypair=$($ATB generate reality-keypair)
  local priv=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  local pub=$(awk -F': ' '/PublicKey/{print $2}' <<<"$keypair")
  local sid=$(openssl rand -hex 8)

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

  if [[ "$D" == "alpine" ]]; then _at_openrc; else _at_systemd; fi
  _svc "$ATS" enable; _svc "$ATS" restart; sleep 2
  if _svc "$ATS" is_active; then info "✅ 安装完成"; at_show_link; else warn "启动失败"; return 1; fi
}

at_status()   { printf "${C}===== AnyTLS 状态 =====${NC}\n"; _svc "$ATS" status || warn "服务未运行"; }
at_start()    { _svc "$ATS" enable; _svc "$ATS" start; info "✅ AnyTLS 已开启"; }
at_stop()     { _svc "$ATS" stop; _svc "$ATS" disable; info "✅ AnyTLS 已停止"; }

at_show_link() {
  printf "${C}===== AnyTLS 配置 =====${NC}\n"
  [[ -f "$ATC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$ATC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['users'][0]['password']); print(ib['users'][0].get('name',''))
print(ib['tls']['server_name']); print(ib['tls']['reality']['short_id']); print(ib['listen_port'])
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local pwd="${L[0]}" nm="${L[1]}" sni="${L[2]}" sid="${L[3]}" port="${L[4]}"
  local pk=$(sb_derive_pubkey "$ATC") || { warn "公钥推导失败"; return 1; }
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -z "$nm" ]] && nm="AnyTLS-${sni}"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "anytls://${pwd}@${ip4}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "anytls://${pwd}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}-v6"
  echo; [[ -n "$ip4" ]] && _qr "anytls://${pwd}@${ip4}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}"; [[ -n "$ip6" ]] && _qr "anytls://${pwd}@[${ip6}]:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pk}&sid=${sid}#${en}-v6"

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

at_uninstall() {
  printf "${C}===== 卸载 AnyTLS =====${NC}\n"
  _svc "$ATS" stop; _svc "$ATS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box-at || { rm -f /etc/systemd/system/sing-box-at.service; systemctl daemon-reload; }
  rm -rf "$ATD"; info "✅ 卸载完成"
}
at_reinstall() { at_uninstall; at_install; }

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
SSD=/etc/sing-box-ss; SSC="$SSD/config.json"; SSB=sing-box; SSS=sing-box-ss

_ss_ver() { _sb_ver; }

_ss_openrc() {
  cat >/etc/init.d/sing-box-ss <<'EOF'
#!/sbin/openrc-run
name="sing-box-ss"; description="sing-box Shadowsocks service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box-ss/config.json"
command_background=true; pidfile="/run/sing-box-ss.pid"
output_log="/var/log/sing-box-ss.log"; error_log="/var/log/sing-box-ss.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box-ss
}

_ss_systemd() {
  cat >/etc/systemd/system/sing-box-ss.service <<EOF
[Unit]
Description=sing-box Shadowsocks service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c ${SSD}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}


ss_install() {
  printf "${C}===== 安装 Shadowsocks（Sing-box）=====${NC}\n"
  local port name
  _ask "节点名称（例如 JP-SS-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  while true; do
    _ask "监听端口（默认: 8388）：" port; port=${port:-8388}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done

  command -v "$SSB" &>/dev/null || { warn "sing-box 未安装，先安装..."; sb_update_bin; }
  command -v "$SSB" &>/dev/null || die "sing-box 安装失败"

  mkdir -p "$SSD"
  local password=$($SSB generate rand --base64 16)

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

  if [[ "$D" == "alpine" ]]; then _ss_openrc; else _ss_systemd; fi
  _svc "$SSS" enable; _svc "$SSS" restart; sleep 2
  if _svc "$SSS" is_active; then info "✅ 安装完成"; ss_show_link; else warn "启动失败"; return 1; fi
}

ss_status()   { printf "${C}===== Shadowsocks 状态 =====${NC}\n"; _svc "$SSS" status || warn "服务未运行"; }
ss_start()    { _svc "$SSS" enable; _svc "$SSS" start; info "✅ Shadowsocks 已开启"; }
ss_stop()     { _svc "$SSS" stop; _svc "$SSS" disable; info "✅ Shadowsocks 已停止"; }

ss_show_link() {
  printf "${C}===== Shadowsocks 链接 =====${NC}\n"
  [[ -f "$SSC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$SSC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
print(ib['password']); print(ib['listen_port']); print(ib['method'])
u=ib.get('users',[{}]); print(u[0].get('name',''))
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local pwd="${L[0]}" port="${L[1]}" method="${L[2]}" nm="${L[3]}"
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -z "$nm" ]] && nm="Shadowsocks"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  local ss_enc=$(printf "%s:%s" "$method" "$pwd" | openssl base64 -A)
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "ss://${ss_enc}@${ip4}:${port}#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "ss://${ss_enc}@[${ip6}]:${port}#${en}-v6"
  echo; [[ -n "$ip4" ]] && _qr "ss://${ss_enc}@${ip4}:${port}#${en}"; [[ -n "$ip6" ]] && _qr "ss://${ss_enc}@[${ip6}]:${port}#${en}-v6"
}

ss_uninstall() {
  printf "${C}===== 卸载 Shadowsocks =====${NC}\n"
  _svc "$SSS" stop; _svc "$SSS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box-ss || { rm -f /etc/systemd/system/sing-box-ss.service; systemctl daemon-reload; }
  rm -rf "$SSD"; info "✅ 卸载完成"
}
ss_reinstall() { ss_uninstall; ss_install; }

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
TRD=/etc/sing-box-trajan; TRC="$TRD/config.json"; TRB=sing-box; TRS=sing-box-trajan

_tr_ver() { _sb_ver; }

_tr_openrc() {
  cat >/etc/init.d/sing-box-trajan <<'EOF'
#!/sbin/openrc-run
name="sing-box-trajan"; description="sing-box Trojan service"
command="/usr/bin/sing-box"; command_args="run -c /etc/sing-box-trajan/config.json"
command_background=true; pidfile="/run/sing-box-trajan.pid"
output_log="/var/log/sing-box-trajan.log"; error_log="/var/log/sing-box-trajan.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box-trajan
}
_tr_systemd() {
  cat >/etc/systemd/system/sing-box-trajan.service <<EOF
[Unit]
Description=sing-box Trojan service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c ${TRD}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
}


tr_install() {
  printf "${C}===== 安装 Trojan（Sing-box）=====${NC}\n"
  local pw port sni name
  _ask "节点名称（例如 JP-TR-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  while true; do
    printf "${Y}认证密码（留空随机生成）：${NC}"; read -rsp "" pw; echo
    if [[ -z "$pw" ]]; then pw=$(openssl rand -base64 16|tr -d "=+/"|cut -c1-16); info "随机密码: $pw"; break
    elif [[ ${#pw} -ge 6 ]]; then break; else warn "至少6位"; fi
  done
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { warn "端口无效"; continue; }
    _port_in_use "$port" && { warn "端口 $port 已被占用，请换一个"; continue; }
    break
  done
  _ask "TLS 域名：" sni; [[ -z "$sni" ]] && die "域名不能为空"
  history -c 2>/dev/null||true; export HISTFILE="/dev/null"

  command -v "$TRB" &>/dev/null || { warn "sing-box 未安装，先安装..."; sb_update_bin; }
  command -v "$TRB" &>/dev/null || die "sing-box 安装失败"
  _need openssl

  mkdir -p "$TRD"
  local cert_type
  printf "${C}证书类型：${NC}\n"
  printf "  ${Y}1)${NC} 自签名证书（快速，无需额外配置，客户端需跳过验证）\n"
  printf "  ${Y}2)${NC} Let's Encrypt（需：域名解析到本机 + 80 端口开放 + 非 NAT/内网）\n"
  while true; do
    printf "${BD}选择 [1-2]: ${NC}"; read -r cert_type; echo
    [[ "$cert_type" == "1" || "$cert_type" == "2" ]] && break || warn "无效选项"
  done

  local use_le=0
  if [[ "$cert_type" == "2" ]]; then
    local port_le; for port_le in 80 8080; do if ! _port_in_use $port_le; then break; fi; port_le=""; done
    if [[ -z "$port_le" ]]; then
      warn "80 和 8080 端口均被占用，Let's Encrypt 申请需要 80 端口"
      local c; _ask "回退使用自签名证书？(y/n): " c
      [[ "$c" =~ ^[Yy]$ ]] || { info "已取消安装"; return 1; }
    else
      use_le=1
      printf "${C}sing-box 将自动申请 Let's Encrypt 证书（使用端口 ${port_le:-80}）${NC}\n"
    fi
  fi

  if [[ "$use_le" == "1" ]]; then
    echo "1" >"$TRD/.use_le"
    tr_write_config "$sni" "$port" "$name" "$pw" "le"
    if [[ "$D" == "alpine" ]]; then _tr_openrc; else _tr_systemd; fi
    _svc "$TRS" enable; _svc "$TRS" restart; sleep 2
    local acme_ok=0
    for i in $(seq 1 30); do
      sleep 2
      if _svc "$TRS" is_active 2>/dev/null; then acme_ok=1; break; fi
    done
    if [[ "$acme_ok" == "1" ]]; then
      printf "${G}✅ Let's Encrypt 证书申请成功${NC}\n"
      echo "1" >"$TRD/.use_le"
      info "✅ 安装完成"; tr_show_link; return 0
    fi
    warn "ACME 申请失败（频率限制/域名未解析/端口不可达），回退自签名..."
    use_le=0
  fi

  printf "${C}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$TRD/server.key" -out "$TRD/server.crt" -subj "/CN=${sni}" -days 3650 || die "证书生成失败"
  echo "0" >"$TRD/.use_le"
  tr_write_config "$sni" "$port" "$name" "$pw" "self"

  if [[ "$D" == "alpine" ]]; then _tr_openrc; else _tr_systemd; fi
  _svc "$TRS" enable; _svc "$TRS" restart; sleep 2
  if _svc "$TRS" is_active; then info "✅ 安装完成"; tr_show_link; else warn "启动失败"; return 1; fi
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
}

tr_status()   { printf "${C}===== Trojan 状态 =====${NC}\n"; _svc "$TRS" status || warn "服务未运行"; }
tr_start()    { _svc "$TRS" enable; _svc "$TRS" start; info "✅ Trojan 已开启"; }
tr_stop()     { _svc "$TRS" stop; _svc "$TRS" disable; info "✅ Trojan 已停止"; }

tr_show_link() {
  printf "${C}===== Trojan 链接 =====${NC}\n"
  [[ -f "$TRC" ]] || { warn "配置文件不存在"; return 1; }
  _need_py
  local f=$(python3 - "$TRC" <<'PYEOF'
import json,sys; c=json.load(open(sys.argv[1])); ib=c['inbounds'][0]
u=ib['users'][0]; print(u['password']); print(u.get('name',''))
print(ib['tls']['server_name']); print(ib['listen_port'])
PYEOF
  ) || { warn "读取失败"; return 1; }
  mapfile -t L <<<"$f"
  local pw="${L[0]}" nm="${L[1]}" sni="${L[2]}" port="${L[3]}"
  local ip4 ip6; read -r ip4 ip6 <<< "$(_get_ips)"
  [[ -z "$ip4" && -z "$ip6" ]] && { warn "无法获取 IP"; return 1; }
  [[ -z "$nm" ]] && nm="Trojan-${sni}"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  local use_le; use_le=$(<"$TRD/.use_le" 2>/dev/null||echo "0")
  local insecure; [[ "$use_le" != "1" ]] && insecure="allowInsecure=1&"
  local cert_info; [[ "$use_le" == "1" ]] && cert_info="${G}[Let's Encrypt]${NC}" || cert_info="${Y}[自签名]${NC}"
  printf "%s %s\n" "$cert_info" "链接："
  [[ -n "$ip4" ]] && printf "${G}IPv4: %s${NC}\n" "trojan://${pw}@${ip4}:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}"
  [[ -n "$ip6" ]] && printf "${G}IPv6: %s${NC}\n" "trojan://${pw}@[${ip6}]:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}-v6"
  echo; [[ -n "$ip4" ]] && _qr "trojan://${pw}@${ip4}:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}"; [[ -n "$ip6" ]] && _qr "trojan://${pw}@[${ip6}]:${port}?${insecure}fp=firefox&security=tls&sni=${sni}&type=tcp&multiplex=true#${en}-v6"
}

tr_uninstall() {
  printf "${C}===== 卸载 Trojan =====${NC}\n"
  _svc "$TRS" stop; _svc "$TRS" disable
  [[ "$D" == "alpine" ]] && rm -f /etc/init.d/sing-box-trajan || { rm -f /etc/systemd/system/sing-box-trajan.service; systemctl daemon-reload; }
  rm -rf "$TRD"; info "✅ 卸载完成"
}
tr_reinstall() { tr_uninstall; tr_install; }

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
  "hy|Hysteria2|_hy_ver"
  "tuic|TUIC|_tuic_ver"
  "at|AnyTLS|_at_ver"
  "ss|Shadowsocks|_ss_ver"
  "tr|Trojan|_tr_ver"
)

# ═══════════════════════════════════════════════════════════════
#  服务子菜单（通用）
# ═══════════════════════════════════════════════════════════════
_svc_menu() {
  local id=$1 title=$2 verfn=$3
  while true; do
    printf "\n${C}===== %s (%s) =====${NC}\n" "$title" "$($verfn)"
    local i=1; local -a callbacks=()
    while IFS='|' read -r lb cb; do
      [[ -z "$lb" ]] && continue
      printf "  ${Y}%2d)${NC} %s\n" "$i" "$lb"
      callbacks+=("$cb"); ((i++))
    done < <("_${id}_menu")
    printf "  ${Y} 0)${NC} 返回上级\n"
    printf "${BD}选择 [0-$((i-1))]: ${NC}"
    read -r ch; echo
    [[ "$ch" == "0" ]] && return
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -ge 1 && "$ch" -le ${#callbacks[@]} ]]; then
      ${callbacks[$((ch-1))]}
    else warn "无效选项"; fi
  done
}

# ═══════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════
_sb_installed()  { [[ -f "$SBC" ]] && echo "已安装" || echo "未安装"; }
_hy_installed()  { [[ -f "$HYC" ]] && echo "已安装" || echo "未安装"; }
_tuic_installed(){ [[ -f "$TUIC" ]] && echo "已安装" || echo "未安装"; }
_at_installed()  { [[ -f "$ATC" ]] && echo "已安装" || echo "未安装"; }
_ss_installed()  { [[ -f "$SSC" ]] && echo "已安装" || echo "未安装"; }
_tr_installed()  { [[ -f "$TRC" ]] && echo "已安装" || echo "未安装"; }

uninstall_all() {
  printf "${C}===== 卸载脚本及所有相关文件 =====${NC}\n"
  local c; _ask "确认卸载所有协议、二进制和脚本？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "取消"; return; }

  sb_uninstall 2>/dev/null||true
  hy_uninstall 2>/dev/null||true
  tuic_uninstall 2>/dev/null||true
  at_uninstall 2>/dev/null||true
  ss_uninstall 2>/dev/null||true
  tr_uninstall 2>/dev/null||true

  rm -f /usr/bin/sing-box /usr/local/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box-tuic.service
  rm -f /etc/systemd/system/sing-box-hy2.service /etc/systemd/system/sing-box-at.service /etc/systemd/system/sing-box-ss.service /etc/systemd/system/sing-box-trajan.service
  rm -f /etc/init.d/sing-box /etc/init.d/sing-box-tuic /etc/init.d/sing-box-hy2 /etc/init.d/sing-box-at /etc/init.d/sing-box-ss /etc/init.d/sing-box-trajan
  systemctl disable --now aio-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/aio-update.service /etc/systemd/system/aio-update.timer
  hash -r 2>/dev/null||true

  rm -f /usr/local/bin/aio
  local sp="${BASH_SOURCE[0]}"
  info "✅ 卸载完成，脚本即将自毁。"
  rm -f "$sp"
  exit 0
}

# ═══════════════════════════════════════════════════════════════
#  DEV 功能
# ═══════════════════════════════════════════════════════════════
dev_auto_update() {
  printf "${C}===== DEV 自动更新 =====${NC}\n"
  local _err=0

  echo; info "📦 更新内核..."
  if ( sb_update_bin ); then
    info "✅ 内核更新完成"
  else
    warn "内核更新失败"
    if [[ -f /usr/bin/sing-box.bak ]]; then
      mv /usr/bin/sing-box.bak /usr/bin/sing-box && info "✅ 已从备份回退内核" || { warn "回退失败，请手动 mv /usr/bin/sing-box.bak /usr/bin/sing-box"; _err=1; }
    else
      warn "无备份可回退"; _err=1
    fi
  fi

  # 安装/刷新 systemd 定时器（必须在脚本更新之前，因为 update_self 会 exec）
  echo; info "⏰ 刷新自动更新定时器..."
  _write_timer_units
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now aio-update.timer 2>/dev/null || true
  info "✅ 定时器已就绪（每天自动更新）"

  echo; info "📜 更新脚本..."
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

_dev_menu() {
  while true; do
    echo; printf "${BD}${B}DEV 功能：${NC}"
    if systemctl is-active --quiet aio-update.timer 2>/dev/null; then
      printf " ${G}[自动更新已开启]${NC}"
    fi
    printf "\n"
    printf "  ${Y}1)${NC} 自动更新脚本和内核\n"
    printf "  ${Y}0)${NC} 返回主菜单\n"
    printf "${BD}选择 [0-1]: ${NC}"; read -r ch; echo
    case "$ch" in 1) dev_auto_update; return ;; 0) return ;; *) warn "无效选项" ;; esac
  done
}

main() {
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
local _resolved; _resolved=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
if [[ ! -L /usr/local/bin/aio ]]; then
  ln -sf "$_resolved" /usr/local/bin/aio && info "✅ 已注册 aio 命令，下次直接输入 aio 启动"
elif [[ "$(readlink /usr/local/bin/aio)" != "$_resolved" ]]; then
  ln -sf "$_resolved" /usr/local/bin/aio
fi

_net >/dev/null || true

clear
printf "%b\n" "$BANNER"

local _kv; _kv=$(_sb_ver); _kv=${_kv#sing-box version }; _kv=${_kv:-未安装}
printf "${B}内核 sing-box %s | 系统 %s | 网络 %s${NC}\n" "$_kv" "${D:-unknown}" "${_NC:-unknown}"

# 异步检查更新（后台任务写结果到缓存文件）
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
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "$title"; ((idx++))
  done
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "设置BBR"; local bb=$idx; ((idx++))
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "更新内核"; local uk=$idx; ((idx++))
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "更新脚本"; local us=$idx; ((idx++))
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "卸载脚本"; local ua=$idx; ((idx++))
  printf "  ${Y}%2d)${NC} %s" "$idx" "DEV功能"; local dev=$idx; ((idx++))
  systemctl is-active --quiet aio-update.timer 2>/dev/null && printf " ${G}[自动]${NC}"
  printf "\n"
  printf "  ${Y} 0)${NC} 退出\n"
  printf "${BD}选择 [0-$((idx-1))]: ${NC}"
  read -r ch; echo

  if [[ "$ch" == "0" ]]; then info "退出。"; exit 0; fi

  local sel=$ch found=false
  local mi=1
  for mod in "${MODULES[@]}"; do
    if [[ "$sel" == "$mi" ]]; then
      IFS='|' read -r id title verfn <<<"$mod"
      _svc_menu "$id" "$title" "$verfn"; found=true; break
    fi; ((mi++))
  done
  $found && continue

  if [[ "$sel" == "$bb" ]]; then set_bbr
  elif [[ "$sel" == "$uk" ]]; then sb_update_bin
  elif [[ "$sel" == "$us" ]]; then update_self
  elif [[ "$sel" == "$ua" ]]; then uninstall_all
  elif [[ "$sel" == "$dev" ]]; then _dev_menu
  else warn "无效选项"; fi
done
}

main "$@"
