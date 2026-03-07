#!/bin/sh
# auto-optimize.sh - 自动检测并优化配置 (Robust Version for OpenWrt/BusyBox)
# 适用设备: R1S H5 (ARMv8, 512MB-1GB RAM)

# ===================== 工具函数 =====================

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    logger -t "auto-optimize" "$1" 2>/dev/null
}

get_mem_mb() {
    local kb
    kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$kb" ] || [ "$kb" -eq 0 ] 2>/dev/null; then
        echo 0
    else
        echo $((kb / 1024))
    fi
}

sysctl_set() {
    local key="$1"
    local val="$2"
    local path="/proc/sys/$(echo "$key" | tr '.' '/')"
    if [ -f "$path" ]; then
        echo "$val" > "$path" 2>/dev/null && log "  sysctl $key = $val" || log "  [跳过] $key 写入失败"
    else
        log "  [跳过] $key 路径不存在"
    fi
}

# ===================== 内存检测 =====================

TOTAL_MEM=$(get_mem_mb)
log "检测到内存: ${TOTAL_MEM}MB"

if [ -z "$TOTAL_MEM" ] || [ "$TOTAL_MEM" -eq 0 ] 2>/dev/null; then
    log "错误：无法检测内存大小，退出"
    exit 1
fi

# ===================== 内核参数优化 =====================

log "--- 开始内核参数优化 ---"

sysctl_set "net.core.somaxconn"           "4096"
sysctl_set "net.core.netdev_max_backlog"  "2000"
sysctl_set "net.ipv4.tcp_fastopen"        "3"
sysctl_set "net.ipv4.tcp_fin_timeout"     "30"
sysctl_set "net.ipv4.tcp_keepalive_time"  "600"
sysctl_set "net.ipv4.tcp_tw_reuse"        "1"
sysctl_set "net.ipv4.ip_local_port_range" "1024 65000"
sysctl_set "fs.file-max"                  "65535"

if [ "$TOTAL_MEM" -lt 512 ]; then
    log "模式：小内存设备 (<512MB)"
    sysctl_set "vm.swappiness"         "20"
    sysctl_set "vm.vfs_cache_pressure" "200"
    sysctl_set "net.core.rmem_max"     "262144"
    sysctl_set "net.core.wmem_max"     "262144"
    if [ -f /etc/init.d/dockerd ]; then
        log "  禁用 Docker 以节省内存"
        /etc/init.d/dockerd disable 2>/dev/null
        /etc/init.d/dockerd stop    2>/dev/null
    fi

elif [ "$TOTAL_MEM" -lt 1024 ]; then
    log "模式：中等内存设备 (512MB-1GB)"
    sysctl_set "vm.swappiness"         "10"
    sysctl_set "vm.vfs_cache_pressure" "150"
    sysctl_set "net.core.rmem_max"     "524288"
    sysctl_set "net.core.wmem_max"     "524288"
    if [ -d /etc/docker ]; then
        DOCKER_CFG="/etc/docker/daemon.json"
        if [ -f "$DOCKER_CFG" ]; then
            if grep -q '"max-size"' "$DOCKER_CFG" 2>/dev/null; then
                sed -i 's/"max-size": *"[^"]*"/"max-size": "5m"/g' "$DOCKER_CFG"
            else
                echo '{"log-driver":"json-file","log-opts":{"max-size":"5m","max-file":"2"}}' > "$DOCKER_CFG"
            fi
            log "  Docker 日志大小已限制为 5m"
        fi
    fi

else
    log "模式：大内存设备 (>=1GB)"
    sysctl_set "vm.swappiness"         "30"
    sysctl_set "vm.vfs_cache_pressure" "100"
    sysctl_set "net.core.rmem_max"     "1048576"
    sysctl_set "net.core.wmem_max"     "1048576"
fi

# ===================== CPU 调度器优化 =====================

log "--- CPU 调度器优化 ---"

GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
AVAIL_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"

if [ -f "$GOV_PATH" ]; then
    AVAIL=""
    [ -f "$AVAIL_GOV_PATH" ] && AVAIL=$(cat "$AVAIL_GOV_PATH")
    CHOSEN=""
    for gov in schedutil ondemand conservative; do
        if echo "$AVAIL" | grep -qw "$gov"; then
            CHOSEN="$gov"
            break
        fi
    done
    if [ -z "$CHOSEN" ]; then
        CHOSEN="performance"
        log "  [警告] 建议确认散热良好后使用 performance 模式"
    fi
    for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$CHOSEN" > "$cpu_gov" 2>/dev/null
    done
    log "  CPU 调度器已设置为: $CHOSEN"
else
    log "  [跳过] cpufreq 接口不存在"
fi

# ===================== 网络接口热插拔优化 =====================

log "--- 配置网络热插拔优化脚本 ---"

mkdir -p /etc/hotplug.d/iface

cat > /etc/hotplug.d/iface/99-net-optimize << 'HOTPLUG_EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
INTERFACE="$DEVICE"
[ -z "$INTERFACE" ] && exit 0
ip link set "$INTERFACE" txqueuelen 1000 2>/dev/null
if command -v ethtool > /dev/null 2>&1; then
    ethtool -G "$INTERFACE" rx 256 tx 256 2>/dev/null
fi
logger -t "net-optimize" "接口 $INTERFACE 已优化 (txqueuelen=1000)"
HOTPLUG_EOF

chmod +x /etc/hotplug.d/iface/99-net-optimize
log "  热插拔脚本已写入"
log "✅ 基础优化完成！当前内存: ${TOTAL_MEM}MB"
