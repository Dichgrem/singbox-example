#!/usr/bin/env bash
# install_singbox.sh
# 版本号
SCRIPT_VERSION="1.12.21"
set -euo pipefail

# 颜色定义
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# 权限检查
if [[ $EUID -ne 0 ]]; then
  printf "${RED}错误：请以 root 用户或使用 sudo 运行此脚本${NC}\n" >&2
  exit 1
fi

# 修复：使用正确的配置目录
CONFIG_DIR=/etc/sing-box
STATE_FILE="$CONFIG_DIR/state.env"
BIN_NAME=sing-box

# 检测网络类型
detect_network_type() {
  local has_ipv4=false
  local has_ipv6=false

  # 检测IPv4
  if ping -4 -c1 -W2 8.8.8.8 &>/dev/null || curl -4 -s --connect-timeout 3 https://api.ipify.org &>/dev/null; then
    has_ipv4=true
  fi

  # 检测IPv6
  if ping -6 -c1 -W2 2001:4860:4860::8888 &>/dev/null || curl -6 -s --connect-timeout 3 https://api64.ipify.org &>/dev/null; then
    has_ipv6=true
  fi

  if $has_ipv4 && $has_ipv6; then
    echo "dual"
  elif $has_ipv6; then
    echo "ipv6"
  elif $has_ipv4; then
    echo "ipv4"
  else
    echo "none"
  fi
}

# 获取服务器IP地址
get_server_ip() {
  local network_type=$(detect_network_type)
  local ip=""

  case "$network_type" in
  "ipv6")
    # 纯IPv6环境
    ip=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null ||
      curl -6 -s --connect-timeout 5 https://ifconfig.co 2>/dev/null ||
      ip -6 addr show scope global | grep inet6 | head -n1 | awk '{print $2}' | cut -d'/' -f1)
    ;;
  "dual" | "ipv4")
    # 双栈或IPv4环境
    ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
      curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null ||
      ip -4 addr show scope global | grep inet | head -n1 | awk '{print $2}' | cut -d'/' -f1)
    ;;
  *)
    # 无法检测到网络
    ip=$(ip addr show scope global | grep -oP '(?<=inet6?\s)\S+' | head -n1 | cut -d'/' -f1)
    ;;
  esac

  echo "$ip"
}

# 检查本地与远程版本，并提示
check_update() {
  if command -v curl &>/dev/null && command -v grep &>/dev/null; then
    LOCAL_VER=$($BIN_NAME version 2>/dev/null | head -n1 | awk '{print $NF}') || LOCAL_VER="未安装"

    local network_type=$(detect_network_type)
    local curl_opts=""
    [[ "$network_type" == "ipv6" ]] && curl_opts="-6"

    LATEST_VER=$(curl $curl_opts -s --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
      grep '"tag_name"' | head -n1 | cut -d '"' -f4 | sed 's/^v//') || LATEST_VER="未知"

    if [[ "$LOCAL_VER" != "$LATEST_VER" && "$LATEST_VER" != "未知" ]]; then
      printf "${YELLOW}检测到新版本：${LATEST_VER}，当前版本：${LOCAL_VER}。请选择 8) 升级 Sing-box 二进制。${NC}\n"
    fi
  fi
}

