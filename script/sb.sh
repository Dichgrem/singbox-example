#!/usr/bin/env bash
# sb.sh — Sing-box + Hysteria 2 统一管理脚本
SCRIPT_VERSION="3.0.0"

set -uo pipefail

# ─── 颜色 ─────────────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# ─── 工具函数 ─────────────────────────────────────────────────
die()   { printf "${RED}错误：%s${NC}\n" "$*" >&2; exit 1; }
info()  { printf "${GREEN}%s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
_ask()  { read -rp "$(printf "${BOLD}%s${NC}" "$*")"; }

# ─── 权限检查 ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "请以 root 用户或使用 sudo 运行此脚本"

# ─── 发行版检测 ───────────────────────────────────────────────
if [[ -f /etc/alpine-release ]]; then DISTRO=alpine
elif command -v apt-get &>/dev/null; then DISTRO=debian
else DISTRO=unknown; fi

# ─── 包管理器封装 ──────────────────────────────────────────────
_pkg_install() { if [[ "$DISTRO" == "alpine" ]]; then apk add --no-cache "$@"; else apt-get install -y "$@"; fi; }
_pkg_update()  { if [[ "$DISTRO" == "alpine" ]]; then apk update; else apt-get update; fi; }

# ─── 依赖检查 ─────────────────────────────────────────────────
_require() {
  local cmd=$1 pkg=${2:-$1}
  command -v "$cmd" &>/dev/null && return 0
  warn "未安装 $cmd，正在安装..."
  _pkg_update && _pkg_install "$pkg" || die "$pkg 安装失败"
}
_require curl
_require_python3() { _require python3 python3; }

# ─── 网络类型检测（带缓存）────────────────────────────────────
_NET_CACHE=""
_get_net() {
  [[ -n "$_NET_CACHE" ]] && { echo "$_NET_CACHE"; return; }
  local has4=false has6=false
  curl -4 -s --connect-timeout 3 https://api.ipify.org &>/dev/null && has4=true || true
  curl -6 -s --connect-timeout 3 https://api64.ipify.org &>/dev/null && has6=true || true
  if $has4 && $has6; then _NET_CACHE=dual
  elif $has6; then _NET_CACHE=ipv6
  elif $has4; then _NET_CACHE=ipv4
  else _NET_CACHE=none; fi
  echo "$_NET_CACHE"
}
_curl_opt() { [[ "$(_get_net)" == "ipv6" ]] && echo "-6" || echo ""; }

_get_ip() {
  local net=$(_get_net) ip=""
  case "$net" in
  ipv6) ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null ||
             curl -6 -s --connect-timeout 5 https://ifconfig.co 2>/dev/null ||
             ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1) ;;
  dual|ipv4) ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
                  curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null ||
                  ip -4 addr show scope global | awk '/inet/{print $2}' | cut -d/ -f1 | head -1) ;;
  *) ip=$(ip addr show scope global | grep -oE '(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f:]+)/[0-9]+' | head -1 | cut -d/ -f1) ;;
  esac
  echo "$ip"
}

# ─── 服务管理封装 ──────────────────────────────────────────────
_svc() {
  local name=$1 action=$2
  if [[ "$DISTRO" == "alpine" ]]; then
    case "$action" in
      enable)  rc-update add "$name" default 2>/dev/null || true ;;
      disable) rc-update del "$name" default 2>/dev/null || true ;;
      start)   rc-service "$name" start 2>/dev/null || true ;;
      stop)    rc-service "$name" stop 2>/dev/null || true ;;
      restart) rc-service "$name" restart ;;
      status)  rc-service "$name" status ;;
      is_active) rc-service "$name" status &>/dev/null ;;
    esac
  else
    case "$action" in
      enable)  systemctl enable "$name.service" ;;
      disable) systemctl disable "$name.service" 2>/dev/null || true ;;
      start)   systemctl daemon-reload; systemctl start "$name.service" 2>/dev/null || true ;;
      stop)    systemctl stop "$name.service" 2>/dev/null || true ;;
      restart) systemctl daemon-reload; systemctl restart "$name.service" ;;
      status)  systemctl status "$name.service" --no-pager ;;
      is_active) systemctl is-active --quiet "$name.service" ;;
    esac
  fi
}

