> 手动安装方法：

### 安装singbox内核
```
Debian
bash <(curl -fsSL https://sing-box.app/deb-install.sh)

Redhat
bash <(curl -fsSL https://sing-box.app/rpm-install.sh)

Archlinux
bash <(curl -fsSL https://sing-box.app/arch-install.sh)
```
默认的配置文件在路径 ``/etc/sing-box/config.json ``下,运行文件在``/usr/local/etc/sing-box/config.json`` 下。

### 生成配置文件

- UUID生成:``sing-box generate uuid``
- PrivateKey和PublicKey生成:``sing-box generate reality-keypair``
- ShortID生成:``sing-box generate rand --hex 8``
- server字段:参考本仓库server目录中的``reality_domain``

随后``nano /etc/sing-box/config.json``，依照本仓库server目录中的配置模板填写。

### 运行服务

- 启动服务
```
sudo systemctl start sing-box
```
- 停止服务
```
sudo systemctl stop sing-box
```
- 开机自启
```
sudo systemctl enable sing-box
```
- 查询运行状态
```
sudo systemctl status sing-box
```

### 导出配置

标准链接示例(更改所有<>)

```
vless://<UUID>@<IP>:<端口>?security=reality&sni=<域名>&fp=<utls浏览器指纹>&pbk=<公钥>&sid=<你的ShortID>&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#<随意填写名称>
```

- 编写完成后即可导入一个客户端,开始使用!

- 如果你想使用原生singbox客户端,参考[这里](singbox-example/client/example-node/single-node-core.yaml),即单节点配置.