# 安装 Sing-box 并生成配置
install_singbox() {
  printf "${CYAN}===== 安装 Sing-box 并生成配置 =====${NC}\n"
  printf "${YELLOW}请输入用户名称 (name 字段，例如 AK-JP-100G)：${NC}"
  read -r NAME
  [[ -z "$NAME" ]] && {
    printf "${RED}名称不能为空，退出。${NC}\n" >&2
    exit 1
  }
  printf "${YELLOW}请输入 SNI 域名 (默认: s0.awsstatic.com)：${NC}"
  read -r SNI
  SNI=${SNI:-s0.awsstatic.com}

  while true; do
    read -rp "请输入监听端口 (默认: 443，范围 1-65535)： " PORT
    PORT=${PORT:-443}
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
      break
    else
      printf "${RED}端口无效，请输入 1-65535 之间的数字${NC}\n"
    fi
  done

  update_singbox
  hash -r
  BIN_PATH=$(command -v $BIN_NAME || true)
  [[ -z "$BIN_PATH" ]] && {
    printf "${RED}未找到 $BIN_NAME，可执行文件路径异常，请检查安装${NC}\n" >&2
    exit 1
  }
  VERSION=$($BIN_PATH version | head -n1 | awk '{print $NF}')
  printf "${GREEN}已安装/更新 sing-box 版本：%s${NC}\n" "$VERSION"

  # 检查openssl是否安装
  if ! command -v openssl &>/dev/null; then
    printf "${RED}未安装 openssl，正在安装...${NC}\n"
    apt update && apt install -y openssl || {
      printf "${RED}openssl 安装失败${NC}\n" >&2
      exit 1
    }
  fi

  UUID=$($BIN_NAME generate uuid)
  KEY_OUTPUT=$($BIN_NAME generate reality-keypair)
  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')
  PUB_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2}')
  SHORT_ID=$(openssl rand -hex 8)
  FP="firefox"
  SERVER_IP=$(get_server_ip)
  SPX="/"

  mkdir -p "$CONFIG_DIR"

  # 根据网络类型选择 DNS
  NET_TYPE=$(detect_network_type)
  if [[ "$NET_TYPE" == "ipv6" ]]; then
    DNS_SERVER1="2606:4700:4700::1111" # Cloudflare IPv6
    DNS_SERVER2="2620:fe::fe"          # Quad9 IPv6
    DNS_STRATEGY="prefer_ipv6"
  elif [[ "$NET_TYPE" == "dual" || "$NET_TYPE" == "ipv4" ]]; then
    DNS_SERVER1="8.8.8.8"
    DNS_SERVER2="1.1.1.1"
    DNS_STRATEGY="prefer_ipv4"
  else
    DNS_SERVER1="8.8.8.8"
    DNS_SERVER2="1.1.1.1"
    DNS_STRATEGY="prefer_ipv4"
  fi

  cat >"$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "type": "tls",
        "server": "$DNS_SERVER1",
        "server_port": 853,
        "tls": { "min_version": "1.2" }
      }
    ],
    "strategy": "$DNS_STRATEGY"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESSReality",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${NAME}",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ],
  "route": {
    "rules": [
      { "type": "default", "outbound": "direct" }
    ]
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

  cat >"$STATE_FILE" <<EOF
NAME="$NAME"
SNI="$SNI"
UUID="$UUID"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
FP="$FP"
SERVER_IP="$SERVER_IP"
PORT="$PORT"
SPX="$SPX"
EOF

  systemctl enable sing-box.service
  systemctl restart sing-box.service
  printf "${GREEN}安装并启动完成，DNS 已根据网络类型自动配置。${NC}\n"
}

# 查看服务状态
status_singbox() {
  printf "${CYAN}===== Sing-box 服务状态 =====${NC}\n"
  if systemctl status sing-box.service &>/dev/null; then
    systemctl status sing-box.service --no-pager
  else
    printf "${YELLOW}服务未安装。${NC}\n"
  fi
}

# 开启服务
start_singbox() {
  systemctl daemon-reload
  systemctl enable sing-box.service 2>/dev/null || true
  systemctl start sing-box.service 2>/dev/null || true
}

# 停止服务
stop_singbox() {
  systemctl stop sing-box.service 2>/dev/null || true
  systemctl disable sing-box.service 2>/dev/null || true
  systemctl daemon-reload
}

