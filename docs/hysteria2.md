## 安装

- 执行下面的一键安装脚本（官方）安装 Hysteria 2
```
bash <(curl -fsSL https://get.hy2.sh/)
```
- 当提示 What's next? 执行下面的命令先将 Hysteria 设置为开机自启.
```
systemctl enable hysteria-server.service
```
## 服务端配置

- 修改服务端配置文件
```
nano /etc/hysteria/config.yaml
```
将配置文件中的内容全部删除，填入以下配置。根据自己的需要选择使用 CA 证书，还是使用自签证书，将对应的注释取消即可.
```
listen: :443 #默认端口443，可以修改为其他端口

#使用CA证书
#acme:
#  domains:
#    - your.domain.net #已经解析到服务器的域名
#  email: your@email.com #你的邮箱

#使用自签证书
#tls:
#  cert: /etc/hysteria/server.crt 
#  key: /etc/hysteria/server.key 

auth:
  type: password
  password: 123456 #认证密码，使用一个强密码进行替换

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
    url: https://cn.bing.com/ #伪装网址
    rewriteHost: true
```

伪装网址推荐使用个人网盘的网址，个人网盘比较符合单节点大流量的特征，可以通过谷歌搜索 intext:登录 cloudreve 来查找别人搭建好的网盘网址.

- 可以使用以下命令生成自签证书
```
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=bing.com" -days 3650 && sudo chown hysteria /etc/hysteria/server.key && sudo chown hysteria /etc/hysteria/server.crt
```
- 启动 Hysteria
```
systemctl start hysteria-server.service
```
- 查看 Hysteria 启动状态
```
systemctl status hysteria-server.service
```
- 重新启动 Hysteria
```
systemctl restart hysteria-server.service
```
如果显示：``{"error": "invalid config: tls: open /etc/hysteria/server.crt: permission denied"}`` 或者 ``failed to load server conf`` 的错误，则说明 Hysteria 没有访问证书文件的权限，需要执行下面的命令将 Hysteria 切换到 root 用户运行
```
sed -i '/User=/d' /etc/systemd/system/hysteria-server.service
sed -i '/User=/d' /etc/systemd/system/hysteria-server@.service
systemctl daemon-reload
systemctl restart hysteria-server.service
```
## UFW 防火墙

- 查看防火墙状态
```
ufw status
```
- 开放 80 和 443 端口
```
ufw allow http && ufw allow https
```

## 性能优化

- 将发送、接收的两个缓冲区都设置为 16 MB：
```
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
```

## 实际配置

```                                         
listen: :443 #默认端口443，可以修改为其他端口

#使用CA证书
#acme:
#  domains:
#    - your.domain.net #已经解析到服务器的域名
#  email: your@email.com #你的邮箱

#使用自签证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: fwp9uy4f0912uhf #认证密码，使用一个强密码进行替换

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
    url: https://cn.bing.com/ #伪装网址
    rewriteHost: true
```