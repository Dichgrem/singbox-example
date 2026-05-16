# allinone.sh 开发文档

## 概述

`allinone.sh` 是一个多协议代理统一管理脚本，整合 Sing-box 和 Hysteria 2 的安装、配置、启停、升级。模块化设计支持快速接入新协议。

## 架构

```
基础层
├─ 颜色 / 工具函数 (die, info, warn, _ask)
├─ 发行版检测 (alpine / debian)
├─ 包管理器封装 (_pkg_i, _pkg_u)
├─ 依赖检查 (_need)
├─ 网络检测 (_net, _co, _get_ip)
├─ 服务管理 (_svc)
└─ 共享功能 (_qr, set_bbr, update_self)

协议模块（每个协议一个 block）
├─ Sing-box: 常量 → 子函数 → install → 管理函数 → _sb_menu
├─ Hysteria 2:  同上
└─ [新协议]: 同上模板

菜单层
├─ MODULES 注册表
├─ _svc_menu (通用二级菜单引擎)
└─ 主菜单循环 + 头部信息
```

## 模块注册

在 `MODULES` 数组中添加一行即可注册新协议：

```bash
MODULES=(
  "sb|Sing-box|_sb_ver"
  "hy|Hysteria 2|_hy_ver"
  "xx|新协议名称|_xx_ver"   # 新增
)
```

格式：`"id|显示名称|版本函数名"`

## 新协议接入模板

实现以下函数即可（以 `id=xx` 为例）：

| 函数 | 必须 | 说明 |
|------|------|------|
| `_xx_ver()` | 是 | 输出已安装版本，未安装输出 `未安装` |
| `_xx_menu()` | 是 | 逐行输出 `label\|callback`，控制子菜单项 |
| `xx_install()` | 是 | 安装并生成配置、启动服务 |
| `xx_status()` | 是 | 查看服务状态 |
| `xx_start()` | 是 | 开启服务 |
| `xx_stop()` | 是 | 停止服务 |
| `xx_show_link()` | 否 | 显示节点链接 + 二维码 |
| `xx_uninstall()` | 是 | 卸载服务 |
| `xx_reinstall()` | 是 | 重新安装 |
| `xx_update_bin()` | 是 | 升级二进制 |

示例 `_xx_menu()`：
```bash
_xx_menu() {
  echo "安装并开启|xx_install"
  echo "查看状态|xx_status"
  echo "显示节点链接|xx_show_link"
  echo "开启服务|xx_start"
  echo "停止服务|xx_stop"
  echo "卸载服务|xx_uninstall"
  echo "重新安装|xx_reinstall"
  echo "升级二进制|xx_update_bin"
}
```

常量建议在模块顶部定义：
```bash
XXD=/etc/xx; XXC="$XXD/config.xxx"; XXB=xx-bin; XXS=xx-service
```

## 配置对齐检查清单

对接入新协议或修改现有模块时，需确认以下项与原脚本一致：

1. **配置文件路径** — 目录、文件名
2. **生成的配置内容** — 缩进、字段名、默认值、变量替换
3. **二进制安装方式** — 包管理器 vs 直接下载 vs 官方脚本
4. **服务名称** — systemd unit 名 / OpenRC 脚本名
5. **证书生成** — 算法、路径、权限
6. **防火墙规则** — ufw/iptables 端口
7. **DNS 地址** — IPv4/IPv6 分支
8. **网络优化** — sysctl 参数

## 依赖

### 系统包（脚本自动安装）

| 包名 | Alpine | Debian | 用途 |
|------|--------|--------|------|
| bash | 内置 | 内置 | 运行环境 |
| curl | curl | curl | 网络请求 |
| openssl | openssl | openssl | 证书生成 / 私钥运算 |
| python3 | python3 | python3 | JSON/YAML解析、QR码、URL编码 |

### Python 库（可选，仅二维码功能需要）

| 库 | pip | Alpine | Debian | 优先级 |
|----|-----|--------|--------|--------|
| qrcode | pip3 install qrcode | apk add py3-qrcode | apt install python3-qrcode | 方案A |
| segno | pip3 install segno | — | — | 方案B |

均未安装时脚本仍正常运行，二维码区域会显示安装提示。

### 外部接口

| URL | 用途 | 所需网络 |
|-----|------|----------|
| `api.ipify.org` | 获取公网 IPv4 | IPv4 |
| `api64.ipify.org` | 获取公网 IPv6 | IPv6 |
| `ifconfig.me` | 获取公网 IPv4 (fallback) | IPv4 |
| `ifconfig.co` | 获取公网 IPv6 (fallback) | IPv6 |
| `api.github.com/repos/SagerNet/sing-box/releases/latest` | Sing-box 版本检测 | 任意 |
| `github.com/SagerNet/sing-box/releases/download/*` | Sing-box 下载 | 任意 |
| `get.hy2.sh` | Hysteria 2 安装脚本 | 任意 |
| `raw.githubusercontent.com/.../allinone.sh` | 脚本自更新 | 任意 |

## 更新机制

1. 选择「更新脚本自身」→ 从 GitHub raw 下载最新版 → `exec` 替换当前进程
2. 旧版 `singbox.sh` / `hysteria2.sh` 的「更新脚本自身」已指向 `allinone.sh`

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 4.0.0 | 2026-05 | 合并 singbox + hy2；模块化二级菜单；ASCII banner |
| 3.0.0 | 2026-05 | sb.sh 初始合并版（已废弃） |
| 2.0.0 | 2026-04 | singbox.sh / hysteria2.sh 独立迭代 |