# ─── QR 码渲染（共享） ─────────────────────────────────────────
_qr_show() {
  printf "${CYAN}===== 二维码 =====${NC}\n"
  LINK="$1" python3 <<'PYEOF'
import os, sys
data = os.environ['LINK']
def render(m):
    if len(m) % 2: m.append([False]*len(m[0]))
    for i in range(0, len(m), 2):
        line=''
        for j in range(len(m[0])):
            t,b=m[i][j],m[i+1][j]
            if t and b: line+='\u2588'
            elif t: line+='\u2580'
            elif b: line+='\u2584'
            else: line+=' '
        print(line)
try:
    import qrcode
    qr=qrcode.QRCode(border=1); qr.add_data(data); qr.make(fit=True)
    render(qr.get_matrix()); sys.exit(0)
except ImportError: pass
try:
    import segno
    segno.make(data, error='m').terminal(compact=True); sys.exit(0)
except ImportError: pass
d="alpine" if os.path.exists('/etc/alpine-release') else "debian"
print(f"（二维码库未安装，请执行: {'apk add py3-qrcode' if d=='alpine' else 'apt install python3-qrcode'}）", file=sys.stderr)
PYEOF
}

# ═══════════════════════════════════════════════════════════════
#  Sing-box 模块
# ═══════════════════════════════════════════════════════════════
SB_DIR=/etc/sing-box
SB_CONF="$SB_DIR/config.json"
SB_BIN=sing-box
SB_SVC=sing-box

_sb_ver() {
  command -v "$SB_BIN" &>/dev/null || { echo "未安装"; return; }
  $SB_BIN version 2>/dev/null | head -1
}

sb_install_openrc() {
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
  printf "${CYAN}===== 升级/安装 Sing-box 二进制 =====${NC}\n"
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; x86|i686|i386) arch=386 ;;
    aarch64|arm64) arch=arm64 ;; armv7l) arch=armv7 ;; s390x) arch=s390x ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
  local copts=$(_curl_opt)
  echo "🌐 网络：$(_get_net)  架构：$arch  发行版：$DISTRO"

  local ver
  ver=$(curl $copts -fsSL --connect-timeout 15 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
    grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//') || true
  [[ -z "$ver" ]] && die "无法获取最新版本号"
  echo "🔖 最新版本：v${ver}"

  local tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" RETURN
  if [[ "$DISTRO" == "alpine" ]]; then
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.tar.gz"
    echo "⬇️  $url"
    curl $copts -fL --connect-timeout 30 -o "$tmp_dir/sb.tar.gz" "$url" || die "下载失败"
    tar -xzf "$tmp_dir/sb.tar.gz" -C "$tmp_dir/"
    install -m 755 "$tmp_dir/sing-box_${ver}_linux_${arch}/sing-box" /usr/bin/sing-box
  else
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box_${ver}_linux_${arch}.deb"
    echo "⬇️  $url"
    curl $copts -fL --connect-timeout 30 -o "$tmp_dir/sb.deb" "$url" || die "下载失败"
    dpkg -i "$tmp_dir/sb.deb" || { apt-get install -f -y && dpkg -i "$tmp_dir/sb.deb"; } || die "安装失败"
  fi
  info "✅ Sing-box 已安装：$($SB_BIN version | head -1)"
  _svc "$SB_SVC" is_active && { _svc "$SB_SVC" restart; info "✅ 服务已重启"; } || true
}