# 显示 VLESS Reality 链接 + 二维码
show_link() {
  printf "${CYAN}===== 您的 VLESS Reality 链接 =====${NC}\n"

  # 如果状态文件不存在，尝试从 config.json 读取并生成
  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ -f "$CONFIG_DIR/config.json" ]]; then
      # 使用Python解析JSON更可靠，避免grep -P兼容性问题
      if command -v python3 &>/dev/null; then
        NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json'))['inbounds'][0]['users'][0]['name'])" 2>/dev/null)
        UUID=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json'))['inbounds'][0]['users'][0]['uuid'])" 2>/dev/null)
        SNI=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json'))['inbounds'][0]['tls']['server_name'])" 2>/dev/null)
        SHORT_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json'))['inbounds'][0]['tls']['reality']['short_id'])" 2>/dev/null)
        PORT=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json'))['inbounds'][0]['listen_port'])" 2>/dev/null)
      else
        # 回退到grep方案（使用基本正则表达式）
        NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_DIR/config.json" | head -1 | cut -d'"' -f4)
        UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_DIR/config.json" | head -1 | cut -d'"' -f4)
        SNI=$(grep -o '"server_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_DIR/config.json" | head -1 | cut -d'"' -f4)
        SHORT_ID=$(grep -o '"short_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_DIR/config.json" | head -1 | cut -d'"' -f4)
        PORT=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$CONFIG_DIR/config.json" | head -1 | grep -o '[0-9]*$')
      fi

      # reality的public_key在服务端配置中不存在，需要从private_key生成或重新获取
      # 这里尝试重新生成
      if command -v sing-box &>/dev/null; then
        PUB_KEY=$(sing-box generate reality-keypair | awk -F': ' '/PublicKey/ {print $2}' 2>/dev/null)
      fi
      [[ -z "$PUB_KEY" ]] && {
        printf "${RED}无法获取 public_key${NC}\n"
        return 1
      }

      FP="firefox"
      SERVER_IP=$(get_server_ip)
      SPX="/"

      # 检查必要字段
      [[ -z "$NAME" || -z "$UUID" || -z "$SNI" || -z "$SHORT_ID" || -z "$PORT" ]] && {
        printf "${RED}无法从配置文件读取完整信息${NC}\n"
        return 1
      }

      # 保存新的 state.env
      mkdir -p "$CONFIG_DIR"
      cat >"$STATE_FILE" <<EOF
NAME="$NAME"
SNI="$SNI"
UUID="$UUID"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
FP="$FP"
SERVER_IP="$SERVER_IP"
PORT="$PORT"
SPX="$SPX"
EOF
    else
      printf "${RED}未找到配置文件，请先安装。${NC}\n"
      return
    fi
  fi

  # 读取 state.env
  source "$STATE_FILE"

  local formatted_ip="$SERVER_IP"
  if [[ "$SERVER_IP" =~ ":" ]]; then
    formatted_ip="[$SERVER_IP]"
  fi

  LINK="vless://${UUID}@${formatted_ip}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"

  printf "${GREEN}%s${NC}\n\n" "$LINK"

  # 生成二维码
  if ! command -v qrencode &>/dev/null; then
    printf "${YELLOW}未安装 qrencode，正在自动安装...${NC}\n"
    apt install -y qrencode &>/dev/null || {
      printf "${RED}自动安装失败，请手动执行：apt install qrencode${NC}\n"
      return
    }
  fi
  printf "${CYAN}===== 二维码 =====${NC}\n"
  qrencode -t ANSIUTF8 "$LINK"
  printf "\n"
}

# 卸载 Sing-box
uninstall_singbox() {
  printf "${CYAN}===== 卸载 Sing-box =====${NC}\n"

  # 停止并禁用服务
  systemctl stop sing-box.service 2>/dev/null || true
  systemctl disable sing-box.service 2>/dev/null || true
  systemctl daemon-reload

  # 删除服务文件
  rm -f /etc/systemd/system/sing-box.service

  # 删除配置目录
  rm -rf /etc/singbox
  rm -rf /etc/sing-box

  # 删除 Sing-box 可执行文件
  rm -f /usr/bin/sing-box
  printf "${GREEN}卸载完成。${NC}\n"
}

# 重新安装
reinstall_singbox() {
  uninstall_singbox
  install_singbox
}

# 升级/安装 Sing-box 二进制
update_singbox() {
  printf "${CYAN}===== 升级/安装 Sing-box 二进制 =====${NC}\n"

  set -e -o pipefail

  # 检测体系架构
  ARCH_RAW=$(uname -m)
  case "${ARCH_RAW}" in
  'x86_64') ARCH='amd64' ;;
  'x86' | 'i686' | 'i386') ARCH='386' ;;
  'aarch64' | 'arm64') ARCH='arm64' ;;
  'armv7l') ARCH='armv7' ;;
  's390x') ARCH='s390x' ;;
  *)
    echo "❌ 不支持的架构: ${ARCH_RAW}"
    return 1
    ;;
  esac

  # 检测网络类型
  local network_type=$(detect_network_type)
  echo "🌐 当前网络模式: $network_type"

  local curl_opts=""
  case "$network_type" in
  "ipv6")
    curl_opts="-6"
    echo "📡 使用 IPv6 连接"
    ;;
  "dual")
    echo "📡 双栈网络，优先使用 IPv4"
    ;;
  "ipv4")
    curl_opts="-4"
    echo "📡 使用 IPv4 连接"
    ;;
  "none")
    echo "⚠️ 无法检测到网络连接，尝试默认方式"
    ;;
  esac

  # 获取最新版本号
  VERSION=$(curl $curl_opts -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
    grep '"tag_name"' | head -n1 | cut -d '"' -f4 | sed 's/^v//') || VERSION=""

  if [[ -z "$VERSION" ]]; then
    echo "⚠️ 获取版本失败，尝试备用源..."
    VERSION=$(curl $curl_opts -fsSL --connect-timeout 15 https://fastly.jsdelivr.net/gh/SagerNet/sing-box@latest/version.txt 2>/dev/null || echo "")
  fi

  [[ -z "$VERSION" ]] && {
    echo "❌ 无法获取最新版本号"
    return 1
  }

  echo "🔖 最新版本：v${VERSION}"
  PKG_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${ARCH}.deb"

  echo "⬇️ 正在下载 ${PKG_URL}"
  curl $curl_opts -fL --connect-timeout 30 -o /tmp/sing-box.deb "$PKG_URL" || {
    echo "❌ 下载失败，请检查网络。"
    return 1
  }

  dpkg -i /tmp/sing-box.deb || {
    echo "⚠️ dpkg 安装失败，尝试修复依赖..."
    apt-get install -f -y
    dpkg -i /tmp/sing-box.deb
  }

  rm -f /tmp/sing-box.deb

  NEW_VER=$($BIN_NAME version 2>/dev/null | head -n1 | awk '{print $NF}')
  echo "✅ Sing-box 已升级到版本：$NEW_VER"
  echo "🔁 正在重载 systemd 并重启服务..."

  systemctl daemon-reload
  if systemctl restart sing-box.service; then
    echo "✅ 服务已重启。"
  else
    echo "⚠️ 服务重启失败，请手动检查。"
  fi
}

