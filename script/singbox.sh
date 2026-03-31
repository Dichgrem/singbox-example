#!/usr/bin/env bash
# install_singbox.sh
SCRIPT_VERSION="2.0.0"

set -uo pipefail

# ─── 颜色 ─────────────────────────────────────────────────────
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ─── 常量 ─────────────────────────────────────────────────────
CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"
BIN_NAME=sing-box

# ─── 权限检查 ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}错误：请以 root 用户或使用 sudo 运行此脚本${NC}\n" >&2
  exit 1
fi

# ─── 工具函数 ─────────────────────────────────────────────────
die() {
  printf "${RED}错误：%s${NC}\n" "$*" >&2
  exit 1
}
info() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }

require_python3() {
  command -v python3 &>/dev/null && return 0
  warn "未安装 python3，正在安装..."
  pkg_update && pkg_install python3 || die "python3 安装失败"
}

# ─── 发行版检测 ───────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/alpine-release ]]; then
    echo "alpine"
  elif command -v apt-get &>/dev/null; then
    echo "debian"
  else
    echo "unknown"
  fi
}
DISTRO=$(detect_distro)

# ─── curl 检查 ─────────────────────────────────────────────────
require_curl() {
  command -v curl &>/dev/null && return 0
  warn "未安装 curl，正在安装..."
  pkg_update && pkg_install curl || die "curl 安装失败"
}
require_curl

# ─── 网络类型检测（带缓存，整个脚本生命周期只探测一次）──────────
_NET_TYPE_CACHE=""
get_net_type() {
  if [[ -n "$_NET_TYPE_CACHE" ]]; then
    echo "$_NET_TYPE_CACHE"
    return
  fi
  local has4=false has6=false
  curl -4 -s --connect-timeout 3 https://api.ipify.org &>/dev/null && has4=true || true
  curl -6 -s --connect-timeout 3 https://api64.ipify.org &>/dev/null && has6=true || true
  if $has4 && $has6; then
    _NET_TYPE_CACHE="dual"
  elif $has6; then
    _NET_TYPE_CACHE="ipv6"
  elif $has4; then
    _NET_TYPE_CACHE="ipv4"
  else
    _NET_TYPE_CACHE="none"
  fi
  echo "$_NET_TYPE_CACHE"
}

# 纯 IPv6 时返回 "-6"，其余返回空（让系统自行选择）
curl_opt() { [[ "$(get_net_type)" == "ipv6" ]] && echo "-6" || echo ""; }

get_server_ip() {
  local net
  net=$(get_net_type)
  local ip=""
  case "$net" in
  ipv6)
    ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null ||
      curl -6 -s --connect-timeout 5 https://ifconfig.co 2>/dev/null ||
      ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)
    ;;
  dual | ipv4)
    ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
      curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null ||
      ip -4 addr show scope global | awk '/inet/{print $2}' | cut -d/ -f1 | head -1)
    ;;
  *)
    ip=$(ip addr show scope global |
      grep -oE '(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f:]+)/[0-9]+' |
      head -1 | cut -d/ -f1)
    ;;
  esac
  echo "$ip"
}

# ─── 包管理器封装 ──────────────────────────────────────────────
pkg_install() {
  if [[ "$DISTRO" == "alpine" ]]; then
    apk add --no-cache "$@"
  else
    apt-get install -y "$@"
  fi
}
pkg_update() {
  if [[ "$DISTRO" == "alpine" ]]; then
    apk update
  else
    apt-get update
  fi
}

# ─── 服务管理封装 ──────────────────────────────────────────────
svc_enable() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-update add sing-box default 2>/dev/null || true
  else systemctl enable sing-box.service; fi
}
svc_disable() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-update del sing-box default 2>/dev/null || true
  else systemctl disable sing-box.service 2>/dev/null || true; fi
}
svc_start() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service sing-box start 2>/dev/null || true
  else
    systemctl daemon-reload
    systemctl start sing-box.service 2>/dev/null || true
  fi
}
svc_stop() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service sing-box stop 2>/dev/null || true
  else systemctl stop sing-box.service 2>/dev/null || true; fi
}
svc_restart() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service sing-box restart
  else
    systemctl daemon-reload
    systemctl restart sing-box.service
  fi
}
svc_status() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service sing-box status
  else systemctl status sing-box.service --no-pager; fi
}

# ─── OpenRC init 脚本 ──────────────────────────────────────────
install_openrc_service() {
  cat >/etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after firewall; }