sb_derive_pubkey() {
  [[ -f "$SB_CONF" ]] || { warn "config.json 不存在"; return 1; }
  _require_python3
  local priv_b64url
  priv_b64url=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: c=json.load(f)
print(c['inbounds'][0]['tls']['reality']['private_key'])
" "$SB_CONF") || { warn "读取私钥失败"; return 1; }

  PRIV_B64URL="$priv_b64url" python3 <<'PYEOF'
import base64, os, subprocess, tempfile, sys
b64=os.environ['PRIV_B64URL'].replace('-','+').replace('_','/')
b64+='='*(-len(b64)%4); priv_bytes=base64.b64decode(b64)
pkcs8=bytes.fromhex("302e020100300506032b656e04220420"); der=pkcs8+priv_bytes
with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as f: f.write(der); tmp=f.name
try:
    r=subprocess.run(['openssl','pkey','-inform','DER','-in',tmp,'-pubout','-outform','DER'],capture_output=True)
    if r.returncode!=0: print(r.stderr.decode(),file=sys.stderr); sys.exit(1)
    print(base64.urlsafe_b64encode(r.stdout[-32:]).rstrip(b'=').decode())
finally: os.unlink(tmp)
PYEOF
}

sb_install() {
  printf "${CYAN}===== 安装 Sing-box 并生成配置 =====${NC}\n"

  local name sni port
  _ask "用户名称（例如 AK-JP-100G）：" name; [[ -z "$name" ]] && die "名称不能为空"
  _ask "SNI 域名（默认: s0.awsstatic.com）：" sni; sni=${sni:-s0.awsstatic.com}
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) && break
    warn "端口无效，请输入 1-65535"
  done

  sb_update_bin; hash -r
  command -v "$SB_BIN" &>/dev/null || die "sing-box 安装失败"
  _require openssl

  local uuid=$($SB_BIN generate uuid)
  local keypair=$($SB_BIN generate reality-keypair)
  local private_key=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  local pub_key=$(awk -F': ' '/PublicKey/{print $2}' <<<"$keypair")
  local short_id=$(openssl rand -hex 8)

  local net=$(_get_net)
  local dns1 dns_strategy
  if [[ "$net" == "ipv6" ]]; then dns1="2606:4700:4700::1111"; dns_strategy="prefer_ipv6"
  else dns1="8.8.8.8"; dns_strategy="prefer_ipv4"; fi

  mkdir -p "$SB_DIR"
  cat >"$SB_CONF" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "dns": { "servers": [ { "type": "tls", "server": "${dns1}", "server_port": 853, "tls": { "min_version": "1.2" } } ], "strategy": "${dns_strategy}" },
  "inbounds": [ {
    "type": "vless", "tag": "VLESSReality", "listen": "::", "listen_port": ${port},
    "users": [ { "name": "${name}", "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
    "tls": { "enabled": true, "server_name": "${sni}",
      "reality": { "enabled": true, "handshake": { "server": "${sni}", "server_port": 443 },
        "private_key": "${private_key}", "short_id": "${short_id}" } }
  } ],
  "route": { "rules": [ { "type": "default", "outbound": "direct" } ] },
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

  [[ "$DISTRO" == "alpine" ]] && sb_install_openrc
  _svc "$SB_SVC" enable; _svc "$SB_SVC" restart; sleep 2
  if _svc "$SB_SVC" is_active; then info "✅ 安装完成"; sb_show_link
  else warn "服务启动失败"; return 1; fi
}

sb_status() { printf "${CYAN}===== Sing-box 服务状态 =====${NC}\n"; _svc "$SB_SVC" status || warn "服务未安装或未运行"; }
sb_start()  { _svc "$SB_SVC" enable; _svc "$SB_SVC" start; info "✅ Sing-box 已开启"; }
sb_stop()   { _svc "$SB_SVC" stop; _svc "$SB_SVC" disable; info "✅ Sing-box 已停止"; }

sb_show_link() {
  printf "${CYAN}===== VLESS Reality 节点链接 =====${NC}\n"
  [[ -f "$SB_CONF" ]] || { warn "配置文件不存在"; return 1; }
  _require_python3

  local fields name uuid sni short_id port
  fields=$(python3 - "$SB_CONF" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: c=json.load(f)
ib=c['inbounds'][0]; r=ib['tls']['reality']
print(ib['users'][0]['name']); print(ib['users'][0]['uuid'])
print(ib['tls']['server_name']); print(r['short_id']); print(ib['listen_port'])
PYEOF
  ) || { warn "读取配置失败"; return 1; }
  mapfile -t lines <<<"$fields"
  name="${lines[0]}"; uuid="${lines[1]}"; sni="${lines[2]}"
  short_id="${lines[3]}"; port="${lines[4]}"

  local pub_key; pub_key=$(sb_derive_pubkey) || { warn "公钥推导失败"; return 1; }
  local server_ip=$(_get_ip); [[ "$server_ip" == *:* ]] && server_ip="[$server_ip]"

  local link="vless://${uuid}@${server_ip}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pub_key}&sid=${short_id}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  printf "${GREEN}%s${NC}\n\n" "$link"
  _qr_show "$link"
}

sb_uninstall() {
  printf "${CYAN}===== 卸载 Sing-box =====${NC}\n"
  _svc "$SB_SVC" stop; _svc "$SB_SVC" disable
  [[ "$DISTRO" == "alpine" ]] && rm -f /etc/init.d/sing-box || { rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload; }
  rm -rf "$SB_DIR"; rm -f /usr/bin/sing-box /usr/local/bin/sing-box
  info "✅ 卸载完成"
}
sb_reinstall() { sb_uninstall; sb_install; }

sb_change_sni() {
  printf "${CYAN}===== 更换 SNI 域名 =====${NC}\n"
  [[ -f "$SB_CONF" ]] || { warn "配置文件不存在"; return 1; }
  _require_python3
  local cur_sni
  cur_sni=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['inbounds'][0]['tls']['server_name'])" "$SB_CONF")
  local new_sni; _ask "新 SNI 域名（当前：${cur_sni}）：" new_sni
  [[ -z "$new_sni" ]] && { warn "SNI 不能为空"; return 1; }

  NEW_SNI="$new_sni" SB_CONF="$SB_CONF" python3 <<'PYEOF'
import json, os
with open(os.environ['SB_CONF']) as f: c=json.load(f)
c['inbounds'][0]['tls']['server_name']=os.environ['NEW_SNI']
c['inbounds'][0]['tls']['reality']['handshake']['server']=os.environ['NEW_SNI']
with open(os.environ['SB_CONF'],'w',encoding='utf-8') as f: json.dump(c,f,indent=2,ensure_ascii=False)
PYEOF
  _svc "$SB_SVC" restart && info "✅ SNI 已更换为 $new_sni" || warn "服务重启失败"
}

