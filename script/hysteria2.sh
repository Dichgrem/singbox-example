#!/usr/bin/env bash
# hysteria2.sh
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
CONFIG_DIR=/etc/hysteria
CONFIG_FILE="$CONFIG_DIR/config.yaml"
BIN_NAME=hysteria

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

# ─── 网络类型检测（带缓存）────────────────────────────────────
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
_svc_name="hysteria-server"
svc_enable() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-update add "$_svc_name" default 2>/dev/null || true
  else systemctl enable "$_svc_name.service"; fi
}
svc_disable() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-update del "$_svc_name" default 2>/dev/null || true
  else systemctl disable "$_svc_name.service" 2>/dev/null || true; fi
}
svc_start() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service "$_svc_name" start 2>/dev/null || true
  else
    systemctl daemon-reload
    systemctl start "$_svc_name.service" 2>/dev/null || true
  fi
}
svc_stop() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service "$_svc_name" stop 2>/dev/null || true
  else systemctl stop "$_svc_name.service" 2>/dev/null || true; fi
}
svc_restart() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service "$_svc_name" restart
  else
    systemctl daemon-reload
    systemctl restart "$_svc_name.service"
  fi
}
svc_status() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service "$_svc_name" status
  else systemctl status "$_svc_name.service" --no-pager; fi
}
svc_is_active() {
  if [[ "$DISTRO" == "alpine" ]]; then
    rc-service "$_svc_name" status &>/dev/null
  else systemctl is-active --quiet "$_svc_name.service"; fi
}