EOF
  chmod +x /etc/init.d/sing-box
}

# ─── 升级/安装二进制 ──────────────────────────────────────────
update_singbox() {
  printf "${CYAN}===== 升级/安装 Sing-box 二进制 =====${NC}\n"

  local arch
  case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  x86 | i686 | i386) arch=386 ;;
  aarch64 | arm64) arch=arm64 ;;
  armv7l) arch=armv7 ;;
  s390x) arch=s390x ;;
  *) die "不支持的架构: $(uname -m)" ;;
  esac

  local copts
  copts=$(curl_opt)
  echo "🌐 网络：$(get_net_type)  架构：$arch  发行版：$DISTRO"

  local ver
  ver=$(curl $copts -fsSL --connect-timeout 15 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
    grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//') || true
  [[ -z "$ver" ]] && die "无法获取最新版本号，请检查网络"
  echo "🔖 最新版本：v${ver}"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
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
    if ! dpkg -i "$tmp_dir/sb.deb"; then
      warn "dpkg 报错，尝试修复依赖..."
      apt-get install -f -y && dpkg -i "$tmp_dir/sb.deb" || die "安装失败"
    fi
  fi

  info "✅ Sing-box 已安装：$($BIN_NAME version | head -1)"

  if [[ "$DISTRO" == "alpine" ]]; then
    [[ -f /etc/init.d/sing-box ]] && { rc-service sing-box restart && info "✅ 服务已重启"; } || true
  else
    systemctl daemon-reload
    systemctl is-active --quiet sing-box.service &&
      systemctl restart sing-box.service && info "✅ 服务已重启" || true
  fi
}

# ─── 版本检查 ─────────────────────────────────────────────────
check_update() {
  local local_ver latest_ver copts
  local_ver=$($BIN_NAME version 2>/dev/null | head -1 | awk '{print $NF}') || local_ver="未安装"
  copts=$(curl_opt)
  latest_ver=$(curl $copts -s --connect-timeout 10 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
    grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//') || latest_ver=""
  if [[ -n "$latest_ver" && "$local_ver" != "$latest_ver" ]]; then
    warn "检测到新版本：$latest_ver（当前：$local_ver）→ 可选择 11) 升级"
  fi
}

# ─── 安装 ─────────────────────────────────────────────────────
install_singbox() {
  printf "${CYAN}===== 安装 Sing-box 并生成配置 =====${NC}\n"

  local name sni port
  read -rp "$(printf "${YELLOW}用户名称（例如 AK-JP-100G）：${NC}")" name
  [[ -z "$name" ]] && die "名称不能为空"

  read -rp "$(printf "${YELLOW}SNI 域名（默认: s0.awsstatic.com）：${NC}")" sni
  sni=${sni:-s0.awsstatic.com}

  while true; do
    read -rp "$(printf "${YELLOW}监听端口（默认: 443）：${NC}")" port
    port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) && break
    warn "端口无效，请输入 1-65535"
  done

  update_singbox
  hash -r
  command -v $BIN_NAME &>/dev/null || die "sing-box 安装失败"
  command -v openssl &>/dev/null || {
    pkg_update
    pkg_install openssl
  }

  local uuid keypair private_key pub_key short_id
  uuid=$($BIN_NAME generate uuid)
  keypair=$($BIN_NAME generate reality-keypair)
  private_key=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
  pub_key=$(awk -F': ' '/PublicKey/{print $2}' <<<"$keypair")
  short_id=$(openssl rand -hex 8)

  # 网络只调一次（已缓存）
  local net
  net=$(get_net_type)
  local dns1 dns_strategy
  if [[ "$net" == "ipv6" ]]; then
    dns1="2606:4700:4700::1111"
    dns_strategy="prefer_ipv6"
  else
    dns1="8.8.8.8"
    dns_strategy="prefer_ipv4"
  fi

  mkdir -p "$CONFIG_DIR"

  cat >"$CONFIG_FILE" <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "dns": {
    "servers": [
      {
        "type": "tls",
        "server": "${dns1}",
        "server_port": 853,
        "tls": { "min_version": "1.2" }
      }
    ],
    "strategy": "${dns_strategy}"
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
          "private_key": "${private_key}",
          "short_id": "${short_id}"
        }
      }
    }
  ],
  "route": { "rules": [ { "type": "default", "outbound": "direct" } ] },
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

  [[ "$DISTRO" == "alpine" ]] && install_openrc_service
  svc_enable
  svc_restart
  info "✅ 安装完成"
}

