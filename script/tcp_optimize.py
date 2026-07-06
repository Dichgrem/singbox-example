#!/usr/bin/env python3
"""
TCP 内核参数优化计算引擎
移植自 singbox-example 的 tcp.js + tcp2.js
用法:
  python3 tcp_optimize.py [--local 1000] [--vps 1000] [--latency 100] [--memory 1024]
                          [--ramp 0.79] [--bbr bbr] [--qdisc cake] [--extreme] [--json]
"""

import math
import sys
import json
import argparse

# ─── 数学曲线 ───────────────────────────────────────────────

def linear_curve(x, slope=1, intercept=0):
    return slope * x + intercept

def exponential_curve(x, base=math.e, scale=1):
    return scale * math.pow(base, x - 1)

def logarithmic_curve(x, base=math.e, scale=1):
    return scale * math.log(x * (base - 1) + 1) / math.log(base)

def sigmoid_curve(x, steepness=6, midpoint=0.5):
    return 1 / (1 + math.exp(-steepness * (x - midpoint)))

def piecewise_linear_curve(x, points):
    pts = sorted(points, key=lambda p: p[0])
    n = len(pts)
    if n == 0:
        return 0
    if x <= pts[0][0]:
        return pts[0][1]
    if x >= pts[-1][0]:
        return pts[-1][1]
    for i in range(n - 1):
        x1, y1 = pts[i]
        x2, y2 = pts[i + 1]
        if x1 <= x <= x2:
            t = (x - x1) / (x2 - x1)
            return y1 + t * (y2 - y1)
    return pts[-1][1]

def tcp_congestion_curve(x, mode="slow_start", scale=1):
    if mode == "slow_start":
        return min(scale * (1 + 0.5 * x), scale + 10 * x)
    return scale + 0.1 * x

def queue_theory_curve(x, rate, utilization):
    return (rate / (1 - min(utilization, 0.95))) * x

# ─── 工具函数 ───────────────────────────────────────────────

def bandwidth_delay_product(bandwidth_bps, latency_ms, factor=1):
    return math.ceil((bandwidth_bps * latency_ms * factor) / 1000)

def memory_aware_buffer_size(buffer_bytes, memory_mb, ratio=0.125):
    return min(buffer_bytes, int(1024 * memory_mb * 1024 * ratio))

def clamp_value(value, minimum, maximum, name=""):
    if math.isnan(value) or not math.isfinite(value):
        if name:
            print(f"[warn] {name}: invalid value {value}, using {minimum}", file=sys.stderr)
        return minimum
    if value < minimum:
        if name:
            print(f"[warn] {name}: {value} < {minimum}, clamping", file=sys.stderr)
        return minimum
    if value > maximum:
        if name:
            print(f"[warn] {name}: {value} > {maximum}, clamping", file=sys.stderr)
        return maximum
    return value

def validate_input(value, name="input"):
    return clamp_value(value, 0, 1, name)

def post_process_curve_output(value, minimum, maximum, name="curve"):
    r = clamp_value(value, minimum, maximum, name)
    if r <= 0:
        if name:
            print(f"[warn] {name}: output {r} not positive, using {minimum}", file=sys.stderr)
        return minimum
    return r

# ─── 场景配置 ───────────────────────────────────────────────

def get_gaming_config(memory_mb):
    base = dict(
        responsiveness=2, jitterTolerance=0.3, burstHandling=0.7,
        memoryEfficiency=1, bufferAggression=0.8, queueDepthPreference=0.8,
        connectionDensity=1.2,
        windowScaling=dict(baseMultiplier=1.2, latencySensitivity=1.5, maxScale=4),
        curves=dict(
            bufferCurve=dict(type="sigmoid", steepness=4, midpoint=0.3),
            queueCurve=dict(type="exponential", aggressiveness=0.8, smoothing=0.3),
            latencyCurve=dict(type="exponential", sensitivity=2, threshold=0.2),
        ),
    )
    if memory_mb <= 256:
        base.update(responsiveness=2.5, jitterTolerance=0.2, burstHandling=0.5,
                     memoryEfficiency=0.8, bufferAggression=0.6, queueDepthPreference=0.6,
                     connectionDensity=1)
        base["windowScaling"].update(baseMultiplier=1, maxScale=3)
    elif memory_mb <= 512:
        base.update(responsiveness=2.2, jitterTolerance=0.25, burstHandling=0.6,
                     memoryEfficiency=0.9, bufferAggression=0.7)
    elif memory_mb > 1024:
        base.update(responsiveness=1.8, jitterTolerance=0.4, burstHandling=0.9,
                     memoryEfficiency=1.2, bufferAggression=1, queueDepthPreference=1,
                     connectionDensity=1.5)
        base["windowScaling"].update(baseMultiplier=1.4, maxScale=6)
    return base