# ─── 安装/升级 Hysteria ────────────────────────────────────────
update_hysteria() {
  printf "${CYAN}===== 升级/安装 Hysteria 2 二进制 =====${NC}\n"

  if [[ "$DISTRO" == "alpine" ]]; then
    warn "Alpine 暂不支持 Hysteria 2 一键安装，请手动处理"
    return 1
  fi

  local copts
  copts=$(curl_opt)
  printf "🌐 网络：%s  发行版：%s\n" "$(get_net_type)" "$DISTRO"

  if bash <(curl "$copts" -fsSL https://get.hy2.sh/); then
    info "✅ Hysteria 2 安装成功"
  else
    die "Hysteria 2 安装失败"
  fi
}

# ─── 安装并生成配置 ───────────────────────────────────────────
install_hysteria() {
  printf "${CYAN}===== 安装 Hysteria 2 并生成配置 =====${NC}\n"

  local password port masquerade_url

  while true; do
    read -rsp "$(printf "${YELLOW}认证密码（留空随机生成）：${NC}")" password
    echo
    if [[ -z "$password" ]]; then
      password=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
      info "已生成随机密码: $password"
      break
    elif [[ ${#password} -ge 6 ]]; then
      break
    else
      warn "密码长度至少6位"
    fi
  done

  while true; do
    read -rp "$(printf "${YELLOW}监听端口（默认: 443）：${NC}")" port
    port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) && break
    warn "端口无效，请输入 1-65535"
  done

  read -rp "$(printf "${YELLOW}伪装网址（默认: https://cn.bing.com/）：${NC}")" masquerade_url
  masquerade_url=${masquerade_url:-https://cn.bing.com/}

  # 清除密码历史
  history -c 2>/dev/null || true
  export HISTFILE="/dev/null"

  command -v openssl &>/dev/null || { pkg_update && pkg_install openssl; }
  command -v "$BIN_NAME" &>/dev/null || update_hysteria || die "Hysteria 2 安装失败"
  command -v "$BIN_NAME" &>/dev/null || die "Hysteria 2 未找到"

  mkdir -p "$CONFIG_DIR"

  # 生成自签名证书
  printf "${CYAN}生成自签名证书...${NC}\n"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$CONFIG_DIR/server.key" \
    -out "$CONFIG_DIR/server.crt" \
    -subj "/CN=bing.com" -days 3650 || die "证书生成失败"

  # 写配置
  cat >"$CONFIG_FILE" <<EOF
listen: :${port}

tls:
  cert: ${CONFIG_DIR}/server.crt
  key: ${CONFIG_DIR}/server.key

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

  # 修正权限：如果 hysteria 用户无法访问证书，切换为 root 运行
  if ! chown hysteria:hysteria "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt" 2>/dev/null; then
    warn "证书权限设置失败，切换为 root 运行"
    sed -i '/User=/d' /etc/systemd/system/hysteria-server.service 2>/dev/null || true
    sed -i '/User=/d' /etc/systemd/system/hysteria-server@.service 2>/dev/null || true
  fi

  # 防火墙
  if command -v ufw &>/dev/null; then
    ufw status | head -1 | grep -q inactive || {
      ufw allow http >/dev/null 2>&1
      ufw allow https >/dev/null 2>&1
      ufw allow "$port" >/dev/null 2>&1
    }
  elif command -v iptables &>/dev/null; then
    iptables -L INPUT -n | grep -q "dpt:$port" || {
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
      iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    }
  fi

  # 性能优化
  sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
  sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
  if ! grep -q "net.core.rmem_max=16777216" /etc/sysctl.conf 2>/dev/null; then
    cat >>/etc/sysctl.conf <<'HEREDOC'

# Hysteria 2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
HEREDOC
  fi

  svc_enable
  svc_restart
  sleep 2
  if svc_is_active; then
    info "✅ 安装完成"
    show_link
  else
    warn "服务启动失败，请检查: journalctl -u hysteria-server.service -f"
    return 1
  fi
}

# ─── 状态 / 开启 / 停止 ───────────────────────────────────────
status_hysteria() {
  printf "${CYAN}===== Hysteria 2 服务状态 =====${NC}\n"
  svc_status || warn "服务未安装或未运行"
}
start_hysteria() { svc_enable && svc_start && info "✅ 服务已开启"; }
stop_hysteria() { svc_stop && svc_disable && info "✅ 服务已停止"; }

# ─── 显示节点链接 + 二维码 ────────────────────────────────────
show_link() {
  printf "${CYAN}===== Hysteria 2 节点链接 =====${NC}\n"
  [[ -f "$CONFIG_FILE" ]] || {
    warn "配置文件不存在，请先安装。"
    return 1
  }

  local password port
  password=$(grep -oP 'password:\s*\K.*' "$CONFIG_FILE" | tr -d ' ')
  port=$(grep -oP 'listen:\s*:\K[0-9]+' "$CONFIG_FILE")

  [[ -n "$password" && -n "$port" ]] || {
    warn "配置解析失败"
    return 1
  }

  local server_ip
  server_ip=$(get_server_ip)
  [[ -z "$server_ip" ]] && {
    warn "无法获取服务器 IP"
    return 1
  }
  [[ "$server_ip" == *:* ]] && server_ip="[$server_ip]"

  local node_name="Hysteria2-${server_ip}"
  local encoded_name
  encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$node_name'))" 2>/dev/null || echo "$node_name")

  local link="hysteria2://${password}@${server_ip}:${port}?insecure=1#${encoded_name}"
  printf "${GREEN}%s${NC}\n\n" "$link"

  # 二维码
  printf "${CYAN}===== 二维码 =====${NC}\n"
  LINK="$link" python3 <<'PYEOF'
import os, sys
data = os.environ['LINK']

def render_matrix(matrix):
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

try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(data)
    qr.make(fit=True)
    render_matrix(qr.get_matrix())
    sys.exit(0)
except ImportError:
    pass

try:
    import segno
    segno.make(data, error='m').terminal(compact=True)
    sys.exit(0)
except ImportError:
    pass

print("（二维码库未安装，请执行: apt install python3-qrcode）", file=sys.stderr)
PYEOF
}

# ─── 卸载 ─────────────────────────────────────────────────────
uninstall_hysteria() {
  printf "${CYAN}===== 卸载 Hysteria 2 =====${NC}\n"
  svc_stop
  svc_disable
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/hysteria-server@.service
  rm -rf "$CONFIG_DIR"
  rm -f /usr/local/bin/hysteria /usr/bin/hysteria
  userdel hysteria 2>/dev/null || true
  info "✅ 卸载完成"
}
reinstall_hysteria() {
  uninstall_hysteria
  install_hysteria
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

# ─── 更新脚本自身 ─────────────────────────────────────────────
update_self() {
  printf "${CYAN}===== 更新脚本自身 =====${NC}\n"
  local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/sb.sh"
  local script_path="${BASH_SOURCE[0]}"
  local tmp
  tmp=$(mktemp)
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
get_net_type >/dev/null || true

printf "${BLUE}脚本版本：${SCRIPT_VERSION}  |  发行版：${DISTRO}  |  网络：${_NET_TYPE_CACHE}${NC}\n"
if command -v "$BIN_NAME" &>/dev/null; then
  _hy_ver=$($BIN_NAME version 2>&1 | sed -n 's/^Version:\s*//p' | head -1) || true
  printf "${BLUE}Hysteria：${_hy_ver:-已安装}${NC}\n"
else
  printf "${BLUE}Hysteria：未安装${NC}\n"
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
  printf "  ${YELLOW} 9)${NC} 更新脚本自身\n"
  printf "  ${YELLOW}10)${NC} 更新 Hysteria 二进制\n"
  printf "  ${YELLOW} 0)${NC} 退出\n"
  printf "${BOLD}[0-10]: ${NC}"
  read -r choice
  echo
  case "$choice" in
  1) install_hysteria ;;
  2) status_hysteria ;;
  3) show_link ;;
  4) start_hysteria ;;
  5) stop_hysteria ;;
  6) uninstall_hysteria ;;
  7) reinstall_hysteria ;;
  8) set_bbr ;;
  9) update_self ;;
  10) update_hysteria ;;
  0)
    info "退出。"
    exit 0
    ;;
  *) warn "无效选项" ;;
  esac
done
