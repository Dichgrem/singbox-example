```json
{
  "outbounds": [
    {
      "tag": "Server1",
      "type": "vless",
      "server": "xxx.xxx.xxx.xxx",
      "server_port": 8443,
      "uuid": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "xxxxxxxxxxxx",
        "insecure": false,
        "reality": {
          "enabled": true,
          "public_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
          "short_id": "xxxxxxxxxxxx"
        },
        "utls": {
          "enabled": true,
          "fingerprint": "firefox"
        }
      },
      "flow": "xtls-rprx-vision"
    },
    {
      "tag": "Server2",
      "type": "vless",
      "server": "xxx.xxx.xxx.xxx",
      "server_port": 8443,
      "uuid": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "xxxxxxxxxxxx",
        "insecure": false,
        "reality": {
          "enabled": true,
          "public_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
          "short_id": "xxxxxxxxxxxx"
        },
        "utls": {
          "enabled": true
        }
      },
      "flow": "xtls-rprx-vision"
    },
    {
    //   "tag": "AUTO",
    //   "type": "urltest",
    //   "outbounds": ["Server1", "Server2"],
    //   "url": "https://cp.cloudflare.com",
    //   "interval": "5m",
    //   "tolerance": 100
    // },
    {
      "tag": "GLOBAL",
      "type": "selector",
      "outbounds": ["AUTO", "Server1", "Server2", "direct"]
    },
    {
      "tag": "direct",
      "type": "direct"
    }
  ]
}
```

## 说明

- 这里存储各个节点,支持``Shadowsocks VMess Trojan Wireguard Hysteria VLESS ShadowTLS TUIC Hysteria2 AnyTLS Tor SSH NaiveProxy`` 等协议.
- selector 字段只能由 Clash API 控制，用来切换节点；切换的时候现有链接会中断. 
- urltest 字段用来自动测速并自动选择延迟最低的节点，这里表述为 AUTO. 字段，默认不开启，因为面板有自带的测速，而且切换节点是有开销的，默认手动切换.
- AUTO 字段中 interval 为测速间隔，tolerance 为切换容差，只有新节点比当前节点快超过该值时才切换.
- 测速链接一般使用``https://www.gstatic.com/generate_204``或者``https://cp.cloudflare.com``.
