#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 检查并安装必要的依赖
for cmd in curl wget tar jq; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}未找到命令：$cmd，正在安装...${NC}"
    apt update && apt install -y $cmd
  fi
done

# 获取最新版本的 Sing-box
echo -e "${GREEN}获取 Sing-box 最新版本...${NC}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo -e "${RED}不支持的架构：$ARCH${NC}"; exit 1 ;;
esac
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"

# 下载并解压
echo -e "${GREEN}下载并解压 Sing-box...${NC}"
mkdir -p /tmp/singbox_install
cd /tmp/singbox_install
curl -L -o singbox.tar.gz "$DOWNLOAD_URL"
tar -xzf singbox.tar.gz
cd sing-box-*

# 安装 Sing-box
echo -e "${GREEN}安装 Sing-box...${NC}"
install -m 755 sing-box /usr/local/bin/sing-box

# 创建配置目录
mkdir -p /usr/local/etc/sing-box

# 生成配置所需的参数
echo -e "${GREEN}生成配置参数...${NC}"
UUID=$(sing-box generate uuid)
KEY_PAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(openssl rand -hex 8)
SERVER_IP=$(curl -s https://api.ipify.org)
read -rp "请输入用户名称（用于链接显示）： " NAME
SNI="s0.awsstatic.com"
FINGERPRINT="chrome"

# 创建配置文件
echo -e "${GREEN}创建配置文件...${NC}"
cat > /usr/local/etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "address": "tls://8.8.8.8"
      }
    ]
  },
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
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ]
  }
}
EOF

# 创建 systemd 服务
echo -e "${GREEN}创建 systemd 服务...${NC}"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 启动并启用服务
echo -e "${GREEN}启动 Sing-box 服务...${NC}"
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box

# 输出连接信息
echo -e "${GREEN}您的 VLESS Reality 链接：${NC}"
echo -e "vless://${UUID}@${SERVER_IP}:443?security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${NAME}"