sb_export() {
  printf "${CYAN}===== 导出配置（迁移用） =====${NC}\n"
  [[ -f "$SB_CONF" ]] || { warn "配置文件不存在"; return 1; }
  _require_python3
  local bundle
  bundle=$(SB_CONF="$SB_CONF" python3 <<'PYEOF'
import json, base64, os
with open(os.environ['SB_CONF']) as f: config=json.load(f)
payload=json.dumps({"v":2,"config":config},ensure_ascii=False,separators=(',',':'))
print(base64.b64encode(payload.encode()).decode())
PYEOF
  ) || { warn "打包失败"; return 1; }
  local sep=$(printf '=%.0s' {1..64})
  printf "\n${GREEN}%s${NC}\n${BOLD}%s${NC}\n${GREEN}%s${NC}\n\n" "$sep" "$bundle" "$sep"
  warn "请复制上方文本，在新机器选「10) 导入配置」粘贴。"
}

sb_import() {
  printf "${CYAN}===== 导入配置（迁移用） =====${NC}\n"
  warn "请粘贴迁移文本，然后按 Enter："
  local bundle; read -r bundle; [[ -z "$bundle" ]] && { warn "输入为空"; return 1; }
  _require_python3
  local config_json
  config_json=$(BUNDLE="$bundle" python3 <<'PYEOF'
import json, base64, os, sys
raw=os.environ.get('BUNDLE','').strip()
if not raw: print("输入为空",file=sys.stderr); sys.exit(1)
try: payload=json.loads(base64.b64decode(raw).decode())
except Exception as e: print(f"解码失败：{e}",file=sys.stderr); sys.exit(1)
config=payload.get("config")
if not config: print("缺少 config 字段",file=sys.stderr); sys.exit(1)
for k in ("inbounds","outbounds","route"):
    if k not in config: print(f"缺少必要字段：{k}",file=sys.stderr); sys.exit(1)
print(json.dumps(config,ensure_ascii=False,indent=2))
PYEOF
  ) || { warn "迁移文本无效"; return 1; }

  command -v "$SB_BIN" &>/dev/null || sb_update_bin || die "sing-box 安装失败"
  mkdir -p "$SB_DIR"; echo "$config_json" >"$SB_CONF"; info "✅ config.json 已写入"
  python3 - "$SB_CONF" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: c=json.load(f)
c.pop('_pubkey',None)
with open(sys.argv[1],'w',encoding='utf-8') as f: json.dump(c,f,indent=2,ensure_ascii=False)
PYEOF
  [[ "$DISTRO" == "alpine" ]] && sb_install_openrc
  _svc "$SB_SVC" enable; _svc "$SB_SVC" restart && info "✅ 迁移完成！" || warn "服务启动失败"
  echo; sb_show_link
}

