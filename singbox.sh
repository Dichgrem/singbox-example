#!/usr/bin/env bash
# install_singbox.sh
# 一键安装 Sing-box，并配置 VLESS Reality，自动生成字段、写入配置、创建 Systemd 服务并输出链接
set -euo pipefail
### 0. 输入名称 ###
read -rp "请输入用户名称 (name 字段，例如 AK-JP-100G)： " NAME
if [[ -z "$NAME" ]]; then
  echo "名称不能为空，退出。" >&2
  exit 1
fi
echo "使用名称：$NAME"
### 1. 安装 Sing-box 内核 ###
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
# 确定 sing-box 可执行文件
BIN_PATH=$(command -v sing-box || true)
if [[ -z "$BIN_PATH" ]]; then
  echo "未找到 sing-box，可执行文件路径异常，请检查安装" >&2
  exit 1
fi
echo "Sing-box 内核版本：$("$BIN_PATH" version | head -n1)"
### 2. 生成 UUID / Reality 密钥 / ShortID / uTLS ###
UUID=$("$BIN_PATH" generate uuid)
KEY_OUTPUT=$("$BIN_PATH" generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')
PUB_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2}')
SHORT_ID=$(openssl rand -hex 8)
FP="chrome"
### 3. 写入配置文件 ###
CONFIG_DIR=/etc/singbox
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "dns": { "servers": [{ "address": "tls://8.8.8.8" }] },
  "inbounds": [
    {
      "type": "vless",
      "tag": "VLESSReality",
      "listen": "::",
      "listen_port": 443,
      "users": [
        { "name": "$NAME", "uuid": "$UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "s0.awsstatic.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "s0.awsstatic.com", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct" }, { "type": "dns", "tag": "dns-out" } ],
  "route": { "rules": [ { "protocol": "dns", "outbound": "dns-out" } ] }
}
EOF
echo "配置已写入：$CONFIG_DIR/config.json"
### 4. 创建 Systemd 服务 ###
SERVICE_FILE=/etc/systemd/system/sing-box.service
cat > "$SERVICE_FILE" <<EOF
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
# 重载并启动
systemctl daemon-reload
systemctl enable sing-box.service
systemctl restart sing-box.service
echo "服务状态："
systemctl status sing-box.service --no-pager
### 5. 输出最终 VLESS Reality 链接 ###
SERVER_IP=$(curl -s https://ifconfig.me)
PORT=443
SNI="s0.awsstatic.com"
SPX="/"
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"
echo -e "\n====== 您的 VLESS Reality 链接 ======\n$LINK\n"