# 更换 SNI 域名
change_sni() {
  printf "${CYAN}===== 更换 SNI 域名 =====${NC}\n"
  [[ -f "$CONFIG_DIR/config.json" ]] || {
    printf "${RED}配置文件不存在，请先安装。${NC}\n"
    return
  }

  printf "${YELLOW}请输入新的 SNI 域名 (当前: $(
    source "$STATE_FILE"
    echo "$SNI"
  ))：${NC}"
  read -r NEW_SNI
  [[ -z "$NEW_SNI" ]] && {
    printf "${RED}SNI 域名不能为空，取消更换。${NC}\n"
    return
  }

  if ! command -v python3 &>/dev/null; then
    printf "${RED}未安装 python3，无法修改配置文件${NC}\n"
    printf "${YELLOW}请手动执行：apt install -y python3${NC}\n"
    return 1
  fi

  python3 - <<EOF
import json

with open('$CONFIG_DIR/config.json', 'r') as f:
    config = json.load(f)

config['inbounds'][0]['tls']['server_name'] = '$NEW_SNI'
config['inbounds'][0]['tls']['reality']['handshake']['server'] = '$NEW_SNI'

with open('$CONFIG_DIR/config.json', 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
EOF

  [[ $? -ne 0 ]] && {
    printf "${RED}修改配置文件失败${NC}\n"
    return 1
  }

  sed -i "s/^SNI=.*/SNI=\"$NEW_SNI\"/" "$STATE_FILE"

  systemctl restart sing-box.service &&
    printf "${GREEN}SNI 已更换为 $NEW_SNI，服务已重启。${NC}\n" ||
    printf "${RED}服务重启失败，请手动检查。${NC}\n"
}

