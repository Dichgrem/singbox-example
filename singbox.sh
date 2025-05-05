#!/usr/bin/env bash
# install_singbox.sh
# 一键安装 sing-box 并配置为 systemd 服务，自动生成 VLESS Reality 所需字段，并允许用户自定义 name 字段，同时输出完整订阅链接

set -euo pipefail

### —— 0. 用户输入 —— ###
read -rp "请输入用户名称 (name 字段，例如 AK-JP-100G)：" NAME
if [[ -z "$NAME" ]]; then
  echo "名称不能为空，退出。" >&2
  exit 1
fi

echo "将使用的 name 字段：${NAME}"

### —— 1. 检查并安装依赖 —— ###
install_deps_debian() {
  apt-get update
  apt-get install -y curl jq tar openssl
}
install_deps_centos() {
  yum install -y epel-release
  yum install -y curl jq tar openssl
}

if command -v apt-get &>/dev/null; then
  echo "检测到 apt 包管理器，使用 Debian/Ubuntu 安装依赖..."
  install_deps_debian
elif command -v yum &>/dev/null; then
  echo "检测到 yum 包管理器，使用 CentOS/RHEL 安装依赖..."
  install_deps_centos
else
  echo "不支持的包管理器，请手动安装 curl jq tar openssl" >&2
  exit 1
fi

### —— 2. 获取最新版本 & 架构 —— ###
echo "获取 sing-box 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
echo "最新版本：${LATEST_TAG}"

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7*|armhf) ARCH=armv7 ;;
  *) echo "不支持的架构：${ARCH}" >&2; exit 1 ;;
esac
echo "CPU 架构：${ARCH}"

### —— 3. 下载并安装 sing-box —— ###
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${LATEST_TAG:1}-linux-${ARCH}.tar.gz"
echo "下载链接：${DOWNLOAD_URL}"

curl -L "${DOWNLOAD_URL}" -o /tmp/singbox.tar.gz

echo "解压并安装到 /usr/local/bin..."

tar -zxf /tmp/singbox.tar.gz -C /tmp
install -m 755 /tmp/sing-box /usr/local/bin/sing-box

### —— 4. 自动生成示例配置 —— ###
echo "生成 VLESS Reality 所需字段..."
UUID=$(sing-box generate uuid)
echo "UUID: ${UUID}"
PRIVATE_KEY=$(sing-box generate reality-key)
echo "Private Key: ${PRIVATE_KEY}"
# 有些版本 sing-box 还支持直接生成公钥，如未支持可手动填写
PUB_KEY=$(sing-box generate reality-public-key || echo "")
echo "Public Key: ${PUB_KEY}"
SHORT_ID=$(sing-box generate short-id)
echo "Short ID: ${SHORT_ID}"
# utls 浏览器指纹
FP=$(sing-box generate utls-fingerprint || echo "")
echo "Browser Fingerprint: ${FP}"

CONFIG_DIR=/etc/singbox
mkdir -p "${CONFIG_DIR}"

echo "生成配置文件 ${CONFIG_DIR}/config.json..."
cat > "${CONFIG_DIR}/config.json" << EOF
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
        {
          "name": "${NAME}",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "s0.awsstatic.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "s0.awsstatic.com",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct" }, { "type": "dns", "tag": "dns-out" } ],
  "route": { "rules": [ { "protocol": "dns", "outbound": "dns-out" } ] }
}
EOF

echo "配置文件已生成：${CONFIG_DIR}/config.json"

### —— 5. 创建 systemd 服务 —— ###
SERVICE_PATH=/etc/systemd/system/singbox.service
cat > "${SERVICE_PATH}" << 'EOF'
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/singbox/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "systemd 服务已生成：${SERVICE_PATH}"

### —— 6. 启用并启动服务 —— ###
echo "重载 systemd 配置..."
systemctl daemon-reload
echo "启用开机自启..."
systemctl enable singbox.service
echo "启动服务..."
systemctl start singbox.service

### —— 7. 输出最终链接 —— ###
echo
SERVER_IP=$(curl -s https://ifconfig.me)
PORT=443
SNI="s0.awsstatic.com"
SPX="/"
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SNI}&fp=${FP}&pbk=${PUB_KEY}&sid=${SHORT_ID}&spx=${SPX}&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"
echo "您的 VLESS Reality 链接："
echo "$LINK"
