#!/bin/sh
# onekey-optimize.sh - 一键全量优化 (ZRAM + 性能调优)
# 适用: OpenWrt R1S H5 (ARMv8, BusyBox)
# 用法: sh /usr/local/bin/onekey-optimize.sh

set -e
SCRIPT_DIR="/usr/local/bin"
log() { echo "[$(date '+%H:%M:%S')] $1"; logger -t "onekey-opt" "$1" 2>/dev/null || true; }

log "🚀 开始一键优化..."

# ===================== ZRAM 配置 =====================
log "▶ 配置 ZRAM 压缩交换"

if ! lsmod 2>/dev/null | grep -q "^zram"; then
    modprobe zram 2>/dev/null || log "  ⊘ zram 模块可能已内置"
fi

ZRAM_DEV="/dev/zram0"
retry=0
while [ ! -b "$ZRAM_DEV" ] && [ "$retry" -lt 10 ]; do
    sleep 0.5
    retry=$((retry + 1))
done

if [ -b "$ZRAM_DEV" ]; then
    # 重置设备
    grep -q "$ZRAM_DEV" /proc/swaps 2>/dev/null && swapoff "$ZRAM_DEV" 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    
    # 选择最佳压缩算法
    COMP_PATH="/sys/block/zram0/comp_algorithm"
    if [ -f "$COMP_PATH" ]; then
        for alg in lz4 lzo-rle lzo zstd; do
            if grep -q "\[$alg\]" "$COMP_PATH" 2>/dev/null; then
                echo "$alg" > "$COMP_PATH" 2>/dev/null && break
            fi
        done
        CUR_ALG=$(cat "$COMP_PATH" 2>/dev/null | grep -o '\[[^]]*\]' | tr -d '[]')
        log "  ✓ 压缩算法: ${CUR_ALG:-auto}"
    fi
    
    # 动态计算 ZRAM 大小 (物理内存的 50%, 64MB~512MB)
    TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    ZRAM_KB=$((TOTAL_KB / 2))
    [ "$ZRAM_KB" -lt 65536  ] && ZRAM_KB=65536
    [ "$ZRAM_KB" -gt 524288 ] && ZRAM_KB=524288
    
    echo "$((ZRAM_KB * 1024))" > /sys/block/zram0/disksize
    mkswap "$ZRAM_DEV" >/dev/null 2>&1
    swapon -p 100 "$ZRAM_DEV" 2>/dev/null && \
        log "  ✓ ZRAM 激活: $((ZRAM_KB/1024))MB (优先级:100)" || \
        log "  ✗ ZRAM 激活失败"
else
    log "  ✗ zram0 设备未就绪，跳过"
fi

# ===================== 执行基础优化 =====================
if [ -x "${SCRIPT_DIR}/auto-optimize.sh" ]; then
    log "▶ 执行 auto-optimize.sh"
    sh "${SCRIPT_DIR}/auto-optimize.sh"
fi

# ===================== 配置定时任务 =====================
log "▶ 配置定时任务"
CRON_FILE="/etc/crontabs/root"
mkdir -p /etc/crontabs

# 清理旧任务
sed -i '/monitor-memory\.sh/d; /auto-optimize\.sh/d' "$CRON_FILE" 2>/dev/null || true

# 添加新任务
cat >> "$CRON_FILE" << CRONEOF
# Auto-optimize scripts (R1S H5)
*/5 * * * * sh ${SCRIPT_DIR}/monitor-memory.sh
0 3 * * *   sh ${SCRIPT_DIR}/auto-optimize.sh
CRONEOF

# 重启 cron
if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null
    log "  ✓ crond 已重启"
fi

# ===================== 安装脚本 =====================
log "▶ 安装脚本到系统目录"
mkdir -p "$SCRIPT_DIR"
for script in auto-optimize.sh monitor-memory.sh setup-dns.sh; do
    src="/usr/local/bin/$script"
    if [ -f "$src" ]; then
        cp -f "$src" "${SCRIPT_DIR}/${script}.bak" 2>/dev/null || true
        log "  ✓ 已备份: ${script}.bak"
    fi
done

log "✅ 一键优化完成!"
log "   📊 内存: $(awk '/^MemAvailable:/ {printf "%.0fMB", $2/1024}' /proc/meminfo) 可用"
log "   💾 ZRAM: $(grep -c zram /proc/swaps 2>/dev/null && echo '已激活' || echo '未激活')"
log "   🔄 下次自动优化: 每日 03:00 + 内存>85% 时"

exit 0