# ─── 状态 / 开启 / 停止 ───────────────────────────────────────
status_singbox() {
  printf "${CYAN}===== Sing-box 服务状态 =====${NC}\n"
  svc_status || warn "服务未安装或未运行"
}
start_singbox() {
  svc_enable
  svc_start
}
stop_singbox() {
  svc_stop
  svc_disable
}

derive_pubkey_from_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    warn "config.json 不存在"
    return 1
  }
  require_python3

  local priv_b64url
  priv_b64url=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(c['inbounds'][0]['tls']['reality']['private_key'])
" "$CONFIG_FILE") || {
    warn "读取私钥失败"
    return 1
  }

  PRIV_B64URL="$priv_b64url" python3 <<'PYEOF'
import base64, os, subprocess, tempfile, sys

b64 = os.environ['PRIV_B64URL'].replace('-', '+').replace('_', '/')
b64 += '=' * (-len(b64) % 4)
priv_bytes = base64.b64decode(b64)

# X25519 PKCS8 DER = 固定16字节头 + 32字节私钥
pkcs8_header = bytes.fromhex("302e020100300506032b656e04220420")
der = pkcs8_header + priv_bytes

with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as f:
    f.write(der)
    tmpfile = f.name

try:
    r = subprocess.run(
        ['openssl', 'pkey', '-inform', 'DER', '-in', tmpfile, '-pubout', '-outform', 'DER'],
        capture_output=True
    )
    if r.returncode != 0:
        print(r.stderr.decode(), file=sys.stderr); sys.exit(1)
    # DER 公钥最后 32 字节是 raw public key
    print(base64.urlsafe_b64encode(r.stdout[-32:]).rstrip(b'=').decode())
finally:
    os.unlink(tmpfile)
PYEOF
}

# ─── 显示节点链接 + 二维码 ────────────────────────────────────
show_link() {
  printf "${CYAN}===== VLESS Reality 节点链接 =====${NC}\n"
  [[ -f "$CONFIG_FILE" ]] || {
    warn "未找到配置文件，请先安装。"
    return 1
  }
  require_python3

  local fields
  fields=$(
    python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
ib = c['inbounds'][0]
r  = ib['tls']['reality']
print(ib['users'][0]['name'])
print(ib['users'][0]['uuid'])
print(ib['tls']['server_name'])
print(r['short_id'])
print(ib['listen_port'])
PYEOF
  ) || {
    warn "读取配置失败"
    return 1
  }

  local name uuid sni short_id port
  mapfile -t lines <<<"$fields"
  name="${lines[0]}"
  uuid="${lines[1]}"
  sni="${lines[2]}"
  short_id="${lines[3]}"
  port="${lines[4]}"

  local pub_key
  pub_key=$(derive_pubkey_from_config) || {
    warn "公钥推导失败，请检查 config.json 是否完整。"
    return 1
  }

  local server_ip
  server_ip=$(get_server_ip)
  [[ "$server_ip" == *:* ]] && server_ip="[$server_ip]"

  local link="vless://${uuid}@${server_ip}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pub_key}&sid=${short_id}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${name}"
  printf "${GREEN}%s${NC}\n\n" "$link"

  printf "${CYAN}===== 二维码 =====${NC}\n"
  LINK="$link" python3 <<'PYEOF'
import os, sys
data = os.environ['LINK']

def render_matrix(matrix):
    """用半块字符渲染，两行像素合并一个字符行，输出更紧凑"""
    if len(matrix) % 2:
        matrix.append([False] * len(matrix[0]))
    for i in range(0, len(matrix), 2):
        line = ''
        for j in range(len(matrix[0])):
            top, bot = matrix[i][j], matrix[i+1][j]
            if   top and bot:  line += '\u2588'
            elif top:          line += '\u2580'
            elif bot:          line += '\u2584'
            else:              line += ' '
        print(line)

# 方案 A：qrcode 库（pip3 install qrcode 或 apk add py3-qrcode）
try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(data)
    qr.make(fit=True)
    render_matrix(qr.get_matrix())
    sys.exit(0)
except ImportError:
    pass

# 方案 B：segno 库（pip3 install segno）
try:
    import segno
    segno.make(data, error='m').terminal(compact=True)
    sys.exit(0)
except ImportError:
    pass

# 均未安装：提示用户
print("（二维码库未安装，无法显示二维码）", file=sys.stderr)
if os.path.exists('/etc/alpine-release'):
    print("  Alpine 安装：apk add py3-qrcode", file=sys.stderr)
else:
    print("  Debian 安装：apt install python3-qrcode", file=sys.stderr)
PYEOF
}

