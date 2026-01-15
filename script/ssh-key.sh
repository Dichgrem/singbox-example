#!/bin/bash

# SSH密钥自动配置脚本
# 该脚本会生成SSH密钥对，将公钥写入服务器，并配置SSH仅允许root用户通过密钥登录

# 设置颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}此脚本必须以root身份运行${NC}"
   exit 1
fi

# 创建必要的目录
echo -e "${YELLOW}创建必要的目录...${NC}"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# 生成SSH密钥对
echo -e "${YELLOW}生成SSH密钥对...${NC}"
KEY_FILE="/root/.ssh/id_rsa"
GENERATE_KEY=true

if [ -f "$KEY_FILE" ]; then
    echo -e "${YELLOW}密钥文件 $KEY_FILE 已存在${NC}"
    read -p "是否要重新生成密钥对? (y/n): " REGENERATE
    if [ "$REGENERATE" == "y" ]; then
        echo -e "${YELLOW}重新生成密钥对...${NC}"
        KEY_FILE="/root/.ssh/id_rsa_new"
    else
        echo -e "${YELLOW}使用现有的密钥文件${NC}"
        GENERATE_KEY=false
    fi
fi

# 生成密钥对
if [ "$GENERATE_KEY" == true ]; then
    ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
    chmod 600 "$KEY_FILE"
fi

# 将公钥添加到授权文件
echo -e "${YELLOW}将公钥添加到授权文件...${NC}"
if ! grep -q -f "${KEY_FILE}.pub" /root/.ssh/authorized_keys 2>/dev/null; then
    cat "${KEY_FILE}.pub" >> /root/.ssh/authorized_keys
    echo -e "${GREEN}公钥已添加到授权文件${NC}"
else
    echo -e "${YELLOW}公钥已存在于授权文件中，跳过添加${NC}"
fi
chmod 600 /root/.ssh/authorized_keys

# 配置SSH服务器
echo -e "${YELLOW}配置SSH服务器...${NC}"
CONFIG_FILE="/etc/ssh/sshd_config"
CONFIG_BACKUP="${CONFIG_FILE}.bak"

# 备份原始配置
cp "$CONFIG_FILE" "$CONFIG_BACKUP"
echo -e "${GREEN}SSH配置已备份到 $CONFIG_BACKUP${NC}"

# 修改SSH配置
sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication no/g' "$CONFIG_FILE"
sed -i 's/^\s*#\?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$CONFIG_FILE"
sed -i 's/^\s*#\?\s*PermitRootLogin.*/PermitRootLogin prohibit-password/g' "$CONFIG_FILE"

# 确保PubkeyAuthentication设置为yes
if ! grep -q "PubkeyAuthentication yes" "$CONFIG_FILE"; then
    echo "PubkeyAuthentication yes" >> "$CONFIG_FILE"
fi

# 重启SSH服务
echo -e "${YELLOW}重启SSH服务...${NC}"
systemctl restart sshd

# 验证配置
echo -e "${YELLOW}验证SSH配置...${NC}"
VALIDATION=$(grep -E 'PasswordAuthentication|PubkeyAuthentication|PermitRootLogin' "$CONFIG_FILE")
echo -e "${GREEN}SSH配置验证结果:${NC}"
echo "$VALIDATION"

# 输出密钥信息
echo -e "${GREEN}密钥生成成功！${NC}"
echo -e "${YELLOW}私钥位置: $KEY_FILE${NC}"
echo -e "${YELLOW}公钥位置: ${KEY_FILE}.pub${NC}"
echo -e "${YELLOW}私钥内容:${NC}"
cat "$KEY_FILE"

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}配置完成! 系统现在仅允许root用户通过密钥登录。${NC}"
echo -e "${GREEN}请将你的私钥内容保存到任一SSH客户端，以备后续登录使用。${NC}"
echo -e "${GREEN}建议在新终端中测试密钥登录，确保配置正确。${NC}"
echo -e "${RED}警告: 不要关闭当前会话，直到确认可以通过密钥登录！${NC}"
echo -e "${GREEN}==================================================${NC}"