def get_filetransfer_config(memory_mb):
    base = dict(
        throughputPriority=2, stabilityFactor=1.5, bufferAggression=2,
        queueDepth=2.5, connectionScaling=2, memoryUtilization=1.5, bufferPooling=1.5,
        windowScaling=dict(baseMultiplier=2, latencyTolerance=2, maxScale=8),
        curves=dict(
            bufferCurve=dict(type="logarithmic", growth=1.5, damping=0.8),
            queueCurve=dict(type="tcp_congestion", scaling=1.8, smoothing=0.5),
            latencyCurve=dict(type="logarithmic", tolerance=1.5, threshold=0.4),
        ),
    )
    if memory_mb <= 512:
        base.update(throughputPriority=1.8, stabilityFactor=1.8, bufferAggression=1.5,
                     queueDepth=2, connectionScaling=1.5, memoryUtilization=1.2, bufferPooling=1.2)
        base["windowScaling"].update(baseMultiplier=1.5, maxScale=6)
    elif memory_mb <= 1024:
        pass
    elif memory_mb <= 2048:
        base.update(throughputPriority=2.2, bufferAggression=2.3, queueDepth=3,
                     connectionScaling=2.5, memoryUtilization=1.8, bufferPooling=1.8)
        base["windowScaling"].update(baseMultiplier=2.5, maxScale=12)
    else:
        base.update(throughputPriority=2.5, bufferAggression=2.5, queueDepth=3.5,
                     connectionScaling=3, memoryUtilization=2, bufferPooling=2)
        base["windowScaling"].update(baseMultiplier=3, maxScale=16)
    return base

# ─── 低延迟核心计算 (≤120ms, 游戏/实时) ────────────────────

def _ll_factors(latency_ms, ramp_up_rate, memory_mb, bandwidth_bps):
    cfg = get_gaming_config(memory_mb)
    ramp = validate_input(ramp_up_rate, "rampUpRate")

    cf1 = post_process_curve_output(
        sigmoid_curve(ramp, cfg["curves"]["bufferCurve"]["steepness"],
                      cfg["curves"]["bufferCurve"]["midpoint"])
        * (cfg["responsiveness"] / 2), 0.3, 2, "cf1_l")

    lf = post_process_curve_output(
        exponential_curve(latency_ms / 120,
                          cfg["curves"]["latencyCurve"]["sensitivity"], 1)
        * cf1 * cfg["responsiveness"], 0.8, 5, "latencyFactor_l")

    bf = post_process_curve_output(
        lf * tcp_congestion_curve(cf1, "slow_start", 1)
        * cfg["memoryEfficiency"] * cfg["bufferAggression"] * cfg["burstHandling"],
        0.5, 3, "bufferFactor_l")

    qf = post_process_curve_output(
        (math.log(
            queue_theory_curve(
                (bandwidth_bps / 65536) * cfg["connectionDensity"],
                (latency_ms / 1000) * 2, 0.8 * cf1) + 1)
         / math.log(1000))
        * cfg["queueDepthPreference"] * (1 + cfg["jitterTolerance"]),
        0.3, 2, "queueFactor_l")

    adv_ws = post_process_curve_output(
        (lf / cfg["windowScaling"]["latencySensitivity"])
        * (max(0, math.ceil(math.log2(
            (2 * bandwidth_delay_product(bandwidth_bps, latency_ms)) / 65535)))
           * cfg["windowScaling"]["baseMultiplier"])
        * cf1, 1, cfg["windowScaling"]["maxScale"], "advWinScaleFactor_l")

    init_cwnd = post_process_curve_output(
        (lf / 2) * (((10 + math.ceil(
            bandwidth_delay_product(bandwidth_bps, latency_ms) / 1460)) / 2) * cf1)
        * cfg["burstHandling"], 2, 20, "initCwndFactor_l")

    return dict(cf1=cf1, lf=lf, bf=bf, qf=qf, adv_ws=adv_ws, init_cwnd=init_cwnd)

# ─── 高延迟核心计算 (>120ms, 文件传输/流媒体) ────────────

