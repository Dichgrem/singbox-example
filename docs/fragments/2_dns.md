FakeIP：
```json
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "local",
        "server": "223.5.5.5"
      },
      {
        "type": "https",
        "tag": "public",
        "domain_resolver": "local",
        "server": "dns.alidns.com"
      },
      {
        "type": "https",
        "tag": "foreign",
        "detour": "Server1",
        "server": "8.8.8.8"
      },
      {
        "type": "fakeip",
        "tag": "fakeip",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "server": "local"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip",
        "rewrite_ttl": 1
      }
    ],
    "final": "foreign",
    "strategy": "prefer_ipv4",
    "independent_cache": true
  }
}
```
RealIP：
```json
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "udp",
        "server": "223.5.5.5"
      },
      {
        "tag": "public",
        "type": "https",
        "server": "dns.alidns.com",
        "domain_resolver": "local"
      },
      {
        "tag": "foreign",
        "type": "https",
        "server": "8.8.8.8",
        "detour": "Server1"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "server": "public"
      }
    ],
    "final": "foreign",
    "strategy": "prefer_ipv4",
    "independent_cache": true,
    "reverse_mapping": true
  },
```

## 说明

- servers 为 DNS 服务器，国内 UDP 使用阿里的``223.5.5.5``或腾讯的``119.29.29.29``，HTTPS 使用阿里的``dns.alidns.com``或腾讯的``doh.pub``,国外使用谷歌的``8.8.8.8``或者 Cloudflare 的``1.1.1.1``.
- domain_resolver 为 local 表示先用 local DNS 解析 dns.alidns.com，否则会陷入循环.
- detour 为 server1 表示国外 DNS 请求自身走代理；
- fakeip 为 FakeIP DNS 机制，会对域名请求返回假的 IP 如198.18.x.x，然后sing-box 内部记住：198.18.x.x -> google.com，后续连接198.18.x.x:443的时候恢复 google.com,这样加快了速度，但会带来缓存污染问题和 dig 等工具无法使用的问题.RealIP 模式则没有该字段.
- strategy 字段为域策略，有``prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only``四种，仅 ipv4 模式使用``ipv4_only``,ipv4+6 模式使用``prefer_ipv4``.
- rule_set: "geosite-cn" 表示中国域名使用本地 DNS.
- query_type 表示 A/AAAA 查询全部返回 FakeIP.
- rewrite_ttl 表示强制 DNS TTL=1 秒,防止系统长期缓存 FakeIP.
- final 为 foreign 表示未匹配规则的域名默认走 foreign 即国外DNS解析.
- independent_cache 表示每个 DNS server 使用独立缓存,否则所有 DNS 共用缓存,共享缓存可能污染分流.
- reverse_mapping 为记录域名 -> IP的映射关系,如果系统自己代理/缓存 DNS，可能有问题.
- FakeIP 最终效果为国内域名->local DNS->国内直连 国外域名->foreign DNS->代理解析 A/AAAA 查询->FakeIP->TUN 接管流量.
- RealIP 最终效果为国内域名->public（国内 DoH）,国外域名->foreign（代理 DoH）,返回真实 IP->reverse_mapping 记录->TUN 捕获连接->恢复域名规则.
