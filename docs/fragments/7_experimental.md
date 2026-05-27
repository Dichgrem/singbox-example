```json
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/etc/momo/run/cache.db",
      "store_fakeip": true
    },
    "clash_api": {
      "external_controller": "0.0.0.0:9095",
      "external_ui": "/etc/momo/run/ui",
      "external_ui_download_url": "https://codeload.github.com/Zephyruso/zashboard/zip/refs/heads/gh-pages",
      "external_ui_download_detour": "direct",
      "secret": "",
      "default_mode": "rule"
    }
  }
}
```

## 说明

- store_fakeip 字段在 realip 模式下不开启.
- cache_file 的 path 字段 在 momo (openwrt) 上为``/etc/momo/run/cache.db`` ，在box(android_root)上为``/data/adb/box/sing-box/cache.db`` ，在 kernel(linux_裸核)上为``/var/lib/sing-box/cache.db``.
- Clash api 可以链接到外部的 Clash UI 面板，便于切换节点和查看路由状态.
- external_ui 字段在不同端上有所不同，一般来说在 momo (openwrt) 上为``/etc/momo/run/ui``,在 box(android_root) 上为``/data/adb/box/sing-box/ui``, 在 kernel(linux_裸核) 上为``/var/lib/sing-box/ui``.
- external_ui_download_url 对应的 Clash UI 面板的下载来源，一般来说有:

```
Zashboard : https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip
Zashboard : https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip
MetaCubeXD : https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip
YACD : https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip
Razord : https://github.com/MetaCubeX/Razord-meta/archive/refs/heads/gh-pages.zip
```

这里默认使用 Zashboard.
- default_mode 字段模拟 Clash 的运行模式（Rule / Global / Direct），默认为 rule 模式，表示按照我们设置的分流规则走；另有 global 表示全部走代理，direct 表示全部走直连.