def _hl_factors(latency_ms, ramp_up_rate, memory_mb, bandwidth_bps):
    cfg = get_filetransfer_config(memory_mb)
    ramp = validate_input(ramp_up_rate, "rampUpRate")

    cf1 = post_process_curve_output(
        logarithmic_curve(ramp, math.e, cfg["throughputPriority"] / 2)
        * cfg["stabilityFactor"] * (cfg["bufferAggression"] / 2), 0.5, 3, "cf1_h")

    lf_input = min(1, (latency_ms - 120) / 1880)
    lf = post_process_curve_output(
        logarithmic_curve(lf_input, cfg["curves"]["latencyCurve"]["tolerance"], 1)
        * cfg["windowScaling"]["latencyTolerance"] * cf1, 1, 8, "latencyFactor_h")

    bf = post_process_curve_output(
        lf * tcp_congestion_curve(cf1, "congestion_avoidance", 10)
        * cfg["throughputPriority"] * cfg["bufferAggression"] * cfg["memoryUtilization"]
        * piecewise_linear_curve(cf1, [(0, 1), (0.3, 1.5), (0.6, 2.5), (1, 4)]),
        1, 8, "bufferFactor_h")

    qf = post_process_curve_output(
        (lf / 3) * (math.log(
            queue_theory_curve(
                (bandwidth_bps / 131072) * cfg["connectionScaling"],
                (latency_ms / 1000) * 3, min(0.9, 0.85 * cf1)) + 1)
                     / math.log(10000))
        * cfg["queueDepth"], 0.8, 4, "queueFactor_h")

    adv_ws = post_process_curve_output(
        (lf / cfg["windowScaling"]["latencyTolerance"])
        * (max(0, math.ceil(math.log2(
            (4 * bandwidth_delay_product(bandwidth_bps, latency_ms)) / 65535)))
           * cfg["windowScaling"]["baseMultiplier"])
        * linear_curve(cf1, 2, 1), 2, cfg["windowScaling"]["maxScale"], "advWinScaleFactor_h")

    init_cwnd = post_process_curve_output(
        max(min(10, max(2, 10)),
            min(100, math.ceil(
                bandwidth_delay_product(bandwidth_bps, latency_ms) / 1460) / 4))
        * cfg["throughputPriority"] * cf1 * (1 + lf / 8) * cfg["connectionScaling"],
        5, 50, "initCwndFactor_h")

    return dict(cf1=cf1, lf=lf, bf=bf, qf=qf, adv_ws=adv_ws, init_cwnd=init_cwnd)

# ─── 低延迟参数 (latency ≤ 120ms) ────────────────────────

