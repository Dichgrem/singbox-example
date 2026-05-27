```json
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m",
    "detour": "DIRECT"
  }
}
```

## 说明

- sing-box 内置的 ntp 服务，可以为协议提供时间校准，这在有些场景下很有用.
- interval 字段为同步间隔，默认为 30 分钟.
- 常用的 ntp 服务器有：

| 分类         | NTP 地址                 | 特点                 | 适合场景        |
| ---------- | ---------------------- | ------------------ | ----------- |
| Cloudflare | `time.cloudflare.com`  | Anycast、低延迟、支持 NTS | 通用        |
| Google     | `time.google.com`      | Google Leap Smear  | Google 生态   |
| Google     | `time1.google.com`     | Google 官方节点        | 通用          |
| Google     | `time2.google.com`     | Google 官方节点        | 通用          |
| Google     | `time3.google.com`     | Google 官方节点        | 通用          |
| Google     | `time4.google.com`     | Google 官方节点        | 通用          |
| Android    | `time.android.com`     | Android 常用         | 安卓相关        |
| Apple      | `time.apple.com`       | Apple 官方           | Apple 生态    |
| Apple      | `time-macos.apple.com` | macOS 专用           | macOS       |
| Apple      | `time-ios.apple.com`   | iOS 专用             | iPhone/iPad |
| Apple      | `time.asia.apple.com`  | 亚洲区域节点             | 亚洲地区        |
| Apple      | `time.euro.apple.com`  | 欧洲区域节点             | 欧洲地区        |
| Microsoft  | `time.windows.com`     | Windows 默认         | Windows     |
| NTP Pool   | `pool.ntp.org`         | 全球自动分配             | 通用推荐        |
| NTP Pool   | `0.pool.ntp.org`       | Pool 节点            | 通用          |
| NTP Pool   | `1.pool.ntp.org`       | Pool 节点            | 通用          |
| NTP Pool   | `2.pool.ntp.org`       | IPv4/IPv6 较友好      | 推荐          |
| NTP Pool   | `3.pool.ntp.org`       | Pool 节点            | 通用          |
| 亚洲 Pool    | `asia.pool.ntp.org`    | 亚洲区域池              | 亚洲用户        |
| 日本 Pool    | `jp.pool.ntp.org`      | 日本区域池              | 日本用户        |
| 中国 Pool    | `cn.pool.ntp.org`      | 中国区域池              | 中国大陆        |
| 中国授时       | `cn.ntp.org.cn`        | 国内公共 NTP           | 中国大陆        |
| 阿里云        | `ntp.aliyun.com`       | 国内稳定               | 中国大陆        |
| 阿里云        | `ntp1.aliyun.com`      | 阿里云节点              | 中国大陆        |
| 阿里云        | `ntp2.aliyun.com`      | 阿里云节点              | 中国大陆        |
| 阿里云        | `ntp3.aliyun.com`      | 阿里云节点              | 中国大陆        |
| 阿里云        | `ntp4.aliyun.com`      | 阿里云节点              | 中国大陆        |
| 阿里云        | `ntp5.aliyun.com`      | 阿里云节点              | 中国大陆        |
| 腾讯云        | `ntp.tencent.com`      | 国内稳定               | 中国大陆        |
| 腾讯云        | `ntp1.tencent.com`     | 腾讯云节点              | 中国大陆        |
| 腾讯云        | `ntp2.tencent.com`     | 腾讯云节点              | 中国大陆        |
| 腾讯云        | `ntp3.tencent.com`     | 腾讯云节点              | 中国大陆        |
| 国家授时中心     | `ntp.ntsc.ac.cn`       | 官方授时               | 高准确性        |
| 中国计量院      | `ntp1.nim.ac.cn`       | 国家计量机构             | 高准确性        |
| 中国计量院      | `ntp2.nim.ac.cn`       | 国家计量机构             | 高准确性        |
