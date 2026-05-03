#!/usr/bin/env bash
# allinone.sh — 多协议代理统一管理脚本
SCRIPT_VERSION="4.0.0"
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
    All in One Proxy Manager v4.0.0${NC}"

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

_get_ip() {
  local n=$(_net) ip=""
  case "$n" in
  ipv6)       ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null || curl -6 -s --connect-timeout 5 https://ifconfig.co 2>/dev/null || ip -6 addr show scope global|awk '/inet6/{print $2}'|cut -d/ -f1|head -1) ;;
  dual|ipv4)  ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || ip -4 addr show scope global|awk '/inet/{print $2}'|cut -d/ -f1|head -1) ;;
  *)          ip=$(ip addr show scope global|grep -oE '(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f:]+)/[0-9]+'|head -1|cut -d/ -f1) ;;
  esac
  echo "$ip"
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
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/allinone.sh"
  local script_path="${BASH_SOURCE[0]}"
  local dir=$(dirname "$script_path")
  local target="$dir/allinone.sh"
  local tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  echo "从 $url 下载..."
  if curl $(_co) -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
    chmod +x "$tmp"; mv "$tmp" "$target"
    info "✅ 已更新至 $target，正在重启..."; exec bash "$target"
  else warn "下载失败"; fi
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Sing-box
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
  printf "${C}===== 升级 Sing-box =====${NC}\n"
  local arch; case "$(uname -m)" in
    x86_64) arch=amd64;; x86|i686|i386) arch=386;; aarch64|arm64) arch=arm64;;
    armv7l) arch=armv7;; s390x) arch=s390x;; *) die "不支持的架构: $(uname -m)";;
  esac
  local co=$(_co)
  printf "🌐 网络：%s  架构：%s  发行版：%s\n" "$(_net)" "$arch" "$D"
  local ver=$(curl $co -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null|grep '"tag_name"'|head -1|cut -d'"' -f4|sed 's/^v//') || true
  [[ -z "$ver" ]] && die "无法获取最新版本号"
  echo "🔖 最新版本：v${ver}"
  local td=$(mktemp -d); trap "rm -rf '$td'" RETURN
  if [[ "$D" == "alpine" ]]; then
    curl $co -fL --connect-timeout 30 -o "$td/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.tar.gz" || die "下载失败"
    tar -xzf "$td/sb.tar.gz" -C "$td/"; install -m 755 "$td/sing-box_${ver}_linux_${arch}/sing-box" /usr/bin/sing-box
  else
    curl $co -fL --connect-timeout 30 -o "$td/sb.deb" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.deb" || die "下载失败"
    dpkg -i "$td/sb.deb" || { apt-get install -f -y && dpkg -i "$td/sb.deb"; } || die "安装失败"
  fi
  info "✅ Sing-box: $($SBB version|head -1)"
  _svc "$SBS" is_active && { _svc "$SBS" restart; info "✅ 已重启"; } || true
}

sb_derive_pubkey() {
  [[ -f "$SBC" ]] || { warn "config.json 不存在"; return 1; }
  _need_py
  local pk=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c['inbounds'][0]['tls']['reality']['private_key'])" "$SBC") || { warn "读取私钥失败"; return 1; }
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
  printf "${C}===== 安装 Sing-box =====${NC}\n"
  local name sni port
  _ask "用户名称（例如 AK-JP-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  _ask "SNI 域名（默认: s0.awsstatic.com）：" sni; sni=${sni:-s0.awsstatic.com}
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] && break
    warn "端口无效"
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

sb_status()   { printf "${C}===== Sing-box 状态 =====${NC}\n"; _svc "$SBS" status || warn "服务未运行"; }
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
  local ip=$(_get_ip); [[ "$ip" == *:* ]] && ip="[$ip]"
  local link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pk}&sid=${sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  printf "${G}%s${NC}\n\n" "$link"; _qr "$link"
}

sb_uninstall() {
  printf "${C}===== 卸载 Sing-box =====${NC}\n"
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
  echo "升级二进制|sb_update_bin"
  echo "更换 SNI|sb_change_sni"
}