def calc_low_latency(local_mbps, vps_mbps, latency_ms, memory_mb,
                     ramp_up_rate, bbr_version="bbr", qdisc="cake", extreme=False):
    lb = clamp_value(local_mbps, 1, 100000, "localBandwidth")
    vb = clamp_value(vps_mbps, 1, 100000, "vpsBandwidth")
    lat = clamp_value(latency_ms, 1, 2000, "latency")
    mem = clamp_value(memory_mb, 64, 32768, "memorySizeMB")
    ramp = clamp_value(ramp_up_rate, 0.1, 1, "rampUpRate")

    if lb > 10 * vb:
        print("[warn] 本地带宽显著高于服务器带宽，可能导致性能问题", file=sys.stderr)
    if lat > 500 and mem < 512:
        print("[warn] 高延迟场景下内存较小，可能影响性能", file=sys.stderr)

    if lat > 120:
        return calc_high_latency(local_mbps, vps_mbps, latency_ms, memory_mb,
                                 ramp_up_rate, bbr_version, qdisc, extreme)

    bw_ratio = lb / vb
    f_bw = min(2, max(1, 1.5 * math.sqrt(bw_ratio)))
    eff_bw = (1024 * min(lb * f_bw, vb) * 1024) / 8

    mem_factor = 1
    if bw_ratio > 1:
        mem_factor = max(0.3, 1 / math.sqrt(min(bw_ratio, 100)))
        if lat > 200:
            mem_factor = min(1, 1.2 * mem_factor)

    bdp_bytes = math.ceil((eff_bw * lat) / 1000)
    rmem_min = max(bdp_bytes, 24576)

    buf_ratio = 0.1 if mem <= 256 else 0.125
    buf_min = 4194304 if mem <= 256 else 8388608
    buf_max = max(memory_aware_buffer_size(
        math.ceil(1.5 * ramp * mem_factor * bdp_bytes), mem, buf_ratio), buf_min)

    f = _ll_factors(lat, ramp, mem, eff_bw)

    tv = 3
    th = 1.5
    if mem <= 256:
        tv, th = 2.5, 1.2
    elif mem <= 512:
        tv, th = 3, 1.5
    else:
        tv, th = 4, 2

    rmem = [8192, 87380, min(math.floor(bdp_bytes * tv * f["bf"]), buf_max)]
    wmem = [8192, 65536, min(math.floor(bdp_bytes * th * f["bf"]), buf_max)]

    backlog_raw = math.ceil(min(2 * max(100, eff_bw / 65536), 10000) * f["qf"])

    ms = {256: 0.6, 512: 0.8, 1024: 1}.get(mem, 1.2) if mem <= 1024 else 1.2

    somaxconn = clamp_value(math.floor(0.2 * backlog_raw * ms), 256, 2048, "somaxconn")
    netdev_max_backlog = clamp_value(math.floor(0.4 * backlog_raw * ms), 2000, 4000, "netdev_max_backlog")
    tcp_max_syn_backlog = clamp_value(math.floor(0.8 * backlog_raw * ms), 2048, 16384, "tcp_max_syn_backlog")

    params = {
        "kernel.pid_max": 65535, "kernel.panic": 1, "kernel.sysrq": 1,
        "kernel.core_pattern": "core_%e", "kernel.printk": "3 4 1 3",
        "kernel.numa_balancing": 0, "kernel.sched_autogroup_enabled": 0,
        "vm.swappiness": 10, "vm.dirty_ratio": 10, "vm.dirty_background_ratio": 5,
        "vm.panic_on_oom": 0, "vm.overcommit_memory": 1,
        "vm.min_free_kbytes": _min_free_low(mem, eff_bw),
        "vm.vfs_cache_pressure": 100, "vm.dirty_expire_centisecs": 3000,
        "vm.dirty_writeback_centisecs": 500,
        "net.core.default_qdisc": qdisc,
        "net.core.netdev_max_backlog": int(netdev_max_backlog),
        "net.core.rmem_max": int(buf_max), "net.core.wmem_max": int(buf_max),
        "net.core.rmem_default": rmem[1], "net.core.wmem_default": wmem[1],
        "net.core.somaxconn": int(somaxconn),
        "net.core.optmem_max": int(min(65536, bdp_bytes / 4)),
        "net.ipv4.tcp_fastopen": 3, "net.ipv4.tcp_timestamps": 1,
        "net.ipv4.tcp_tw_reuse": 1, "net.ipv4.tcp_fin_timeout": 10,
        "net.ipv4.tcp_slow_start_after_idle": 0, "net.ipv4.tcp_max_tw_buckets": 32768,
        "net.ipv4.tcp_sack": 1, "net.ipv4.tcp_fack": 0,
        "net.ipv4.tcp_rmem": " ".join(map(str, rmem)),
        "net.ipv4.tcp_wmem": " ".join(map(str, wmem)),
        "net.ipv4.tcp_mtu_probing": 1,
        "net.ipv4.tcp_congestion_control": bbr_version,
        "net.ipv4.tcp_notsent_lowat": 4096,
        "net.ipv4.tcp_window_scaling": 1,
        "net.ipv4.tcp_adv_win_scale": int(max(2, math.ceil(f["adv_ws"]))),
        "net.ipv4.tcp_moderate_rcvbuf": 1, "net.ipv4.tcp_no_metrics_save": 0,
        "net.ipv4.tcp_max_syn_backlog": int(tcp_max_syn_backlog),
        "net.ipv4.tcp_max_orphans": 65536,
        "net.ipv4.tcp_synack_retries": 2, "net.ipv4.tcp_syn_retries": 3,
        "net.ipv4.tcp_abort_on_overflow": 0, "net.ipv4.tcp_stdurg": 0,
        "net.ipv4.tcp_rfc1337": 0, "net.ipv4.tcp_syncookies": 1,
        "net.ipv4.ip_forward": 0, "net.ipv4.ip_local_port_range": "1024 65535",
        "net.ipv4.ip_no_pmtu_disc": 0, "net.ipv4.route.gc_timeout": 100,
        "net.ipv4.neigh.default.gc_stale_time": 120,
        "net.ipv4.neigh.default.gc_thresh3": 8192,
        "net.ipv4.neigh.default.gc_thresh2": 4096,
        "net.ipv4.neigh.default.gc_thresh1": 1024,
        "net.ipv4.conf.all.accept_redirects": 0,
        "net.ipv4.conf.default.accept_redirects": 0,
        "net.ipv4.conf.all.secure_redirects": 0,
        "net.ipv4.conf.default.secure_redirects": 0,
        "net.ipv4.conf.all.accept_source_route": 0,
        "net.ipv4.conf.default.accept_source_route": 0,
        "net.ipv4.conf.all.forwarding": 0, "net.ipv4.conf.default.forwarding": 0,
        "net.ipv4.icmp_echo_ignore_broadcasts": 1,
        "net.ipv4.icmp_ignore_bogus_error_responses": 1,
        "net.ipv4.conf.all.rp_filter": 1, "net.ipv4.conf.default.rp_filter": 1,
        "net.ipv4.conf.all.arp_announce": 2, "net.ipv4.conf.default.arp_announce": 2,
        "net.ipv4.conf.all.arp_ignore": 1, "net.ipv4.conf.default.arp_ignore": 1,
    }

    if extreme:
        if mem < 512:
            print("[warn] 内存不足512MB，激进模式可能影响系统稳定性", file=sys.stderr)
        x = max(min(((eff_bw * lat) / 1000) * min(8, 4 + mem / 2048),
                    1024 * mem * 122.88), 2097152)
        k = min(eff_bw / 1048576, 10000)
        s_e = min(4 * mem, 16384)
        bl_e = min(s_e, 4000 + k)
        sb_e = min(s_e / 2, 2048 + k / 2)
        params.update({
            "net.core.rmem_max": int(2 * x), "net.core.wmem_max": int(x),
            "net.core.rmem_default": 262144, "net.core.wmem_default": 262144,
            "net.ipv4.tcp_rmem": f"32768 262144 {int(2 * x)}",
            "net.ipv4.tcp_wmem": f"32768 262144 {int(x)}",
            "net.core.netdev_max_backlog": int(bl_e),
            "net.core.somaxconn": 16384,
            "net.ipv4.tcp_max_syn_backlog": int(sb_e),
            "net.ipv4.tcp_slow_start_after_idle": 0,
            "net.ipv4.tcp_mtu_probing": 2, "net.ipv4.tcp_timestamps": 0,
            "net.ipv4.tcp_window_scaling": 1, "net.ipv4.tcp_sack": 1,
            "net.ipv4.tcp_fack": 1, "net.ipv4.tcp_notsent_lowat": 16384,
            "net.core.default_qdisc": "fq",
            "net.core.busy_read": 50, "net.core.busy_poll": 50,
            "kernel.sched_min_granularity_ns": 3000000,
            "vm.min_free_kbytes": int(max(131072, 32 * mem)),
            "vm.swappiness": 1,
            "net.ipv4.tcp_mem": f"{int(384 * mem)} {int(512 * mem)} {int(768 * mem)}",
            "net.ipv4.tcp_keepalive_time": 600,
            "net.ipv4.tcp_keepalive_intvl": 30,
            "net.ipv4.tcp_keepalive_probes": 3,
            "net.ipv4.tcp_fin_timeout": 15,
            "net.ipv4.tcp_moderate_rcvbuf": 0,
            "net.core.optmem_max": int(min(81920, 80 * mem))},
        )
    return params

