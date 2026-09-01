非kernel：
```json
{
  "route": {
    "rules": [
      {
        "action": "sniff",
        "sniffer": ["http", "tls", "quic", "dns"]
      },
      {
        "inbound": "dns-in",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-cn",
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs",
        "http_client": "rule-set-direct"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/srs/cn.srs",
        "http_client": "rule-set-direct"
      }
    ],
    "final": "GLOBAL",
    "default_http_client": "rule-set-direct",
    "default_domain_resolver": "public"
  }
}
```

### http_clients（sing-box 1.14.0 新增）

rule-set 下载通道的顶层声明（1.14 起 `download_detour` 废弃，1.16 移除），无 detour 表示系统直连下载：

```json
"http_clients": [
  {
    // 直连下载 rule-set（无 detour = 系统直连；1.14 禁止 detour 到空 direct）
    "tag": "rule-set-direct"
  }
],
```

kernel:
```json
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "port": 53,
        "action": "hijack-dns"
      },
      {
        "inbound": "dns-in",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-cn",
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      },
      {
        "action": "sniff",
        "sniffer": [
          "http",
          "tls",
          "quic",
          "dns"
        ]
      },
      {
        "outbound": "GLOBAL"
      }
    ],
```

## 说明

- sniff 字段为协议嗅探，会主动从 HTTP Header/TLS ClientHello/QUIC SNI 提取域名，这样``"rule_set": "geosite-cn"``才可以正常工作.
- tun-in 表示劫持所有经过 TUN 的 53 端口流量，因为现在越来越多应用绕过系统 DNS.momo 的配置中没有 tun-in,因为 momo 运行在 OpenWrt 路由器上，一般无法绕过.
- hijack-dns 字段为 DNS 劫持，防止 DNS 绕过 sing-box.
- ip_is_private 表示私有 IP 直连，如10.0.0.0/8和192.168.0.0/16等等.
- geosite-cn 表示中国域名直连.
- geoip-cn 表示中国 IP 直连.
- rule_set 表示从远程下载的中国域名和IP规则，使用 sing-box 原生.srs格式.
- http_client 为 rule-set 的下载通道（sing-box 1.14.0 新增，替代已废弃的 download_detour），无 detour 表示系统直连下载；default_http_client 为 route 默认下载通道，对应顶层 http_clients 中声明的 tag.
- final 为 "GLOBAL" 表示未匹配规则的流量全部走 GLOBAL，GLOBAL 又指向 selector 或者 urltest.
- 该配置效果为连接进入 sing-box -> 协议嗅探（sniff）-> DNS 劫持（hijack-dns）-> 局域网/IP直连 -> 国内域名直连 -> 国内 IP 直连 -> 其余流量走 GLOBAL.
