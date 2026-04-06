#!/bin/sh
# auto-optimize.sh - 自动检测并优化配置 (Robust Version for OpenWrt/BusyBox)
# 适用设备: NanoPi R1S H5 (ARMv8, 512MB-1GB RAM)
# 功能: 内核参数优化 + CPU 调度器 + 网络热插拔优化

set -e

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    logger -t "auto-optimize" "$1" 2>/dev/null || true
}

get_mem_mb() {
    local kb
    kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$kb" ] || [ "$kb" -eq 0 ] 2>/dev/null; then
        echo 512  # 默认值，避免除零
    else
        echo $((kb / 1024))
    fi
}

sysctl_set() {
    local key="$1"
    local val="$2"
    local path="/proc/sys/$(echo "$key" | tr '.' '/')"
    if [ -f "$path" ] && [ -w "$path" ]; then
        echo "$val" > "$path" 2>/dev/null && \
            log "  ✓ $key = $val" || \
            log "  ✗ $key 写入失败"
    else
        log "  ⊘ $key 路径不可写"
    fi
}

# ===================== 主逻辑 =====================

TOTAL_MEM=$(get_mem_mb)
log "▶ 启动优化 | 检测到内存: ${TOTAL_MEM}MB"

# --- 内核网络参数 ---
log "▶ 优化网络参数"
sysctl_set "net.core.somaxconn"           "4096"
sysctl_set "net.core.netdev_max_backlog"  "2000"
sysctl_set "net.core.rps_sock_flow_entries" "32768"
sysctl_set "net.ipv4.tcp_fastopen"        "3"
sysctl_set "net.ipv4.tcp_fin_timeout"     "30"
sysctl_set "net.ipv4.tcp_keepalive_time"  "600"
sysctl_set "net.ipv4.tcp_tw_reuse"        "1"
sysctl_set "net.ipv4.ip_local_port_range" "1024 65000"
sysctl_set "net.ipv4.tcp_max_syn_backlog" "8192"
sysctl_set "net.netfilter.nf_conntrack_max" "65536"
sysctl_set "fs.file-max"                  "65535"

# --- 内存策略 ---
if [ "$TOTAL_MEM" -lt 512 ]; then
    log "▶ 模式: 小内存 (<512MB)"
    sysctl_set "vm.swappiness"         "20"
    sysctl_set "vm.vfs_cache_pressure" "200"
    sysctl_set "net.core.rmem_max"     "262144"
    sysctl_set "net.core.wmem_max"     "262144"
elif [ "$TOTAL_MEM" -lt 1024 ]; then
    log "▶ 模式: 中等内存 (512MB-1GB) ← R1S H5 典型配置"
    sysctl_set "vm.swappiness"         "10"
    sysctl_set "vm.vfs_cache_pressure" "150"
    sysctl_set "net.core.rmem_max"     "524288"
    sysctl_set "net.core.wmem_max"     "524288"
else
    log "▶ 模式: 大内存 (≥1GB)"
    sysctl_set "vm.swappiness"         "30"
    sysctl_set "vm.vfs_cache_pressure" "100"
    sysctl_set "net.core.rmem_max"     "1048576"
    sysctl_set "net.core.wmem_max"     "1048576"
fi

# --- CPU 调度器 ---
log "▶ 优化 CPU 调度器"
GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [ -f "$GOV_PATH" ]; then
    AVAIL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
    for gov in schedutil ondemand conservative; do
        if echo "$AVAIL" | grep -qw "$gov"; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo "$gov" > "$cpu" 2>/dev/null || true
            done
            log "  ✓ CPU 调度器: $gov"
            break
        fi
    done
else
    log "  ⊘ cpufreq 接口不可用"
fi

# --- 网络接口热插拔优化 ---
log "▶ 配置网络热插拔优化"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-net-optimize << 'HPEOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ -z "$DEVICE" ] && exit 0

# 提升发送队列长度
ip link set "$DEVICE" txqueuelen 1000 2>/dev/null || true

# 优化网卡缓冲区 (需 ethtool 支持)
if command -v ethtool >/dev/null 2>&1; then
    ethtool -G "$DEVICE" rx 256 tx 256 2>/dev/null || true
fi

logger -t "net-opt" "接口 $DEVICE 已优化"
HPEOF
chmod +x /etc/hotplug.d/iface/99-net-optimize

log "✅ 优化完成! 内存: ${TOTAL_MEM}MB | 时间: $(date '+%H:%M')"
exit 0