# ─── 高延迟参数 (latency > 120ms) ────────────────────────

def calc_high_latency(local_mbps, vps_mbps, latency_ms, memory_mb,
                      ramp_up_rate, bbr_version="bbr", qdisc="fq", extreme=False):
    lb = clamp_value(local_mbps, 1, 100000, "localBandwidth")
    vb = clamp_value(vps_mbps, 1, 100000, "vpsBandwidth")
    lat = clamp_value(latency_ms, 120, 2000, "latency")
    mem = clamp_value(memory_mb, 256, 32768, "memorySizeMB")
    ramp = clamp_value(ramp_up_rate, 0.1, 1, "rampUpRate")

    if lat > 1000 and mem < 1024:
        print("[warn] 极高延迟场景下内存较小，强烈建议增加内存", file=sys.stderr)
    if lb > 5 * vb:
        print("[warn] 高延迟场景下本地带宽过高，可能导致缓冲区膨胀", file=sys.stderr)
    if ramp < 0.3:
        print("[warn] 高延迟场景下建议使用较高的rampUpRate值以获得更好的吞吐量", file=sys.stderr)

    f_rtt = min(5, max(1, lat / 40))
    f_bw_ratio = min(5, max(1.5, 2 * math.sqrt(lb / vb) * f_rtt))
    eff_bw = math.floor((1024 * min(lb * f_bw_ratio, 2 * vb) * 1024) / 8)

    bw_ratio = lb / vb
    mem_factor = {100: 0.06, 50: 0.12, 20: 0.2, 10: 0.3, 5: 0.5, 2: 0.7}.get(
        next((b for b in [100, 50, 20, 10, 5, 2] if bw_ratio > b), None), 1)

    f = _hl_factors(lat, ramp, mem, eff_bw)

    bdp_bytes = math.ceil((eff_bw * lat) / 1000)
    rmem_min = max(bdp_bytes, 262144)
    rmem_low = max(rmem_min, math.floor((eff_bw * lat) / 800))

    if mem <= 512:
        rmem_min = max(bdp_bytes, 131072)
        rmem_low = max(rmem_min, math.floor((eff_bw * lat) / 1200))
    elif mem <= 1024:
        rmem_min = max(bdp_bytes, 262144)
        rmem_low = max(rmem_min, math.floor((eff_bw * lat) / 1000))
    else:
        rmem_min = max(bdp_bytes, 524288)
        rmem_low = max(rmem_min, math.floor((eff_bw * lat) / 800))

    wmem_max = memory_aware_buffer_size(
        math.ceil(2 * ramp * mem_factor * bdp_bytes), mem, 0.125)
    if lat > 500:
        wmem_max = max(wmem_max, math.ceil(0.5 * bdp_bytes))

    tk = min(8, max(4, 1.8 * f_rtt)) * f["bf"]
    th = min(10, max(5, 2 * f_rtt))
    if mem <= 512:
        tk = min(6, max(3, 1.5 * f_rtt)) * f["bf"]
        th = min(6, max(3, 1.5 * f_rtt))
    elif mem <= 1024:
        tk = min(8, max(4, 1.8 * f_rtt)) * f["bf"]
        th = min(8, max(4, 1.8 * f_rtt))
    else:
        tk = min(10, max(5, 2 * f_rtt)) * f["bf"]
        th = min(10, max(5, 2 * f_rtt))

    rmem = [32768, 262144, min(math.floor(rmem_low * th), wmem_max)]
    wmem = [32768, 262144, min(math.floor(rmem_low * tk), wmem_max)]

    backlog_raw = math.ceil(min(3 * max(50, eff_bw / 131072), 20000) * f["qf"])

    ms = {256: 0.8, 512: 1, 1024: 1, 2048: 1.3}.get(mem, 1.5) if mem <= 2048 else 1.5

    somaxconn = clamp_value(math.floor(0.15 * backlog_raw * ms), 2560,
                            8192 if mem <= 512 else 16384, "somaxconn")
    netdev_max_backlog = clamp_value(math.floor(0.3 * backlog_raw * ms), 8192,
                                     16384 if mem <= 512 else 32768, "netdev_max_backlog")
    tcp_max_syn_backlog = clamp_value(math.floor(0.6 * backlog_raw * ms), 8192,
                                      32768 if mem <= 512 else 65536, "tcp_max_syn_backlog")

    params = {
        "kernel.pid_max": 65535, "kernel.panic": 1, "kernel.sysrq": 1,
        "kernel.core_pattern": "core_%e", "kernel.printk": "3 4 1 3",
        "kernel.numa_balancing": 0, "kernel.sched_autogroup_enabled": 0,
        "vm.swappiness": 5, "vm.dirty_ratio": 5, "vm.dirty_background_ratio": 2,
        "vm.panic_on_oom": 0, "vm.overcommit_memory": 1,
        "vm.min_free_kbytes": _min_free_high(mem, eff_bw),
        "vm.vfs_cache_pressure": 100, "vm.dirty_expire_centisecs": 3000,
        "vm.dirty_writeback_centisecs": 500,
        "net.core.default_qdisc": qdisc,
        "net.core.netdev_max_backlog": int(netdev_max_backlog),
        "net.core.rmem_max": int(wmem_max), "net.core.wmem_max": int(wmem_max),
        "net.core.rmem_default": rmem[1], "net.core.wmem_default": wmem[1],
        "net.core.somaxconn": int(somaxconn),
        "net.core.optmem_max": int(min(262144, rmem_low / 2)),
        "net.ipv4.tcp_fastopen": 3, "net.ipv4.tcp_timestamps": 1,
        "net.ipv4.tcp_tw_reuse": 1, "net.ipv4.tcp_fin_timeout": 10,
        "net.ipv4.tcp_slow_start_after_idle": 0, "net.ipv4.tcp_max_tw_buckets": 32768,
        "net.ipv4.tcp_sack": 1, "net.ipv4.tcp_fack": 1,
        "net.ipv4.tcp_rmem": " ".join(map(str, rmem)),
        "net.ipv4.tcp_wmem": " ".join(map(str, wmem)),
        "net.ipv4.tcp_mtu_probing": 1,
        "net.ipv4.tcp_congestion_control": bbr_version,
        "net.ipv4.tcp_notsent_lowat": int(min(rmem_low / 2, 524288)),
        "net.ipv4.tcp_window_scaling": 1,
        "net.ipv4.tcp_adv_win_scale": int(max(2, math.ceil(f_rtt * f["adv_ws"]))),
        "net.ipv4.tcp_moderate_rcvbuf": 1, "net.ipv4.tcp_no_metrics_save": 1,
        "net.ipv4.tcp_max_syn_backlog": int(tcp_max_syn_backlog),
        "net.ipv4.tcp_max_orphans": 16384 if mem <= 256 else 32768,
        "net.ipv4.tcp_synack_retries": 2, "net.ipv4.tcp_syn_retries": 2,
        "net.ipv4.tcp_abort_on_overflow": 0, "net.ipv4.tcp_stdurg": 0,
        "net.ipv4.tcp_rfc1337": 0, "net.ipv4.tcp_syncookies": 1,
        "net.ipv4.ip_forward": 0, "net.ipv4.ip_local_port_range": "1024 65535",
        "net.ipv4.ip_no_pmtu_disc": 0, "net.ipv4.route.gc_timeout": 100,
        "net.ipv4.neigh.default.gc_stale_time": 120,
        "net.ipv4.neigh.default.gc_thresh3": 2048 if mem <= 512 else 4096,
        "net.ipv4.neigh.default.gc_thresh2": 1024 if mem <= 512 else 2048,
        "net.ipv4.neigh.default.gc_thresh1": 256 if mem <= 512 else 512,
        "net.ipv4.conf.all.accept_redirects": 0,
        "net.ipv4.conf.default.accept_redirects": 0,
        "net.ipv4.conf.all.secure_redirects": 0,
        "net.ipv4.conf.default.secure_redirects": 0,
        "net.ipv4.conf.all.accept_source_route": 0,
        "net.ipv4.conf.default.accept_source_route": 0,
        "net.ipv4.conf.all.forwarding": 0, "net.ipv4.conf.default.forwarding": 0,
        "net.ipv4.icmp_echo_ignore_broadcasts": 1,
        "net.ipv4.icmp_ignore_bogus_error_responses": 1,
        "net.ipv4.conf.all.rp_filter": 1, "net.ipv4.conf.default.rp_filter": 1,
        "net.ipv4.conf.all.arp_announce": 2, "net.ipv4.conf.default.arp_announce": 2,
        "net.ipv4.conf.all.arp_ignore": 1, "net.ipv4.conf.default.arp_ignore": 1,
    }

    if extreme:
        if mem < 512:
            print("[warn] 高延迟场景下内存不足512MB，激进模式可能影响系统稳定性", file=sys.stderr)
        x = max(min(((eff_bw * lat) / 1000) * min(12, 6 + mem / 1024),
                    1024 * mem * 153.6), 4194304)
        k = min(lat / 100, 5)
        q = min(eff_bw / 1048576, 15000)
        s_e = min(6 * mem, 24576)
        bl_e = min(s_e, 6000 + q * k)
        sb_e = min(s_e / 2, 3000 + (q * k) / 2)
        params.update({
            "net.core.rmem_max": int(2 * x), "net.core.wmem_max": int(x),
            "net.core.rmem_default": 524288, "net.core.wmem_default": 524288,
            "net.ipv4.tcp_rmem": f"65536 524288 {int(2 * x)}",
            "net.ipv4.tcp_wmem": f"65536 524288 {int(x)}",
            "net.core.netdev_max_backlog": int(bl_e),
            "net.core.somaxconn": 32768,
            "net.ipv4.tcp_max_syn_backlog": int(sb_e),
            "net.ipv4.tcp_slow_start_after_idle": 0,
            "net.ipv4.tcp_mtu_probing": 2, "net.ipv4.tcp_window_scaling": 1,
            "net.ipv4.tcp_sack": 1, "net.ipv4.tcp_fack": 1,
            "net.ipv4.tcp_notsent_lowat": 32768,
            "net.core.default_qdisc": "fq", "net.ipv4.tcp_timestamps": 1,
            "vm.min_free_kbytes": int(max(262144, 64 * mem)),
            "vm.swappiness": 1,
            "net.ipv4.tcp_mem": f"{int(512 * mem)} {int(768 * mem)} {int(1024 * mem)}",
            "net.ipv4.tcp_keepalive_time": 1200,
            "net.ipv4.tcp_keepalive_intvl": 60,
            "net.ipv4.tcp_fin_timeout": 30,
            "net.core.busy_read": 0, "net.core.busy_poll": 0,
            "net.core.optmem_max": int(min(163840, 160 * mem))},
        )
    return params

