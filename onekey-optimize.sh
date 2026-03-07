#!/bin/sh
# onekey-optimize.sh - 一键全量优化 (ZRAM + 性能调优)
# 适用: OpenWrt R1S H5 (ARMv8, BusyBox)

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    logger -t "onekey-optimize" "$1" 2>/dev/null
}

# ===================== ZRAM 配置 =====================

log "--- 配置 ZRAM ---"

# 加载 zram 内核模块
if ! lsmod 2>/dev/null | grep -q "^zram"; then
    modprobe zram 2>/dev/null || log "  [警告] 加载 zram 模块失败，可能已内置"
fi

# 等待设备节点出现
ZRAM_DEV="/dev/zram0"
ZRAM_SYS="/sys/block/zram0"
retry=0
while [ ! -b "$ZRAM_DEV" ] && [ "$retry" -lt 5 ]; do
    sleep 1
    retry=$((retry + 1))
done

if [ ! -b "$ZRAM_DEV" ]; then
    log "  [错误] zram0 设备不存在，跳过 ZRAM 配置"
else
    # 先重置设备（防止已挂载状态写入失败）
    if grep -q "$ZRAM_DEV" /proc/swaps 2>/dev/null; then
        swapoff "$ZRAM_DEV" 2>/dev/null
    fi
    echo 1 > "${ZRAM_SYS}/reset" 2>/dev/null

    # 设置压缩算法 (lz4 > lzo-rle > lzo，按支持度降级)
    COMP_ALG_PATH="${ZRAM_SYS}/comp_algorithm"
    if [ -f "$COMP_ALG_PATH" ]; then
        for alg in lz4 lzo-rle lzo; do
            if grep -q "$alg" "$COMP_ALG_PATH" 2>/dev/null; then
                echo "$alg" > "$COMP_ALG_PATH" 2>/dev/null && break
            fi
        done
        log "  压缩算法: $(cat "$COMP_ALG_PATH" | grep -o '\[.*\]' | tr -d '[]')"
    fi

    # 动态计算 ZRAM 大小：物理内存的 50%，最小 64MB，最大 512MB
    TOTAL_MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    ZRAM_KB=$((TOTAL_MEM_KB / 2))
    [ "$ZRAM_KB" -lt 65536  ] && ZRAM_KB=65536   # 最小 64MB
    [ "$ZRAM_KB" -gt 524288 ] && ZRAM_KB=524288  # 最大 512MB
    ZRAM_BYTES=$((ZRAM_KB * 1024))

    echo "$ZRAM_BYTES" > "${ZRAM_SYS}/disksize"
    log "  ZRAM 大小: $((ZRAM_KB / 1024))MB (物理内存 $((TOTAL_MEM_KB / 1024))MB 的 50%)"

    # 格式化并激活 swap
    mkswap "$ZRAM_DEV" > /dev/null 2>&1
    swapon -p 100 "$ZRAM_DEV" 2>/dev/null
    log "  ZRAM swap 已激活: $(swapon -s 2>/dev/null | grep zram)"
fi

# ===================== 调用基础优化脚本 =====================

SCRIPT_DIR=$(dirname "$0")
if [ -f "${SCRIPT_DIR}/auto-optimize.sh" ]; then
    log "--- 执行 auto-optimize.sh ---"
    sh "${SCRIPT_DIR}/auto-optimize.sh"
else
    log "  [提示] auto-optimize.sh 未找到，跳过基础优化"
fi

# ===================== Cron 任务注册 =====================

log "--- 配置定时任务 ---"

CRON_FILE="/etc/crontabs/root"
mkdir -p /etc/crontabs

# 移除旧的同名任务，防止重复
sed -i '/monitor-memory\.sh/d' "$CRON_FILE" 2>/dev/null
sed -i '/auto-optimize\.sh/d'  "$CRON_FILE" 2>/dev/null

# 添加新任务
INSTALL_DIR="/usr/local/bin"
echo "*/5 * * * * sh ${INSTALL_DIR}/monitor-memory.sh" >> "$CRON_FILE"
echo "0 3 * * *   sh ${INSTALL_DIR}/auto-optimize.sh"  >> "$CRON_FILE"
log "  Cron 任务已写入 $CRON_FILE"

# 重启 crond (OpenWrt cron 服务名)
if [ -f /etc/init.d/cron ]; then
    /etc/init.d/cron enable  2>/dev/null
    /etc/init.d/cron restart 2>/dev/null
    log "  crond 已重启"
elif command -v crond > /dev/null 2>&1; then
    killall crond 2>/dev/null
    crond -c /etc/crontabs 2>/dev/null &
    log "  crond 已手动启动"
fi

# ===================== 安装脚本到系统目录 =====================

log "--- 安装脚本到 $INSTALL_DIR ---"
mkdir -p "$INSTALL_DIR"

for script in auto-optimize.sh monitor-memory.sh setup-dns.sh; do
    SRC="${SCRIPT_DIR}/${script}"
    if [ -f "$SRC" ]; then
        cp "$SRC" "${INSTALL_DIR}/${script}"
        chmod +x "${INSTALL_DIR}/${script}"
        log "  已安装: ${INSTALL_DIR}/${script}"
    fi
done

log "✅ 一键优化完成！"
log "   ZRAM swap: $(grep zram /proc/swaps 2>/dev/null | awk '{print $1, $3"kB"}' || echo '未激活')"
log "   可用内存: $(awk '/^MemAvailable:/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