# ─── 卸载 ─────────────────────────────────────────────────────
uninstall_singbox() {
  printf "${CYAN}===== 卸载 Sing-box =====${NC}\n"
  svc_stop
  svc_disable
  if [[ "$DISTRO" == "alpine" ]]; then
    rm -f /etc/init.d/sing-box
  else
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
  fi
  rm -rf "$CONFIG_DIR"
  rm -f /usr/bin/sing-box /usr/local/bin/sing-box
  info "✅ 卸载完成"
}
reinstall_singbox() {
  uninstall_singbox
  install_singbox
}

# ─── 更换 SNI ─────────────────────────────────────────────────
change_sni() {
  printf "${CYAN}===== 更换 SNI 域名 =====${NC}\n"
  [[ -f "$CONFIG_FILE" ]] || {
    warn "配置文件不存在，请先安装。"
    return 1
  }
  require_python3

  # 读取当前 SNI
  local cur_sni
  cur_sni=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['inbounds'][0]['tls']['server_name'])" "$CONFIG_FILE")

  local new_sni
  read -rp "$(printf "${YELLOW}新 SNI 域名（当前：%s）：${NC}" "$cur_sni")" new_sni
  [[ -z "$new_sni" ]] && {
    warn "SNI 不能为空，取消。"
    return 1
  }

  # 通过环境变量传参，彻底避免 shell 注入
  NEW_SNI="$new_sni" CONFIG_FILE="$CONFIG_FILE" python3 <<'PYEOF'
import json, os
path = os.environ['CONFIG_FILE']
new_sni = os.environ['NEW_SNI']
with open(path) as f:
    c = json.load(f)
c['inbounds'][0]['tls']['server_name'] = new_sni
c['inbounds'][0]['tls']['reality']['handshake']['server'] = new_sni
with open(path, 'w', encoding='utf-8') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF

  svc_restart && info "✅ SNI 已更换为 $new_sni，服务已重启" || warn "服务重启失败，请手动检查"
}

# ─── BBR ──────────────────────────────────────────────────────
set_bbr() {
  sysctl net.ipv4.tcp_available_congestion_control &>/dev/null || {
    warn "系统不支持 TCP 拥塞控制设置"
    return 1
  }
  local current
  current=$(sysctl -n net.ipv4.tcp_congestion_control)
  echo "📋 可用算法：$(sysctl -n net.ipv4.tcp_available_congestion_control)"
  echo "⚡ 当前算法：$current"
  [[ "$current" == "bbr" ]] && {
    info "✅ 已在使用 BBR"
    return 0
  }

  local confirm
  read -rp "⚠️  是否切换为 BBR？(y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    if grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
      sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
    else
      echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
    fi
    info "✅ BBR 已启用，重启后永久生效"
  else
    echo "取消"
  fi
}

# ─── 导出配置（迁移） ─────────────────────────────────────────
export_config() {
  printf "${CYAN}===== 导出配置（迁移用） =====${NC}\n"
  [[ -f "$CONFIG_FILE" ]] || {
    warn "未找到配置文件，请先安装。"
    return 1
  }
  require_python3

  local bundle
  bundle=$(
    CONFIG_FILE="$CONFIG_FILE" python3 <<'PYEOF'
import json, base64, os
with open(os.environ['CONFIG_FILE']) as f:
    config = json.load(f)
payload = json.dumps({"v": 2, "config": config}, ensure_ascii=False, separators=(',', ':'))
print(base64.b64encode(payload.encode()).decode())
PYEOF
  ) || {
    warn "打包失败，请确认 python3 已安装"
    return 1
  }

  local sep
  sep=$(printf '=%.0s' {1..64})
  printf "\n${GREEN}%s${NC}\n${BOLD}%s${NC}\n${GREEN}%s${NC}\n\n" "$sep" "$bundle" "$sep"
  warn "请完整复制上方一行文本，在新机器选「13) 导入配置」粘贴即可。"
}