# ─── vm.min_free_kbytes ────────────────────────────────────

def _min_free_low(mem, eff_bw):
    mr = 0.015 if mem <= 256 else 0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03
    return clamp_value(math.floor(1024 * mem * mr) + math.floor(0.5 * math.ceil(eff_bw / 1024)),
                       32768, 1048576, "min_free_kbytes")

def _min_free_high(mem, eff_bw):
    mr = 0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03 if mem <= 2048 else 0.035
    return clamp_value(math.floor(1024 * mem * mr) + math.floor(0.6 * math.ceil(eff_bw / 1024)),
                       65536, 1048576, "min_free_kbytes")

# ─── 主入口 ────────────────────────────────────────────────

def format_sysctl(params):
    lines = [
        "# ═══════════════════════════════════════════════════",
        "# TCP 优化配置 — 由 tcp_optimize.py 生成",
        "# ═══════════════════════════════════════════════════\n",
    ]
    for k, v in params.items():
        lines.append(f"{k} = {v}")
    return "\n".join(lines)

def apply_sysctl(params):
    import os, shutil, subprocess, time
    src = "/etc/sysctl.conf"
    bk = f"{src}.bk_{time.strftime('%Y%m%d_%H%M%S')}"
    if os.path.exists(src):
        shutil.copy2(src, bk)
        print(f"[backup] {src} → {bk}", file=sys.stderr)
    lines = [
        "# ═══════════════════════════════════════════════════",
        "# TCP 优化配置 — 由 tcp_optimize.py 生成",
        "# ═══════════════════════════════════════════════════\n",
    ]
    for k, v in params.items():
        lines.append(f"{k} = {v}")
    with open(src, "w") as f:
        f.write("\n".join(lines) + "\n")
    r = subprocess.run(["sysctl", "-p"], capture_output=True, text=True)
    if r.returncode == 0:
        print("[ok] 配置已生效", file=sys.stderr)
    else:
        print(f"[warn] sysctl -p 部分失败:\n{r.stderr}", file=sys.stderr)

