#!/usr/bin/env bash
# install_singbox.sh
# 版本号
SCRIPT_VERSION="1.12.10-alapa"
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

# 检查本地与远程版本，并提示
check_update() {
  if command -v curl &>/dev/null && command -v grep &>/dev/null; then
    LOCAL_VER=$($BIN_NAME version 2>/dev/null | head -n1 | awk '{print $NF}') || LOCAL_VER="未安装"
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest |
      grep '"tag_name"' | head -n1 | cut -d '"' -f4 | sed 's/^v//') || LATEST_VER="未知"
    if [[ "$LOCAL_VER" != "$LATEST_VER" ]]; then
      printf "${YELLOW}检测到新版本：${LATEST_VER}，当前版本：${LOCAL_VER}。请选择 6) 升级 Sing-box 二进制。${NC}\n"
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
  read -rp "请输入监听端口 (默认: 443)： " PORT
  PORT=${PORT:-443} # 如果用户没输入，则默认 443

  update_singbox
  hash -r
  BIN_PATH=$(command -v $BIN_NAME || true)
  [[ -z "$BIN_PATH" ]] && {
    printf "${RED}未找到 $BIN_NAME，可执行文件路径异常，请检查安装${NC}\n" >&2
    exit 1
  }
  VERSION=$($BIN_PATH version | head -n1 | awk '{print $NF}')
  printf "${GREEN}已安装/更新 sing-box 版本：%s${NC}\n" "$VERSION"

  UUID=$($BIN_PATH generate uuid)
  KEY_OUTPUT=$($BIN_PATH generate reality-keypair)
  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')
  PUB_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2}')
  SHORT_ID=$(openssl rand -hex 8)
  FP="firefox"
  SERVER_IP=$(curl -4 -s https://api.ipify.org)
  SPX="/"

  mkdir -p "$CONFIG_DIR"

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
        "server": "8.8.8.8",
        "server_port": 853,
        "tls": {
          "min_version": "1.2"
        }
      }
    ],
    "strategy": "prefer_ipv4"
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
      {
        "type": "default",
        "outbound": "direct"
      }
    ]
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
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
  printf "${GREEN}安装并启动完成。${NC}\n"
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
stop_singbox(){
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
      NAME=$(grep -oP '"name"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      UUID=$(grep -oP '"uuid"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      SNI=$(grep -oP '"server_name"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      PUB_KEY=$(grep -oP '"public_key"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      SHORT_ID=$(grep -oP '"short_id"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      FP="firefox"
      SERVER_IP=$(curl -s https://ifconfig.me)
      PORT=$(grep -oP '"listen_port"\s*:\s*"\K[^"]+' "$CONFIG_DIR/config.json")
      SPX="/"

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
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"

  printf "${GREEN}%s${NC}\n\n" "$LINK"

  # 生成二维码
  if command -v qrencode &>/dev/null; then
    printf "${CYAN}===== 二维码 =====${NC}\n"
    qrencode -t ANSIUTF8 "$LINK"
    printf "\n"
  else
    printf "${YELLOW}未安装 qrencode，无法生成二维码。\n"
    printf "安装方法：apt install qrencode 或 yum install qrencode${NC}\n"
  fi
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

  # 删除 env 文件
  rm -f /etc/sing-box/state.env

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
  if command -v apt-get &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/rpm-install.sh)
  elif command -v pacman &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/arch-install.sh)
  else
    printf "${RED}无法识别发行版，请手动升级 Sing-box 二进制${NC}\n" >&2
    return 1
  fi
  hash -r
  NEW_VER=$($BIN_NAME version | head -n1 | awk '{print $NF}')
  printf "${GREEN}Sing-box 已升级到版本：%s${NC}\n" "$NEW_VER"
  printf "${CYAN}重启服务...${NC}\n"
  if systemctl restart sing-box.service; then
    systemctl daemon-reload
    printf "${GREEN}服务已重启。${NC}\n"
  else
    printf "${YELLOW}服务重启失败，请手动检查。${NC}\n"
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

  # 替换 config.json 中的 SNI 字段
  sed -i "s/\"server_name\":\s*\"[^\"]*\"/\"server_name\": \"$NEW_SNI\"/" "$CONFIG_DIR/config.json"
  sed -i "s/\"server\":\s*\"[^\"]*\"/\"server\": \"$NEW_SNI\"/" "$CONFIG_DIR/config.json"

  # 替换 state.env 中的 SNI
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
        sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
        echo "✅ 已切换为 BBR（临时）"

        # 永久生效
        if ! grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.conf
        else
            sudo sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
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
    if curl -fsSL "$url" -o "$tmp_file"; then
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