# ─── 导入配置（迁移） ─────────────────────────────────────────
import_config() {
  printf "${CYAN}===== 导入配置（迁移用） =====${NC}\n"
  warn "请粘贴迁移文本，然后按 Enter："
  local bundle
  read -r bundle
  [[ -z "$bundle" ]] && {
    warn "输入为空，取消。"
    return 1
  }
  require_python3

  local config_json
  config_json=$(
    BUNDLE="$bundle" python3 <<'PYEOF'
import json, base64, os, sys

raw = os.environ.get('BUNDLE', '').strip()
if not raw:
    print("输入为空", file=sys.stderr); sys.exit(1)

try:
    payload = json.loads(base64.b64decode(raw).decode())
except Exception as e:
    print(f"解码失败：{e}", file=sys.stderr); sys.exit(1)

config = payload.get("config")
if not config:
    print("缺少 config 字段", file=sys.stderr); sys.exit(1)

for k in ("inbounds", "outbounds", "route"):
    if k not in config:
        print(f"配置缺少必要字段：{k}", file=sys.stderr); sys.exit(1)

print(json.dumps(config, ensure_ascii=False, indent=2))
PYEOF
  ) || {
    warn "迁移文本无效或已损坏，请重新导出。"
    return 1
  }

  command -v sing-box &>/dev/null || {
    warn "未检测到 sing-box，开始安装..."
    update_singbox || die "sing-box 安装失败，中止导入"
  }

  mkdir -p "$CONFIG_DIR"
  echo "$config_json" >"$CONFIG_FILE"
  info "✅ config.json 已写入"

  python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
c.pop('_pubkey', None)
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF

  [[ "$DISTRO" == "alpine" ]] && install_openrc_service
  svc_enable
  svc_restart && info "✅ 服务已启动，迁移完成！" || warn "服务启动失败，请运行「2) 查看状态」排查"
  echo
  show_link
}

# ─── 更新脚本自身 ─────────────────────────────────────────────
update_self() {
  printf "${CYAN}===== 更新脚本自身 =====${NC}\n"
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/singbox.sh"
  local script_path="${BASH_SOURCE[0]}"
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  echo "从 $url 下载..."
  local copts
  copts=$(curl_opt)
  if curl $copts -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
    chmod +x "$tmp"
    mv "$tmp" "$script_path"
    info "✅ 脚本已更新，正在重启..."
    exec bash "$script_path"
  else
    warn "下载失败，无法更新脚本。"
  fi
}

# ─── 主菜单 ───────────────────────────────────────────────────
get_net_type >/dev/null || true # 启动时探测一次，结果缓存
check_update

printf "${BLUE}脚本版本：${SCRIPT_VERSION}  |  发行版：${DISTRO}  |  网络：${_NET_TYPE_CACHE}${NC}\n"
if command -v sing-box &>/dev/null; then
  printf "${BLUE}Sing-box：$(sing-box version 2>/dev/null | head -1)${NC}\n"
else
  printf "${BLUE}Sing-box：未安装${NC}\n"
fi

while true; do
  printf "\n${BOLD}${BLUE}请选择操作：${NC}\n"
  printf "  ${YELLOW} 1)${NC} 安装并开启服务\n"
  printf "  ${YELLOW} 2)${NC} 查看服务状态\n"
  printf "  ${YELLOW} 3)${NC} 显示节点链接\n"
  printf "  ${YELLOW} 4)${NC} 开启服务\n"
  printf "  ${YELLOW} 5)${NC} 停止服务\n"
  printf "  ${YELLOW} 6)${NC} 卸载服务\n"
  printf "  ${YELLOW} 7)${NC} 重新安装\n"
  printf "  ${YELLOW} 8)${NC} 设置 BBR 算法\n"
  printf "  ${YELLOW} 9)${NC} 更换 SNI 字段 \n"
  printf "  ${YELLOW}10)${NC} 更新脚本自身\n"
  printf "  ${YELLOW}11)${NC} 更新 Sing-box 二进制\n"
  printf "  ${YELLOW}12)${NC} 导出配置（迁移到新机器）\n"
  printf "  ${YELLOW}13)${NC} 导入配置（从旧机器迁移）\n"
  printf "  ${YELLOW} 0)${NC} 退出\n"
  printf "${BOLD}[0-13]: ${NC}"
  read -r choice
  echo
  case "$choice" in
  1) install_singbox ;;
  2) status_singbox ;;
  3) show_link ;;
  4) start_singbox ;;
  5) stop_singbox ;;
  6) uninstall_singbox ;;
  7) reinstall_singbox ;;
  8) set_bbr ;;
  9) change_sni ;;
  10) update_self ;;
  11) update_singbox ;;
  12) export_config ;;
  13) import_config ;;
  0)
    info "退出。"
    exit 0
    ;;
  *) warn "无效选项" ;;
  esac
done
