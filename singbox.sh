#!/usr/bin/env bash
# install_singbox.sh
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

CONFIG_DIR=/etc/singbox
STATE_FILE="$CONFIG_DIR/state.env"
BIN_NAME=sing-box

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

  # 安装
  if command -v apt-get &>/dev/null; then
    printf "${BLUE}检测到 Debian/Ubuntu，使用官方 deb 安装脚本...${NC}\n"
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    printf "${BLUE}检测到 RHEL/CentOS，使用官方 rpm 安装脚本...${NC}\n"
    bash <(curl -fsSL https://sing-box.app/rpm-install.sh)
  elif command -v pacman &>/dev/null; then
    printf "${BLUE}检测到 Arch Linux，使用官方 arch 安装脚本...${NC}\n"
    bash <(curl -fsSL https://sing-box.app/arch-install.sh)
  else
    printf "${RED}无法识别发行版，请手动安装 Sing-box 内核${NC}\n" >&2
    exit 1
  fi

  # 确认安装路径
  hash -r
  BIN_PATH=$(command -v $BIN_NAME || true)
  [[ -z "$BIN_PATH" ]] && {
    printf "${RED}未找到 $BIN_NAME，可执行文件路径异常，请检查安装${NC}\n" >&2
    exit 1
  }
  VERSION=$($BIN_PATH version | head -n1 | awk '{print $NF}')
  printf "${GREEN}已安装 $BIN_NAME 版本：%s${NC}\n" "$VERSION"

  # 生成参数
  UUID=$($BIN_PATH generate uuid)
  KEY_OUTPUT=$($BIN_PATH generate reality-keypair)
  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')
  PUB_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2}')
  SHORT_ID=$(openssl rand -hex 8)
  FP="chrome"
  SERVER_IP=$(curl -s https://ifconfig.me)
  PORT=443
  SPX="/"

  # 写入配置和状态
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_DIR/config.json" <<EOF
{
  "log": {"level": "info"},
  "dns": {"servers": [{"address": "tls://8.8.8.8"}]},
  "inbounds": [{
    "type": "vless",
    "tag": "VLESSReality",
    "listen": "::",
    "listen_port": 443,
    "users": [{"name":"$NAME","uuid":"$UUID","flow":"xtls-rprx-vision"}],
    "tls": {"enabled":true,"server_name":"$SNI","reality":{
      "enabled":true,
      "handshake":{"server":"$SNI","server_port":443},
      "private_key":"$PRIVATE_KEY",
      "short_id":["$SHORT_ID"]
    }}
  }],
  "outbounds":[{"type":"direct"},{"type":"dns","tag":"dns-out"}],
  "route":{"rules":[{"protocol":"dns","outbound":"dns-out"}]}
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

  # 启用并启动官方 systemd 单元
  systemctl daemon-reload
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

# 显示 VLESS Reality 链接
show_link() {
  printf "${CYAN}===== 您的 VLESS Reality 链接 =====${NC}\n"
  [[ -f "$STATE_FILE" ]] || {
    printf "${RED}未找到状态文件，请先安装。${NC}\n"
    return
  }
  source "$STATE_FILE"
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"
  printf "${GREEN}%s${NC}\n\n" "$LINK"
}

# 卸载 Sing-box
uninstall_singbox() {
  printf "${CYAN}===== 卸载 Sing-box =====${NC}\n"
  if systemctl status sing-box.service &>/dev/null; then
    systemctl stop sing-box.service
    systemctl disable sing-box.service
    rm -rf "$CONFIG_DIR"
    printf "${GREEN}卸载完成：已移除配置。${NC}\n"
  else
    printf "${YELLOW}服务未安装，无需卸载。${NC}\n"
  fi
}

# 重新安装
reinstall_singbox() {
  printf "${CYAN}===== 重新安装 Sing-box =====${NC}\n"
  uninstall_singbox
  install_singbox
}

# 菜单主循环
while true; do
  printf "${BOLD}${BLUE}请选择操作：${NC}\n"
  printf "  ${YELLOW}1)${NC} 安装 Sing-box 并生成配置\n"
  printf "  ${YELLOW}2)${NC} 查看服务状态\n"
  printf "  ${YELLOW}3)${NC} 显示 VLESS Reality 链接\n"
  printf "  ${YELLOW}4)${NC} 卸载 Sing-box\n"
  printf "  ${YELLOW}5)${NC} 重新安装 Sing-box\n"
  printf "  ${YELLOW}6)${NC} 退出\n"
  printf "${BOLD}输入数字 [1-6]: ${NC}"
  read -r choice
  case "$choice" in
  1) install_singbox ;; 2) status_singbox ;; 3) show_link ;; 4) uninstall_singbox ;; 5) reinstall_singbox ;; 6)
    printf "${GREEN}退出。${NC}\n"
    exit 0
    ;;
  *) printf "${RED}无效选项，请重试。${NC}\n" ;;
  esac
  echo
done
