#!/bin/sh
# monitor-memory.sh - 轻量级内存监控 (完全兼容 BusyBox sh)
# 适用: OpenWrt R1S H5

LOG_TAG="MemMonitor"
CHECK_INTERVAL=300    # 检查间隔(秒)，默认 5 分钟
WARN_THRESHOLD=85     # 警告阈值 (%)
CRITICAL_THRESHOLD=95 # 紧急阈值 (%)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t "$LOG_TAG" "$1" 2>/dev/null
}

# 获取内存统计 (kB)，兼容不同内核版本的 /proc/meminfo
get_mem_stats() {
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_FREE=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
    MEM_BUFFERS=$(awk '/^Buffers:/ {print $2}' /proc/meminfo)
    # 优先读 MemAvailable (内核 3.14+)，否则用 Cached 估算
    MEM_AVAILABLE=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$MEM_AVAILABLE" ]; then
        MEM_CACHED=$(awk '/^Cached:/ && !/SwapCached/ {print $2}' /proc/meminfo)
        MEM_AVAILABLE=$((MEM_FREE + MEM_BUFFERS + MEM_CACHED))
    fi
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
    if [ "$MEM_TOTAL" -gt 0 ]; then
        MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    else
        MEM_PERCENT=0
    fi
}

# 查找内存占用最高的 N 个非系统进程 PID (BusyBox 兼容)
# BusyBox ps 输出格式: PID USER VSZ STAT COMMAND
# 注意：BusyBox ps 无 %MEM 列，用 VSZ 做近似排序
get_top_pids() {
    local count="${1:-2}"
    ps 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort -k2 -rn | head -n "$((count + 10))" | \
    while read pid vsz; do
        [ "$pid" -le 100 ] 2>/dev/null && continue
        # 读取进程名
        local cmd
        cmd=$(cat "/proc/$pid/comm" 2>/dev/null)
        [ -z "$cmd" ] && continue
        # 跳过核心系统进程
        case "$cmd" in
            procd|ubusd|logd|netifd|odhcpd|rpcd|dnsmasq|uhttpd|sh|ash) continue ;;
        esac
        echo "$pid $cmd"
        count=$((count - 1))
        [ "$count" -le 0 ] && break
    done
}

# 清理内存缓存
clean_cache() {
    log "清理页面缓存..."
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
    sleep 1
    echo 2 > /proc/sys/vm/drop_caches 2>/dev/null
}

# 主循环
log "内存监控守护进程启动 (阈值: 警告=${WARN_THRESHOLD}% 紧急=${CRITICAL_THRESHOLD}%，间隔=${CHECK_INTERVAL}s)"

while true; do
    get_mem_stats

    MEM_TOTAL_MB=$((MEM_TOTAL / 1024))
    MEM_USED_MB=$((MEM_USED / 1024))
    MEM_AVAILABLE_MB=$((MEM_AVAILABLE / 1024))

    log "内存: 总计=${MEM_TOTAL_MB}MB 已用=${MEM_USED_MB}MB 可用=${MEM_AVAILABLE_MB}MB 使用率=${MEM_PERCENT}%"

    if [ "$MEM_PERCENT" -ge "$CRITICAL_THRESHOLD" ]; then
        log "[紧急] 内存使用率 ${MEM_PERCENT}%，执行强力清理..."
        clean_cache

        # 向占用内存最多的前 2 个非系统进程发送 HUP 信号（请求重载而非杀死）
        get_top_pids 2 | while read pid cmd; do
            log "  发送 HUP 信号: $cmd (PID=$pid)"
            kill -HUP "$pid" 2>/dev/null
        done

        # 重新检查
        sleep 5
        get_mem_stats
        log "清理后内存使用率: ${MEM_PERCENT}%"

    elif [ "$MEM_PERCENT" -ge "$WARN_THRESHOLD" ]; then
        log "[警告] 内存使用率 ${MEM_PERCENT}%，执行缓存清理..."
        clean_cache
    fi

    sleep "$CHECK_INTERVAL"
done
