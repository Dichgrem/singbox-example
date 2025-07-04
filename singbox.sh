#!/usr/bin/env bash
# install_singbox.sh
# 一键安装 Sing-box，并配置 VLESS Reality，支持菜单操作：安装、状态、显示链接、卸载、重装
set -euo pipefail

CONFIG_DIR=/etc/singbox
SERVICE_FILE=/etc/systemd/system/sing-box.service
STATE_FILE="$CONFIG_DIR/state.env"
BIN_NAME=sing-box

# 函数：安装 Sing-box 并生成配置
install_singbox() {
  # 0. 输入名称 & SNI
  read -rp "请输入用户名称 (name 字段，例如 AK-JP-100G)： " NAME
  [[ -z "$NAME" ]] && {
    echo "名称不能为空，退出。" >&2
    exit 1
  }
  read -rp "请输入 SNI 域名 (默认: s0.awsstatic.com)： " SNI
  SNI=${SNI:-s0.awsstatic.com}

  # 1. 安装 Sing-box
  if command -v apt-get &>/dev/null; then
    echo "检测到 Debian/Ubuntu，使用官方 deb 安装脚本..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    echo "检测到 RHEL/CentOS，使用官方 rpm 安装脚本..."
    bash <(curl -fsSL https://sing-box.app/rpm-install.sh)
  elif command -v pacman &>/dev/null; then
    echo "检测到 Arch Linux，使用官方 arch 安装脚本..."
    bash <(curl -fsSL https://sing-box.app/arch-install.sh)
  else
    echo "无法识别发行版，请手动安装 Sing-box 内核" >&2
    exit 1
  fi
  BIN_PATH=$(command -v $BIN_NAME)
  [[ -z "$BIN_PATH" ]] && {
    echo "未找到 $BIN_NAME，可执行文件路径异常，请检查安装" >&2
    exit 1
  }
  echo "已安装 $BIN_NAME 版本：$($BIN_PATH version | head -n1)"

  # 2. 生成 UUID / Reality 密钥 / ShortID / uTLS
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

  # 4. 创建并启动 Systemd 服务
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONFIG_DIR/config.json
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box.service
  systemctl restart sing-box.service
  echo "安装并启动完成。"
}

# 函数：显示服务状态
status_singbox() {
  if systemctl list-units --full -all | grep -q sing-box.service; then
    systemctl status sing-box.service --no-pager
  else
    echo "服务未安装。"
  fi
}

# 函数：显示 VLESS Reality 链接
show_link() {
  [[ -f "$STATE_FILE" ]] || {
    echo "未找到状态文件，请先安装。"
    return
  }
  source "$STATE_FILE"
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"
  echo -e "\n====== 您的 VLESS Reality 链接 ======\n$LINK\n"
}

# 函数：卸载 Sing-box
uninstall_singbox() {
  if systemctl list-units --full -all | grep -q sing-box.service; then
    systemctl stop sing-box.service
    systemctl disable sing-box.service
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    echo "卸载完成：已移除配置和服务。"
  else
    echo "服务未安装，无需卸载。"
  fi
}

# 函数：重新安装
reinstall_singbox() {
  uninstall_singbox
  install_singbox
}

# 菜单主循环
while true; do
  cat <<EOF
请选择操作：
 1) 安装 Sing-box 并生成配置
 2) 查看服务状态
 3) 显示 VLESS Reality 链接
 4) 卸载 Sing-box
 5) 重新安装 Sing-box
 6) 退出
EOF
  read -rp "输入数字 [1-6]: " choice
  case "$choice" in
  1) install_singbox ;;
  2) status_singbox ;;
  3) show_link ;;
  4) uninstall_singbox ;;
  5) reinstall_singbox ;;
  6)
    echo "退出。"
    exit 0
    ;;
  *) echo "无效选项，请重试。" ;;
  esac
done

