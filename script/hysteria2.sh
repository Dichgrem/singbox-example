#!/bin/bash

# Hysteria 2 自动安装配置脚本
# 支持安装、卸载和重新配置

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
DEFAULT_PORT=443
DEFAULT_MASQUERADE_URL="https://cn.bing.com/"
CONFIG_FILE="/etc/hysteria/config.yaml"
SERVICE_NAME="hysteria-server"

# 打印彩色消息
print_message() {
  local color=$1
  local message=$2
  echo -e "${color}${message}${NC}"
}

# 检查是否为root用户
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_message $RED "错误: 此脚本需要root权限运行"
    print_message $YELLOW "请使用: sudo $0"
    exit 1
  fi
}

# 检查系统要求
check_system() {
  if ! command -v curl &>/dev/null; then
    print_message $YELLOW "正在安装 curl..."
    apt update && apt install -y curl
  fi

  if ! command -v openssl &>/dev/null; then
    print_message $YELLOW "正在安装 openssl..."
    apt update && apt install -y openssl
  fi
}

# 生成随机密码
generate_password() {
  openssl rand -base64 16 | tr -d "=+/" | cut -c1-16
}

# 安装 Hysteria 2
install_hysteria() {
  print_message $BLUE "开始安装 Hysteria 2..."

  # 下载并执行官方安装脚本
  if bash <(curl -fsSL https://get.hy2.sh/); then
    print_message $GREEN "Hysteria 2 安装成功"
  else
    print_message $RED "Hysteria 2 安装失败"
    exit 1
  fi

  # 设置开机自启
  systemctl enable hysteria-server.service
  print_message $GREEN "已设置 Hysteria 2 开机自启"
}

# 生成自签名证书
generate_self_signed_cert() {
  print_message $BLUE "正在生成自签名证书..."

  # 创建配置目录
  mkdir -p /etc/hysteria

  # 生成自签名证书
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" \
    -days 3650

  # 设置文件权限
  chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt 2>/dev/null || {
    print_message $YELLOW "警告: 无法设置证书文件权限，稍后将切换到root运行模式"
    NEED_ROOT_MODE=true
  }

  print_message $GREEN "自签名证书生成完成"
}

# 创建配置文件
create_config() {
  local password=$1
  local port=$2
  local masquerade_url=$3

  print_message $BLUE "正在创建配置文件..."

  cat >$CONFIG_FILE <<EOF
listen: :${port}

# 使用自签证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

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

  print_message $GREEN "配置文件创建完成"
}

# 修复权限问题
fix_permissions() {
  if [[ "$NEED_ROOT_MODE" == "true" ]]; then
    print_message $YELLOW "正在修复权限问题，切换到root运行模式..."

    sed -i '/User=/d' /etc/systemd/system/hysteria-server.service 2>/dev/null || true
    sed -i '/User=/d' /etc/systemd/system/hysteria-server@.service 2>/dev/null || true

    systemctl daemon-reload
    print_message $GREEN "权限问题已修复"
  fi
}

# 配置防火墙
configure_firewall() {
  if command -v ufw &>/dev/null; then
    print_message $BLUE "正在配置UFW防火墙..."

    # 检查防火墙状态
    local ufw_status=$(ufw status | head -1)
    if [[ $ufw_status == *"inactive"* ]]; then
      print_message $YELLOW "UFW防火墙未启用，跳过防火墙配置"
      return
    fi

    # 开放端口
    ufw allow http >/dev/null 2>&1
    ufw allow https >/dev/null 2>&1
    ufw allow $1 >/dev/null 2>&1

    print_message $GREEN "防火墙配置完成"
  else
    print_message $YELLOW "未检测到UFW防火墙，跳过防火墙配置"
  fi
}

# 性能优化
optimize_performance() {
  print_message $BLUE "正在进行性能优化..."

  # 设置网络缓冲区
  sysctl -w net.core.rmem_max=16777216 >/dev/null
  sysctl -w net.core.wmem_max=16777216 >/dev/null

  # 写入系统配置文件持久化
  cat >>/etc/sysctl.conf <<EOF

# Hysteria 2 性能优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

  print_message $GREEN "性能优化完成"
}

# 启动服务
start_service() {
  print_message $BLUE "正在启动 Hysteria 2 服务..."

  systemctl start hysteria-server.service

  sleep 2

  if systemctl is-active --quiet hysteria-server.service; then
    print_message $GREEN "Hysteria 2 服务启动成功"
  else
    print_message $RED "Hysteria 2 服务启动失败"
    print_message $YELLOW "查看服务状态: systemctl status hysteria-server.service"
    print_message $YELLOW "查看日志: journalctl -u hysteria-server.service -f"
    return 1
  fi
}

# URL编码函数
url_encode() {
  local string="$1"
  # 尝试使用Python进行URL编码
  if command -v python3 &>/dev/null; then
    python3 -c "import urllib.parse; print(urllib.parse.quote('$string'))" 2>/dev/null
  elif command -v python &>/dev/null; then
    python -c "import urllib; print urllib.quote('$string')" 2>/dev/null
  else
    # 如果没有Python，进行简单的字符替换
    echo "$string" | sed 's/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/\*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/-/%2D/g; s/\./%2E/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/</%3C/g; s/=/%3D/g; s/>/%3E/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\\/%5C/g; s/\]/%5D/g; s/\^/%5E/g; s/_/%5F/g; s/`/%60/g; s/{/%7B/g; s/|/%7C/g; s/}/%7D/g; s/~/%7E/g'
  fi
}

# 显示连接信息
show_connection_info() {
  local password=$1
  local port=$2
  local server_ip=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP")

  # 生成节点名称（URL编码）
  local node_name="Hysteria2-${server_ip}"
  local encoded_node_name=$(url_encode "$node_name")

  # 生成 Hysteria2 标准链接
  local hysteria2_url="hysteria2://${password}@${server_ip}:${port}?insecure=1#${encoded_node_name}"

  print_message $GREEN "=============================================="
  print_message $GREEN "Hysteria 2 安装配置完成！"
  print_message $GREEN "=============================================="
  echo
  print_message $BLUE "服务器信息:"
  echo "  服务器地址: $server_ip"
  echo "  端口: $port"
  echo "  密码: $password"
  echo "  协议: hysteria2"
  echo "  TLS: 自签名证书"
  echo
  print_message $BLUE "标准连接链接:"
  print_message $GREEN "$hysteria2_url"
  echo
  print_message $BLUE "客户端配置示例:"
  echo "  server: $server_ip:$port"
  echo "  auth: $password"
  echo "  tls:"
  echo "    insecure: true"
  echo
  print_message $YELLOW "重要提示:"
  echo "  - 请妥善保存上述连接信息"
  echo "  - 客户端需要设置 insecure: true（因为使用自签名证书）"
  echo "  - 配置文件位置: $CONFIG_FILE"
  echo "  - 复制标准连接链接可直接导入支持的客户端"
  print_message $GREEN "=============================================="
}

# 卸载 Hysteria 2
uninstall_hysteria() {
  print_message $YELLOW "正在卸载 Hysteria 2..."

  # 停止服务
  systemctl stop hysteria-server.service 2>/dev/null || true
  systemctl disable hysteria-server.service 2>/dev/null || true

  # 删除服务文件
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/hysteria-server@.service
  systemctl daemon-reload

  # 删除二进制文件
  rm -f /usr/local/bin/hysteria

  # 删除配置目录
  rm -rf /etc/hysteria

  # 删除用户
  userdel hysteria 2>/dev/null || true

  print_message $GREEN "Hysteria 2 卸载完成"
}

# 检查安装状态
check_installation() {
  if command -v hysteria &>/dev/null && systemctl list-unit-files | grep -q hysteria-server; then
    return 0
  else
    return 1
  fi
}

# 主菜单
show_menu() {
  clear
  print_message $BLUE "=============================================="
  print_message $BLUE "       Dich's Hysteria 2 管理脚本"
  print_message $BLUE "=============================================="
  echo

  if check_installation; then
    echo "1. 重新配置 Hysteria 2"
    echo "2. 重启 Hysteria 2 服务"
    echo "3. 查看服务状态"
    echo "4. 查看配置信息"
    echo "5. 卸载 Hysteria 2"
    echo "0. 退出"
  else
    echo "1. 安装 Hysteria 2"
    echo "0. 退出"
  fi

  echo
}

# 获取用户输入
get_user_input() {
  # 获取密码
  while true; do
    read -p "请输入认证密码 (留空使用随机密码): " user_password
    if [[ -z "$user_password" ]]; then
      PASSWORD=$(generate_password)
      print_message $GREEN "已生成随机密码: $PASSWORD"
      break
    elif [[ ${#user_password} -ge 6 ]]; then
      PASSWORD="$user_password"
      break
    else
      print_message $RED "密码长度至少6位，请重新输入"
    fi
  done

  # 获取端口
  while true; do
    read -p "请输入监听端口 (默认443): " user_port
    if [[ -z "$user_port" ]]; then
      PORT=$DEFAULT_PORT
      break
    elif [[ "$user_port" =~ ^[0-9]+$ ]] && [ "$user_port" -ge 1 ] && [ "$user_port" -le 65535 ]; then
      PORT="$user_port"
      break
    else
      print_message $RED "请输入有效的端口号 (1-65535)"
    fi
  done

  # 获取伪装网址
  read -p "请输入伪装网址 (默认: $DEFAULT_MASQUERADE_URL): " user_masquerade
  if [[ -z "$user_masquerade" ]]; then
    MASQUERADE_URL="$DEFAULT_MASQUERADE_URL"
  else
    MASQUERADE_URL="$user_masquerade"
  fi
}

# 完整安装流程
install_process() {
  print_message $BLUE "开始 Hysteria 2 安装流程..."

  get_user_input

  check_system
  install_hysteria
  generate_self_signed_cert
  create_config "$PASSWORD" "$PORT" "$MASQUERADE_URL"
  fix_permissions
  configure_firewall "$PORT"
  optimize_performance

  if start_service; then
    show_connection_info "$PASSWORD" "$PORT"
  else
    print_message $RED "安装过程中出现错误，请检查日志"
    exit 1
  fi
}

# 重新配置流程
reconfigure_process() {
  print_message $BLUE "开始重新配置 Hysteria 2..."

  get_user_input

  systemctl stop hysteria-server.service
  create_config "$PASSWORD" "$PORT" "$MASQUERADE_URL"
  configure_firewall "$PORT"

  if start_service; then
    show_connection_info "$PASSWORD" "$PORT"
  else
    print_message $RED "重新配置过程中出现错误，请检查日志"
    exit 1
  fi
}

# 查看当前配置
show_current_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    print_message $BLUE "当前配置文件内容:"
    print_message $GREEN "=============================================="
    cat "$CONFIG_FILE"
    print_message $GREEN "=============================================="
  else
    print_message $RED "配置文件不存在"
  fi
}

# 主程序
main() {
  check_root

  while true; do
    show_menu
    read -p "请选择操作 [0-5]: " choice

    case $choice in
    1)
      if check_installation; then
        reconfigure_process
      else
        install_process
      fi
      read -p "按回车键继续..."
      ;;
    2)
      if check_installation; then
        print_message $BLUE "正在重启 Hysteria 2 服务..."
        systemctl restart hysteria-server.service
        sleep 2
        if systemctl is-active --quiet hysteria-server.service; then
          print_message $GREEN "服务重启成功"
        else
          print_message $RED "服务重启失败"
        fi
        read -p "按回车键继续..."
      else
        print_message $RED "Hysteria 2 未安装"
        read -p "按回车键继续..."
      fi
      ;;
    3)
      if check_installation; then
        print_message $BLUE "Hysteria 2 服务状态:"
        systemctl status hysteria-server.service
        read -p "按回车键继续..."
      else
        print_message $RED "Hysteria 2 未安装"
        read -p "按回车键继续..."
      fi
      ;;
    4)
      if check_installation; then
        show_current_config
        read -p "按回车键继续..."
      else
        print_message $RED "Hysteria 2 未安装"
        read -p "按回车键继续..."
      fi
      ;;
    5)
      if check_installation; then
        read -p "确定要卸载 Hysteria 2 吗？[y/N]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
          uninstall_hysteria
        else
          print_message $YELLOW "已取消卸载"
        fi
        read -p "按回车键继续..."
      else
        print_message $RED "Hysteria 2 未安装"
        read -p "按回车键继续..."
      fi
      ;;
    0)
      print_message $GREEN "退出程序"
      exit 0
      ;;
    *)
      print_message $RED "无效选择，请重新输入"
      read -p "按回车键继续..."
      ;;
    esac
  done
}

# 运行主程序
main "$@"
