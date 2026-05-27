momo:
```json
{
  "inbounds": [
    {
      "tag": "dns-in",
      "type": "direct",
      "listen": "::",
      "listen_port": 1053
    },
    {
      "tag": "redirect-in",
      "type": "redirect",
      "listen": "::",
      "listen_port": 7890
    },
    {
      "tag": "tproxy-in",
      "type": "tproxy",
      "listen": "::",
      "listen_port": 7891
    },
    {
      "tag": "tun-in",
      "type": "tun",
      "interface_name": "momo",
      "address": ["172.31.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": false,
      "auto_redirect": false
    }
  ]
}
```
kernel:
```json
  "inbounds": [
    {
      "tag": "dns-in",
      "type": "direct",
      "listen": "127.0.0.1",
      "listen_port": 1053
    },
    {
      "tag": "tun-in",
      "type": "tun",
      "interface_name": "stun",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "mtu": 9000,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": false
    },
    {
      "type": "mixed",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
```
box:
```json
  "inbounds": [
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "listen_port": 1053
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "stun",
      "mtu": 9000,
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "auto_redirect": true,
      "include_package": [
        "de.danoeh.antennapod",
        "com.termux"
      ],
      "exclude_package": []
    },
    {
      "type": "mixed",
      "listen": "127.0.0.1",
      "listen_port": 7890
    },
    {
      "type": "redirect",
      "tag": "redirect-in",
      "listen": "::",
      "listen_port": 9797
    }
  ],
```
## 说明


- listen 字段 ``127.0.0.1`` 为仅本机 IPv4，``::1``为仅本机 IPv6，``0.0.0.0``为全部 IPv4，``::``为全部 IPv6.
- inbounds 用于定义 sing-box 接收流量的入口.
- direct 为最基础的本地监听入口，listen: "::" 表示同时监听 IPv4 与 IPv6，1053 为常见的本地 DNS 监听端口.
- redirect 用于 Linux REDIRECT 透明代理，仅支持TCP，通常配合 iptables/nftables/OpenWrt 防火墙等，内核会将 TCP 流量重定向到 sing-box 监听端口.
- tproxy 用于 Linux TProxy 透明代理，支持TCP.
- tun 用于创建 TUN 虚拟网卡,sing-box 会创建虚拟网络接口并接管系统流量,interface_name 为虚拟网卡名称,address 为分配给虚拟网卡的 IPv4/IPv6 地址.
- auto_route 用于自动添加系统路由,开启后sing-box 自动接管默认路由,一般和 auto_redirect 配合使用.
- auto_redirect 用于自动配置透明代理防火墙规则，在Linux上总是被推荐，因为它提供了更好的路由、更高的性能（比 tproxy 更好），并且避免了 TUN 和 Docker 桥接网络之间的冲突.
- strict_route 表示sing-box 是否“严格接管”系统路由，当为 True 时强制所有匹配流量必须经过 TUN，防止DNS泄露，但更容易路由冲突. 
- mixed 为 HTTP + SOCKS 混合代理入口，支持socks4、socks4a、socks5 和 http.
- include_package 和 exclude_package 用来在安卓上分应用代理.