def main():
    ap = argparse.ArgumentParser(description="TCP 内核参数优化")
    ap.add_argument("--local", type=float, help="本地带宽 (Mbps)")
    ap.add_argument("--vps", type=float, help="服务器带宽 (Mbps)")
    ap.add_argument("--latency", type=float, help="网络延迟 (ms)")
    ap.add_argument("--memory", type=float, help="内存大小 (MB)")
    ap.add_argument("--ramp", type=float, default=0.79, help="爬升速率 0-1")
    ap.add_argument("--bbr", default="bbr", choices=["bbr", "bbr3"], help="BBR 版本")
    ap.add_argument("--qdisc", default="cake", choices=["cake", "fq", "fq_codel"], help="队列算法")
    ap.add_argument("--extreme", action="store_true", help="激进模式")
    ap.add_argument("--json", action="store_true", help="JSON 输出")
    ap.add_argument("--apply", action="store_true", help="非交互模式 + 直接写入")
    args = ap.parse_args()

    interactive = any(x is None for x in (args.local, args.vps, args.latency, args.memory))

    if interactive:
        print("TCP 内核参数优化\n" + "=" * 50)
        try:
            if args.local is None:
                args.local = float(input("本地带宽 (Mbps) [1000]: ") or "1000")
            if args.vps is None:
                args.vps = float(input("服务器带宽 (Mbps) [1000]: ") or "1000")
            if args.latency is None:
                args.latency = float(input("网络延迟 (ms) [100]: ") or "100")
            if args.memory is None:
                mem_def = 1024
                try:
                    for line in open("/proc/meminfo"):
                        if line.startswith("MemTotal:"):
                            mem_def = int(line.split()[1]) // 1024
                            break
                except OSError:
                    pass
                inp = input(f"内存大小 (MB) [{mem_def}]: ") or str(mem_def)
                args.memory = float(inp)
            inp = input(f"爬升速率 0-1 [{args.ramp}]: ") or str(args.ramp)
            args.ramp = float(inp)
            if input("激进模式? (y/N): ").lower().startswith("y"):
                args.extreme = True
            inp = input(f"BBR 版本 ({args.bbr}) [bbr/bbr3]: ") or args.bbr
            if inp in ("bbr", "bbr3"):
                args.bbr = inp
            inp = input(f"队列算法 ({args.qdisc}) [cake/fq/fq_codel]: ") or args.qdisc
            if inp in ("cake", "fq", "fq_codel"):
                args.qdisc = inp
        except (EOFError, KeyboardInterrupt):
            print("\n已取消")
            sys.exit(1)

    if args.latency > 120:
        params = calc_high_latency(args.local, args.vps, args.latency, args.memory,
                                   args.ramp, args.bbr, args.qdisc, args.extreme)
        scenario = "高延迟 (文件传输/流媒体)"
    else:
        params = calc_low_latency(args.local, args.vps, args.latency, args.memory,
                                  args.ramp, args.bbr, args.qdisc, args.extreme)
        scenario = "低延迟 (游戏/实时)"

    if args.json:
        print(json.dumps({"scenario": scenario, "params": params}, indent=2))
    else:
        print(f"\n# 场景: {scenario}")
        print(format_sysctl(params))

    if args.apply:
        apply_sysctl(params)
    elif interactive:
        try:
            inp = input("\n应用以上配置到 /etc/sysctl.conf 并生效? (y/N): ")
            if inp.lower().startswith("y"):
                apply_sysctl(params)
        except (EOFError, KeyboardInterrupt):
            print()

if __name__ == "__main__":
    main()
