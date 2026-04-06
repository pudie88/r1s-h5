#!/bin/sh
# monitor-memory.sh - 轻量级内存监控 (BusyBox 兼容)
# 适用: OpenWrt R1S H5
# 功能: 定期检测内存使用，自动清理缓存，防止 OOM

LOG_TAG="MemMonitor"
CHECK_INTERVAL=300      # 检查间隔(秒)
WARN_THRESHOLD=85       # 警告阈值 (%)
CRITICAL_THRESHOLD=95   # 紧急阈值 (%)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t "$LOG_TAG" "$1" 2>/dev/null || true
}

get_mem_stats() {
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_FREE=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
    MEM_BUFFERS=$(awk '/^Buffers:/ {print $2}' /proc/meminfo)
    MEM_AVAILABLE=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    
    if [ -z "$MEM_AVAILABLE" ] || [ "$MEM_AVAILABLE" -eq 0 ] 2>/dev/null; then
        MEM_CACHED=$(awk '/^Cached:/ && !/SwapCached/ {print $2}' /proc/meminfo)
        MEM_AVAILABLE=$((MEM_FREE + MEM_BUFFERS + ${MEM_CACHED:-0}))
    fi
    
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
    MEM_PERCENT=0
    [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null && MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
}

clean_cache() {
    log "  🧹 清理页面缓存..."
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1
    echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

get_top_processes() {
    local count="${1:-3}"
    ps 2>/dev/null | awk 'NR>1 {print $1, $3, $4}' | sort -k2 -rn | head -n "$count" | \
    while read pid vsz stat; do
        [ "$pid" -le 100 ] 2>/dev/null && continue
        cmd=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
        case "$cmd" in
            procd|ubusd|logd|netifd|dnsmasq|uhttpd|rpcd|sh|ash|init) continue ;;
        esac
        echo "  • $cmd (PID:$pid VSZ:${vsz}KB)"
    done
}

# ===================== 主循环 =====================

log "🚀 内存监控启动 | 阈值: 警告=${WARN_THRESHOLD}% 紧急=${CRITICAL_THRESHOLD}%"

while true; do
    get_mem_stats
    
    TOTAL_MB=$((MEM_TOTAL / 1024))
    USED_MB=$((MEM_USED / 1024))
    AVAIL_MB=$((MEM_AVAILABLE / 1024))
    
    log "📊 内存: 总计=${TOTAL_MB}MB 已用=${USED_MB}MB 可用=${AVAIL_MB}MB 使用率=${MEM_PERCENT}%"
    
    if [ "$MEM_PERCENT" -ge "$CRITICAL_THRESHOLD" ]; then
        log "🔴 [紧急] 使用率 ${MEM_PERCENT}%! 执行强力清理..."
        clean_cache
        
        log "  📋 内存占用最高的进程:"
        get_top_processes 3
        
        # 向非关键进程发送 HUP 信号（请求重载）
        ps 2>/dev/null | awk 'NR>1 {print $1, $4}' | sort -k2 -rn | head -n 5 | \
        while read pid cmd; do
            [ "$pid" -le 100 ] 2>/dev/null && continue
            case "$cmd" in procd|ubusd|logd|netifd|dnsmasq|uhttpd|rpcd|init|sh) continue ;; esac
            log "  ↻ 发送 HUP 信号: $cmd (PID=$pid)"
            kill -HUP "$pid" 2>/dev/null || true
        done
        
        sleep 3
        get_mem_stats
        log "  ✅ 清理后使用率: ${MEM_PERCENT}%"
        
    elif [ "$MEM_PERCENT" -ge "$WARN_THRESHOLD" ]; then
        log "🟡 [警告] 使用率 ${MEM_PERCENT}%，执行缓存清理"
        clean_cache
    fi
    
    sleep "$CHECK_INTERVAL"
done