# 设置BBR算法
set_bbr() {
  if ! sysctl net.ipv4.tcp_available_congestion_control &>/dev/null; then
    echo "❌ 系统不支持 TCP 拥塞控制设置"
    return 1
  fi

  echo "📋 支持的 TCP 拥塞控制算法："
  sysctl net.ipv4.tcp_available_congestion_control

  current=$(sysctl -n net.ipv4.tcp_congestion_control)
  echo "⚡ 当前使用的算法: $current"

  if [ "$current" == "bbr" ]; then
    echo "✅ 当前已经在使用 BBR"
    return 0
  fi

  read -p "⚠️ 当前使用的不是 BBR，是否切换为 BBR？(y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # 临时生效
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    echo "✅ 已切换为 BBR（临时）"

    # 永久生效
    if ! grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
      echo "net.ipv4.tcp_congestion_control = bbr" | tee -a /etc/sysctl.conf
    else
      sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
    fi
    echo "✅ 已写入 /etc/sysctl.conf，重启后永久生效"
  else
    echo "❌ 未修改 TCP 拥塞控制算法"
  fi
}

# 更新脚本自身
update_self() {
  local script_path="${BASH_SOURCE[0]}"
  local tmp_file="/tmp/install_singbox.sh.tmp"

  printf "${CYAN}===== 更新脚本自身 =====${NC}\n"
  if command -v curl &>/dev/null; then
    local url="https://raw.githubusercontent.com/Dichgrem/singbox-example/refs/heads/main/script/singbox.sh"
    echo "从 $url 下载最新脚本..."

    # 根据网络类型选择curl参数
    local network_type=$(detect_network_type)
    local curl_opts=""
    [[ "$network_type" == "ipv6" ]] && curl_opts="-6"

    if curl $curl_opts -fsSL --connect-timeout 15 "$url" -o "$tmp_file"; then
      echo "下载成功，准备替换本地脚本..."
      chmod +x "$tmp_file"
      mv "$tmp_file" "$script_path"
      echo "脚本更新完成。"
      echo "重启脚本..."
      exec bash "$script_path"
    else
      echo "${RED}下载失败，无法更新脚本。${NC}"
      rm -f "$tmp_file"
    fi
  else
    echo "${RED}未安装 curl，无法自动更新脚本。${NC}"
  fi
}

# 菜单主循环
check_update
printf "${BLUE}当前脚本版本：${SCRIPT_VERSION}${NC}\n"

# 显示网络类型
NETWORK_TYPE=$(detect_network_type)
printf "${BLUE}检测到网络类型：${NETWORK_TYPE}${NC}\n"

# 显示 Sing-box 版本
if command -v sing-box >/dev/null 2>&1; then
  SINGBOX_VERSION=$(sing-box version 2>/dev/null | head -n 1)
else
  SINGBOX_VERSION="未安装"
fi
printf "${BLUE}当前 Sing-box 版本：${SINGBOX_VERSION}${NC}\n"

while true; do
  printf "${BOLD}${BLUE}请选择操作：${NC}\n"
  printf "  ${YELLOW}1)${NC} 安装 Sing-box&&Reality\n"
  printf "  ${YELLOW}2)${NC} 查看服务状态\n"
  printf "  ${YELLOW}3)${NC} 开启服务\n"
  printf "  ${YELLOW}4)${NC} 停止服务\n"
  printf "  ${YELLOW}5)${NC} 卸载服务\n"
  printf "  ${YELLOW}6)${NC} 显示节点链接\n"
  printf "  ${YELLOW}7)${NC} 重新安装 Sing-box\n"
  printf "  ${YELLOW}8)${NC} 升级 Sing-box 二进制\n"
  printf "  ${YELLOW}9)${NC} 更换 SNI 域名\n"
  printf "  ${YELLOW}10)${NC} 设置 BBR 算法\n"
  printf "  ${YELLOW}11)${NC} 更新脚本自身\n"
  printf "  ${YELLOW}0)${NC} 退出\n"
  printf "${BOLD}输入数字 [0-11]: ${NC}"
  read -r choice
  case "$choice" in
  1) install_singbox ;;
  2) status_singbox ;;
  3) start_singbox ;;
  4) stop_singbox ;;
  5) uninstall_singbox ;;
  6) show_link ;;
  7) reinstall_singbox ;;
  8) update_singbox ;;
  9) change_sni ;;
  10) set_bbr ;;
  11) update_self ;;
  0)
    printf "${GREEN}退出。${NC}\n"
    exit 0
    ;;
  *) printf "${RED}无效选项，请重试。${NC}\n" ;;
  esac
  echo
done