# ═══════════════════════════════════════════════════════════════
#  协议模块：Hysteria 2
# ═══════════════════════════════════════════════════════════════
HYD=/etc/hysteria; HYC="$HYD/config.yaml"; HYB=hysteria; HYS=hysteria-server

_hy_ver() {
  command -v "$HYB" &>/dev/null || { echo "未安装"; return; }
  local v=$("$HYB" version 2>&1 | sed -n 's/^Version:\s*//p' | head -1) || true
  echo "${v:-已安装}"
}

hy_update_bin() {
  printf "${C}===== 升级 Hysteria 2 =====${NC}\n"
  [[ "$D" == "alpine" ]] && { warn "Alpine 暂不支持"; return 1; }
  printf "🌐 网络：%s  发行版：%s\n" "$(_net)" "$D"
  bash <(curl $(_co) -fsSL https://get.hy2.sh/) || die "安装失败"
  info "✅ Hysteria 2: $(_hy_ver)"
}

hy_install() {
  printf "${C}===== 安装 Hysteria 2 =====${NC}\n"
  local pw port mu
  while true; do
    printf "${Y}认证密码（留空随机生成）：${NC}"; read -rsp "" pw; echo
    if [[ -z "$pw" ]]; then pw=$(openssl rand -base64 16|tr -d "=+/"|cut -c1-16); info "随机密码: $pw"; break
    elif [[ ${#pw} -ge 6 ]]; then break; else warn "至少6位"; fi
  done
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] && break; warn "端口无效"
  done
  _ask "伪装网址（默认: https://cn.bing.com/）：" mu; mu=${mu:-https://cn.bing.com/}
  history -c 2>/dev/null||true; export HISTFILE="/dev/null"

  _need openssl
  command -v "$HYB" &>/dev/null || hy_update_bin || die "安装失败"
  command -v "$HYB" &>/dev/null || die "未找到二进制"

  mkdir -p "$HYD"
  printf "${C}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$HYD/server.key" -out "$HYD/server.crt" -subj "/CN=bing.com" -days 3650 || die "证书生成失败"

  cat >"$HYC" <<EOF
listen: :${port}

tls:
  cert: ${HYD}/server.crt
  key: ${HYD}/server.key

auth:
  type: password
  password: ${pw}

resolver:
  type: udp
  tcp:
    addr: 8.8.8.8:53
    timeout: 4s
  udp:
    addr: 8.8.4.4:53
    timeout: 4s
  tls:
    addr: 1.1.1.1:853
    timeout: 10s
    sni: cloudflare-dns.com
    insecure: false
  https:
    addr: 1.1.1.1:443
    timeout: 10s
    sni: cloudflare-dns.com
    insecure: false

masquerade:
  type: proxy
  proxy:
    url: ${mu}
    rewriteHost: true
EOF

  if ! chown hysteria:hysteria "$HYD/server.key" "$HYD/server.crt" 2>/dev/null; then
    warn "证书权限异常，切换 root 运行"
    sed -i '/User=/d' /etc/systemd/system/hysteria-server.service 2>/dev/null||true
    sed -i '/User=/d' /etc/systemd/system/hysteria-server@.service 2>/dev/null||true
  fi

  if command -v ufw &>/dev/null; then
    ufw status|head -1|grep -q inactive || { ufw allow http>/dev/null 2>&1; ufw allow https>/dev/null 2>&1; ufw allow "$port">/dev/null 2>&1; }
  fi
  if command -v iptables &>/dev/null; then
    iptables -L INPUT -n|grep -q "dpt:$port" || { iptables -I INPUT -p tcp --dport "$port" -j ACCEPT; iptables -I INPUT -p udp --dport "$port" -j ACCEPT; }
  fi

  sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1||true
  sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1||true
  grep -q "net.core.rmem_max=16777216" /etc/sysctl.conf 2>/dev/null || cat >>/etc/sysctl.conf <<'HEREDOC'

# Hysteria 2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
HEREDOC

  _svc "$HYS" enable; _svc "$HYS" restart; sleep 2
  if _svc "$HYS" is_active; then info "✅ 安装完成"; hy_show_link; else warn "启动失败"; return 1; fi
}

hy_status()     { printf "${C}===== Hysteria 2 状态 =====${NC}\n"; _svc "$HYS" status || warn "服务未运行"; }
hy_start()      { _svc "$HYS" enable; _svc "$HYS" start; info "✅ Hysteria 2 已开启"; }
hy_stop()       { _svc "$HYS" stop; _svc "$HYS" disable; info "✅ Hysteria 2 已停止"; }

hy_show_link() {
  printf "${C}===== Hysteria 2 链接 =====${NC}\n"
  [[ -f "$HYC" ]] || { warn "配置文件不存在"; return 1; }
  local pw=$(grep -oP 'password:\s*\K.*' "$HYC"|tr -d ' ')
  local pt=$(grep -oP 'listen:\s*:\K[0-9]+' "$HYC")
  [[ -n "$pw" && -n "$pt" ]] || { warn "解析失败"; return 1; }
  local ip=$(_get_ip); [[ -z "$ip" ]] && { warn "无法获取 IP"; return 1; }
  [[ "$ip" == *:* ]] && ip="[$ip]"
  local nm="Hysteria2-${ip}"
  local en=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$nm'))" 2>/dev/null||echo "$nm")
  local link="hysteria2://${pw}@${ip}:${pt}?insecure=1#${en}"
  printf "${G}%s${NC}\n\n" "$link"; _qr "$link"
}

hy_uninstall() {
  printf "${C}===== 卸载 Hysteria 2 =====${NC}\n"
  _svc "$HYS" stop; _svc "$HYS" disable
  rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -rf "$HYD"; rm -f /usr/local/bin/hysteria /usr/bin/hysteria
  userdel hysteria 2>/dev/null||true; info "✅ 卸载完成"
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
  echo "升级二进制|hy_update_bin"
}

# ═══════════════════════════════════════════════════════════════
#  模块注册（新增协议只需加一行 + 实现同模板的模块）
# ═══════════════════════════════════════════════════════════════
# 格式: "id|标题|版本函数"
MODULES=(
  "sb|Sing-box|_sb_ver"
  "hy|Hysteria 2|_hy_ver"
)

# ═══════════════════════════════════════════════════════════════
#  服务子菜单（通用）
# ═══════════════════════════════════════════════════════════════
_svc_menu() {
  local id=$1 title=$2 verfn=$3
  while true; do
    printf "\n${C}===== %s (%s) =====${NC}\n" "$title" "$($verfn)"
    local i=1; local -a labels=() callbacks=()
    while IFS='|' read -r lb cb; do
      [[ -z "$lb" ]] && continue
      printf "  ${Y}%2d)${NC} %s\n" "$i" "$lb"
      labels+=("$lb"); callbacks+=("$cb"); ((i++))
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
main() {
_net >/dev/null || true

clear
printf "%b\n" "$BANNER"

printf "${B}脚本版本：${SCRIPT_VERSION}  |  发行版：${D}  |  网络：${_NC}${NC}\n"
for mod in "${MODULES[@]}"; do
  IFS='|' read -r id title _ <<<"$mod"
  printf "${B}%s：%s${NC}\n" "$title" "$(_${id}_ver)"
done

while true; do
  printf "\n${BD}${B}请选择服务：${NC}\n"
  local idx=1
  for mod in "${MODULES[@]}"; do
    IFS='|' read -r _ title _ <<<"$mod"
    printf "  ${Y}%2d)${NC} %s\n" "$idx" "$title"; ((idx++))
  done
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "设置 BBR"; local bb=$idx; ((idx++))
  printf "  ${Y}%2d)${NC} %s\n" "$idx" "更新脚本自身"; local us=$idx; ((idx++))
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
  elif [[ "$sel" == "$us" ]]; then update_self
  else warn "无效选项"; fi
done
}

main "$@"