# ═══════════════════════════════════════════════════════════════
#  Hysteria 2 模块
# ═══════════════════════════════════════════════════════════════
HY_DIR=/etc/hysteria
HY_CONF="$HY_DIR/config.yaml"
HY_BIN=hysteria
HY_SVC=hysteria-server

_hy_ver() {
  command -v "$HY_BIN" &>/dev/null || { echo "未安装"; return; }
  local v; v=$("$HY_BIN" version 2>&1 | sed -n 's/^Version:\s*//p' | head -1) || true
  echo "${v:-已安装}"
}

hy_update_bin() {
  printf "${CYAN}===== 升级/安装 Hysteria 2 二进制 =====${NC}\n"
  [[ "$DISTRO" == "alpine" ]] && { warn "Alpine 暂不支持 Hysteria 2 一键安装"; return 1; }
  local copts=$(_curl_opt)
  printf "🌐 网络：%s  发行版：%s\n" "$(_get_net)" "$DISTRO"
  bash <(curl $copts -fsSL https://get.hy2.sh/) || die "Hysteria 2 安装失败"
  info "✅ Hysteria 2 安装成功"
}

hy_install() {
  printf "${CYAN}===== 安装 Hysteria 2 并生成配置 =====${NC}\n"

  local password port masquerade_url
  while true; do
    read -rsp "$(printf "${YELLOW}认证密码（留空随机生成）：${NC}")" password; echo
    if [[ -z "$password" ]]; then
      password=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
      info "已生成随机密码: $password"; break
    elif [[ ${#password} -ge 6 ]]; then break
    else warn "密码长度至少6位"; fi
  done
  while true; do
    _ask "监听端口（默认: 443）：" port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) && break
    warn "端口无效，请输入 1-65535"
  done
  _ask "伪装网址（默认: https://cn.bing.com/）：" masquerade_url
  masquerade_url=${masquerade_url:-https://cn.bing.com/}

  history -c 2>/dev/null || true; export HISTFILE="/dev/null"

  _require openssl
  command -v "$HY_BIN" &>/dev/null || hy_update_bin || die "Hysteria 2 安装失败"
  command -v "$HY_BIN" &>/dev/null || die "Hysteria 2 未找到"

  mkdir -p "$HY_DIR"

  printf "${CYAN}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$HY_DIR/server.key" -out "$HY_DIR/server.crt" \
    -subj "/CN=bing.com" -days 3650 || die "证书生成失败"

  cat >"$HY_CONF" <<EOF
listen: :${port}

tls:
  cert: ${HY_DIR}/server.crt
  key: ${HY_DIR}/server.key

auth:
  type: password
  password: ${password}

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
    url: ${masquerade_url}
    rewriteHost: true
EOF

  if ! chown hysteria:hysteria "$HY_DIR/server.key" "$HY_DIR/server.crt" 2>/dev/null; then
    warn "证书权限设置失败，切换为 root 运行"
    sed -i '/User=/d' /etc/systemd/system/hysteria-server.service 2>/dev/null || true
    sed -i '/User=/d' /etc/systemd/system/hysteria-server@.service 2>/dev/null || true
  fi

  if command -v ufw &>/dev/null; then
    ufw status | head -1 | grep -q inactive || { ufw allow http >/dev/null 2>&1; ufw allow https >/dev/null 2>&1; ufw allow "$port" >/dev/null 2>&1; }
  elif command -v iptables &>/dev/null; then
    iptables -L INPUT -n | grep -q "dpt:$port" || { iptables -I INPUT -p tcp --dport "$port" -j ACCEPT; iptables -I INPUT -p udp --dport "$port" -j ACCEPT; }
  fi

  sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
  sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
  grep -q "net.core.rmem_max=16777216" /etc/sysctl.conf 2>/dev/null || {
    cat >>/etc/sysctl.conf <<<'HEREDOC'

# Hysteria 2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
HEREDOC
  }

  _svc "$HY_SVC" enable; _svc "$HY_SVC" restart; sleep 2
  if _svc "$HY_SVC" is_active; then info "✅ 安装完成"; hy_show_link
  else warn "服务启动失败，请检查: journalctl -u hysteria-server.service -f"; return 1; fi
}

hy_status() { printf "${CYAN}===== Hysteria 2 服务状态 =====${NC}\n"; _svc "$HY_SVC" status || warn "服务未安装或未运行"; }
hy_start()  { _svc "$HY_SVC" enable; _svc "$HY_SVC" start; info "✅ Hysteria 2 已开启"; }
hy_stop()   { _svc "$HY_SVC" stop; _svc "$HY_SVC" disable; info "✅ Hysteria 2 已停止"; }

hy_show_link() {
  printf "${CYAN}===== Hysteria 2 节点链接 =====${NC}\n"
  [[ -f "$HY_CONF" ]] || { warn "配置文件不存在"; return 1; }

  local password port
  password=$(grep -oP 'password:\s*\K.*' "$HY_CONF" | tr -d ' ')
  port=$(grep -oP 'listen:\s*:\K[0-9]+' "$HY_CONF")
  [[ -n "$password" && -n "$port" ]] || { warn "配置解析失败"; return 1; }

  local server_ip=$(_get_ip)
  [[ -z "$server_ip" ]] && { warn "无法获取服务器 IP"; return 1; }
  [[ "$server_ip" == *:* ]] && server_ip="[$server_ip]"

  local node_name="Hysteria2-${server_ip}"
  local encoded_name
  encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$node_name'))" 2>/dev/null || echo "$node_name")

  local link="hysteria2://${password}@${server_ip}:${port}?insecure=1#${encoded_name}"
  printf "${GREEN}%s${NC}\n\n" "$link"
  _qr_show "$link"
}

hy_uninstall() {
  printf "${CYAN}===== 卸载 Hysteria 2 =====${NC}\n"
  _svc "$HY_SVC" stop; _svc "$HY_SVC" disable
  rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -rf "$HY_DIR"; rm -f /usr/local/bin/hysteria /usr/bin/hysteria
  userdel hysteria 2>/dev/null || true
  info "✅ 卸载完成"
}
hy_reinstall() { hy_uninstall; hy_install; }

# ═══════════════════════════════════════════════════════════════
#  共享功能
# ═══════════════════════════════════════════════════════════════

set_bbr() {
  sysctl net.ipv4.tcp_available_congestion_control &>/dev/null || { warn "系统不支持"; return 1; }
  local cur; cur=$(sysctl -n net.ipv4.tcp_congestion_control)
  echo "📋 可用算法：$(sysctl -n net.ipv4.tcp_available_congestion_control)"
  echo "⚡ 当前算法：$cur"
  [[ "$cur" == "bbr" ]] && { info "✅ 已在使用 BBR"; return 0; }
  local c; _ask "⚠️  是否切换为 BBR？(y/n): " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "取消"; return; }
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  if grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
    sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
  else echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf; fi
  info "✅ BBR 已启用"
}

update_self() {
  printf "${CYAN}===== 更新脚本自身 =====${NC}\n"
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/sb.sh"
  local script_path="${BASH_SOURCE[0]}"
  local tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  echo "从 $url 下载..."
  local copts=$(_curl_opt)
  if curl $copts -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
    chmod +x "$tmp"; mv "$tmp" "$script_path"
    info "✅ 脚本已更新，正在重启..."; exec bash "$script_path"
  else warn "下载失败"; fi
}

# ═══════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════
_get_net >/dev/null || true

printf "${BLUE}脚本版本：${SCRIPT_VERSION}  |  发行版：${DISTRO}  |  网络：${_NET_CACHE}${NC}\n"
printf "${BLUE}Sing-box：%s${NC}\n" "$(_sb_ver)"
printf "${BLUE}Hysteria：%s${NC}\n" "$(_hy_ver)"

while true; do
  printf "\n${BOLD}${BLUE}请选择操作：${NC}\n"
  printf "  ${YELLOW} 1)${NC} Sing-box  安装并开启服务\n"
  printf "  ${YELLOW} 2)${NC} Sing-box  查看服务状态\n"
  printf "  ${YELLOW} 3)${NC} Sing-box  显示节点链接\n"
  printf "  ${YELLOW} 4)${NC} Sing-box  开启服务\n"
  printf "  ${YELLOW} 5)${NC} Sing-box  停止服务\n"
  printf "  ${YELLOW} 6)${NC} Sing-box  卸载服务\n"
  printf "  ${YELLOW} 7)${NC} Sing-box  重新安装\n"
  printf "  ${YELLOW} 8)${NC} Sing-box  更换 SNI\n"
  printf "  ${YELLOW} 9)${NC} Sing-box  导出配置\n"
  printf "  ${YELLOW}10)${NC} Sing-box  导入配置\n"
  echo
  printf "  ${YELLOW}11)${NC} Hysteria2 安装并开启服务\n"
  printf "  ${YELLOW}12)${NC} Hysteria2 查看服务状态\n"
  printf "  ${YELLOW}13)${NC} Hysteria2 显示节点链接\n"
  printf "  ${YELLOW}14)${NC} Hysteria2 开启服务\n"
  printf "  ${YELLOW}15)${NC} Hysteria2 停止服务\n"
  printf "  ${YELLOW}16)${NC} Hysteria2 卸载服务\n"
  printf "  ${YELLOW}17)${NC} Hysteria2 重新安装\n"
  echo
  printf "  ${YELLOW}18)${NC} 设置 BBR 算法\n"
  printf "  ${YELLOW}19)${NC} 更新 Sing-box 二进制\n"
  printf "  ${YELLOW}20)${NC} 更新 Hysteria 二进制\n"
  printf "  ${YELLOW}21)${NC} 更新脚本自身\n"
  printf "  ${YELLOW} 0)${NC} 退出\n"
  printf "${BOLD}[0-21]: ${NC}"
  read -r choice; echo
  case "$choice" in
   1) sb_install ;;
   2) sb_status ;;
   3) sb_show_link ;;
   4) sb_start ;;
   5) sb_stop ;;
   6) sb_uninstall ;;
   7) sb_reinstall ;;
   8) sb_change_sni ;;
   9) sb_export ;;
  10) sb_import ;;
  11) hy_install ;;
  12) hy_status ;;
  13) hy_show_link ;;
  14) hy_start ;;
  15) hy_stop ;;
  16) hy_uninstall ;;
  17) hy_reinstall ;;
  18) set_bbr ;;
  19) sb_update_bin ;;
  20) hy_update_bin ;;
  21) update_self ;;
   0) info "退出。"; exit 0 ;;
   *) warn "无效选项" ;;
  esac
done
