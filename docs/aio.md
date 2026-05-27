# allinone.sh 开发文档

## 概述

`allinone.sh` 是一个多协议代理统一管理脚本，集成 Reality、Hysteria2、TUIC、AnyTLS、Shadowsocks、Trojan 六种协议的安装、配置、启停、升级。模块化设计支持快速接入新协议，内置自动更新、健康检查回滚、节点链接上传等功能。

## 架构

```
基础层
├─ 颜色 / 工具函数 (die, info, warn, _ask)
├─ 发行版检测 (alpine / debian)
├─ 包管理器封装 (_pkg_i, _pkg_u)
├─ 依赖检查 (_need, _need_py)
├─ 网络检测 (_net, _co, _get_ips)
├─ 服务管理 (_svc)
├─ IP 获取 (_get_ips, 双栈独立 curl)
└─ 共享功能 (_qr, set_bbr, update_self, sb_update_bin)

协议模块（六个协议）
├─ Reality:    sb_install / sb_status / sb_show_link / ...
├─ Hysteria2:  hy_install / hy_status / hy_show_link / ...
├─ TUIC:       tuic_install / tuic_status / tuic_show_link / ...
├─ AnyTLS:     at_install / at_status / at_show_link / ...
├─ Shadowsocks:ss_install / ss_status / ss_show_link / ...
└─ Trojan:     tr_install / tr_status / tr_show_link / ...

菜单层
├─ MODULES 注册表
├─ _svc_menu (通用二级菜单引擎)
├─ 主菜单循环 + 头部信息
├─ DEV 子菜单 (自动更新, Subhatch 上传)
└─ --auto-update 无头模式
```

## 模块注册

在 `MODULES` 数组中添加一行即可注册新协议：

```bash
MODULES=(
  "sb|Reality|_sb_ver"
  "hy|Hysteria2|_hy_ver"
  "tuic|TUIC|_tuic_ver"
  "at|AnyTLS|_at_ver"
  "ss|Shadowsocks|_ss_ver"
  "tr|Trojan|_tr_ver"
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
| `xx_show_link()` | 是 | 显示节点链接 + 二维码（需同时注册到 `_collect_node_uris`） |
| `xx_uninstall()` | 是 | 卸载服务 |
| `xx_reinstall()` | 是 | 重新安装 |
| `_xx_installed()` | 否 | 检测是否已安装，主菜单头部状态显示使用 |

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
}
```

常量建议在模块顶部定义：
```bash
XXD=/etc/xx; XXC="$XXD/config.xxx"; XXB=xx-bin; XXS=xx-service
```

## Subhatch 上传

DEV 子菜单中的「上传到 Subhatch」可将服务器上已安装协议的节点链接选择性推送到 Subhatch 订阅转换服务。

### 流程

1. 读取/输入 Subhatch 地址和 Upload Token（保存到 `/etc/sing-box/.subhatch`，chmod 600）
2. `_collect_node_uris()` 扫描已安装协议配置，生成 `<proto>|<name>|<uri>` 格式的链接列表
3. 展示编号菜单（支持空格多选或 `a` 全选）
4. 调用 `POST /api/upload?token=<upload_token>` 上传
5. 服务端自动去重、处理重名、增量追加，返回新增/跳过计数

### 关键函数

| 函数 | 说明 |
|------|------|
| `_collect_node_uris()` | 读取六个协议的 config.json，计算公私钥，生成 v4/v6 双栈完整 URI |
| `_subhatch_upload()` | 读取配置、调用收集函数、展示菜单、HTTP 上传 |

### 新增协议时

需在 `_collect_node_uris()` 中新增对应的 if-block：
1. 用 python3 heredoc 从 config.json 提取连接参数
2. 生成 v4 和 v6 两条 URI，格式 `PROTO|display_name|full_uri`
3. 使用 `urllib.parse.quote` 对中文名称做 URL 编码

## 自动更新

### 手动触发

主菜单「更新内核」和「更新脚本」分别调用 `sb_update_bin` 和 `update_self`。

### 定时自动更新

DEV 子菜单「自动更新脚本和内核」(`dev_auto_update`)：
- 调用 `sb_update_bin` 更新内核（含健康检查回滚）
- `_write_timer_units` 生成 systemd timer 单元文件
- 调用 `update_self` 更新脚本自身

`--auto-update` 模式（systemd timer 触发）：
- 所有输出写入 journal（`ExecStart=/usr/local/bin/aio --auto-update`）
- Timer 配置：每天 08:00-09:00 随机触发 (`RandomizedDelaySec=3600`)
- 非交互模式，失败回退到 journal 日志
- `update_self` 在自动模式下会跳过同版本（不重复下载），手动模式始终强制更新

### 内核健康检查与自动回滚

`sb_update_bin` 更新二进制后：
1. 重启所有运行的 sing-box 服务
2. 等待 2 秒
3. 逐服务检查状态
4. 任一服务失败 → 打印 `_svc status` + `journalctl -n 15` → 恢复备份二进制 → 重启所有服务 → `warn; return 1`

备份路径：`/usr/bin/sing-box.bak`，每次更新前覆盖写入，始终保留一个已知可用版本。

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
| python3 | python3 | python3 | JSON解析、QR码、URL编码 |

### Python 库（可选，仅二维码功能需要）

| 库 | pip | Alpine | Debian | 优先级 |
|----|-----|--------|--------|--------|
| segno | `pip3 install segno` | — | — | 首选（纯 Python，零依赖） |
| qrencode | — | `apk add libqrencode` | `apt install qrencode` | 方案B（原生 C，极轻量） |
| qrcode | `pip3 install qrcode` | `apk add py3-qrcode` | `apt install python3-qrcode` | 方案C（依赖 pillow） |

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
| `raw.githubusercontent.com/.../allinone.sh` | 脚本自更新 | 任意 |
| `<subhatch>/api/upload` | 上传节点链接到 Subhatch | 任意 |

## 更新机制

1. 选择「更新脚本」→ 从 GitHub raw 下载最新版 → `exec` 替换当前进程（手动模式始终强制更新）
2. 选择「更新内核」→ GitHub API 获取最新版本 → 下载二进制 → 重启服务 → 健康检查
3. 定时自动更新 → systemd timer 每天触发 → `--auto-update` 模式 → 检测到同版本跳过
4. 旧版 `singbox.sh` / `hysteria2.sh` 的「更新脚本自身」已指向 `allinone.sh`

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 5.50.0 | 2026-05 | 新增 Subhatch 节点上传功能；内核更新后自动健康检查与回滚；`update_self` 手动模式强制更新 |
| 4.0.0 | 2026-05 | 合并 singbox + hy2；模块化二级菜单；ASCII banner |
| 3.0.0 | 2026-05 | sb.sh 初始合并版（已废弃） |
| 2.0.0 | 2026-04 | singbox.sh / hysteria2.sh 独立迭代 |
