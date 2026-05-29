# Changelog

## v5.70.5 (dev)

- 新增 ECS VPS 测评工具（DEV 功能：安装/卸载，不自动运行）
- Banner 版本行显示当前频道 `[stable]` / `[beta]`

## v5.70.0

- 新增更新频道切换（stable → main 分支，beta → dev 分支）
- 频道选择持久化到 `/etc/sing-box/.aio_channel`
- 切换后提示是否立即更新，不自动执行

## v5.60.0

- 新增 Subhatch 节点链接上传（选择性上传，配置持久化）
- 异步检查脚本和 sing-box 更新，主菜单实时提示新版本

## v5.30.0

- DEV 自动更新功能（脚本 + 内核一键更新，失败自动回退）
- systemd 定时器每日自动更新（`aio-update.timer`）

## v5.15.0

- 自动注册 `aio` 命令（symlink 到 `/usr/local/bin/aio`）
- ASCII Shadow 风格 Banner

## v5.11.0

- 异步版本检查（后台检测脚本和 sing-box 新版本）

## v5.9.0

- 新增 Trojan 协议（支持自签名 / Let's Encrypt 证书）
- Let's Encrypt ACME 集成（自动申请，失败回退自签名）

## v5.5.0

- 新增 AnyTLS Reality 协议
- 新增 Shadowsocks 协议（2022-blake3-aes-128-gcm）

## v5.2.0

- Hysteria2 切换至 sing-box 内核（原独立 hysteria 二进制）
- 节点名称嵌入配置文件

## v5.0.0

- 主菜单分离内核版本和协议安装状态显示
- 新增节点命名步骤（安装时询问节点名称）

## v4.1.0

- 新增 TUIC 协议（sing-box 内核）
- 端口冲突检测（安装前检查端口是否被占用）

## v4.0.0

- 从 `sb.sh` 重命名为 `allinone.sh`
- 模块化子菜单设计（每个协议独立操作菜单）
- 合合 sing-box + Hysteria2 为统一脚本

## v3.x 及更早

- Reality VLESS 安装/管理
- Hysteria2 安装/管理（独立 hysteria 二进制）
- BBR 设置
- 脚本自更新
- 二维码显示