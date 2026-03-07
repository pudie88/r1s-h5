#!/bin/sh
# setup-dns.sh - 智能 DNS 分层配置 (带依赖性检查)
# 适用: OpenWrt + AdGuardHome / OpenClash 组合

# ===================== 工具函数 =====================

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    logger -t "setup-dns" "$1" 2>/dev/null
}

# 动态获取 LAN IP
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | awk -F'/' '{print $1}')
if [ -z "$LAN_IP" ]; then
    LAN_IP=$(ip addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n1)
fi
if [ -z "$LAN_IP" ]; then
    LAN_IP="192.168.1.1"
    log "[警告] 无法自动获取 LAN IP，使用默认值 $LAN_IP"
fi
log "LAN IP: $LAN_IP"

DNS_ACTIVE=""

# ===================== 停止 dnsmasq =====================

# 注意：若 OpenClash 依赖 dnsmasq 做本地转发，需保留 dnsmasq 并修改其端口
# 这里采用完全接管策略（AGH 或 OC 直接监听 53）
if /etc/init.d/dnsmasq status > /dev/null 2>&1; then
    log "停止并禁用 dnsmasq..."
    /etc/init.d/dnsmasq stop    2>/dev/null
    /etc/init.d/dnsmasq disable 2>/dev/null
fi

# ===================== 配置 AdGuardHome =====================

if [ -f /etc/init.d/adguardhome ]; then
    log "检测到 AdGuardHome，开始配置..."

    # 检查 AGH 配置文件路径
    AGH_CFG=$(uci get adguardhome.config.configpath 2>/dev/null || echo "/etc/adguardhome/AdGuardHome.yaml")

    uci set adguardhome.config.enabled=1
    uci set adguardhome.config.port=3000   # Web 管理端口
    uci commit adguardhome 2>/dev/null

    # 如果有 YAML 配置，直接写入 DNS 设置
    if [ -f "$AGH_CFG" ]; then
        # 使用 sed 修改上游 DNS（保留格式）
        sed -i '/upstream_dns:/,/^[^ ]/{ /- /d }' "$AGH_CFG" 2>/dev/null
        sed -i '/upstream_dns:/a\  - tls://dns.alidns.com\n  - tls://dot.pub\n  - https://dns.alidns.com/dns-query' "$AGH_CFG" 2>/dev/null
        sed -i 's/^  port: [0-9]*/  port: 53/' "$AGH_CFG" 2>/dev/null
        log "  AGH YAML 已更新"
    fi

    /etc/init.d/adguardhome restart 2>/dev/null
    sleep 2

    # 验证 AGH 是否实际监听 53
    if netstat -lnup 2>/dev/null | grep ':53 ' | grep -q 'AdGuard\|adguard'; then
        DNS_ACTIVE="adguardhome"
        log "  AdGuardHome 已在端口 53 监听"
    elif ss -lnup 2>/dev/null | grep -q ':53 '; then
        DNS_ACTIVE="adguardhome"
        log "  AdGuardHome 已启动（端口 53）"
    else
        log "  [警告] AdGuardHome 未能监听 53 端口，请检查配置"
    fi
fi

# ===================== 配置 OpenClash =====================

if [ -f /etc/init.d/openclash ]; then
    log "检测到 OpenClash，开始配置..."

    if [ "$DNS_ACTIVE" = "adguardhome" ]; then
        # AGH 已占用 53，OpenClash DNS 监听 7874，通过 iptables 转发流量
        OC_DNS_PORT=7874
        log "  AGH 已占用 53，OpenClash DNS 将使用端口 $OC_DNS_PORT"
        uci set openclash.config.dns_port="$OC_DNS_PORT" 2>/dev/null
    else
        # 无 AGH，OpenClash 直接监听 53
        uci set openclash.config.dns_port=53 2>/dev/null
    fi

    uci set openclash.config.enable=1 2>/dev/null
    uci commit openclash 2>/dev/null
    /etc/init.d/openclash restart 2>/dev/null
    log "  OpenClash 已启动"

    [ -z "$DNS_ACTIVE" ] && DNS_ACTIVE="openclash"
fi

# ===================== 防火墙 DNS 劫持规则 =====================

if [ -n "$DNS_ACTIVE" ]; then
    log "--- 应用 DNS 防火墙劫持规则 ---"

    # 清除同名旧规则，防止重复叠加
    OLD_IDX=$(uci show firewall 2>/dev/null | grep "redirect.*name='DNS-Force'" | awk -F'[.[]' '{print $3}' | head -n1)
    if [ -n "$OLD_IDX" ]; then
        uci delete "firewall.@redirect[$OLD_IDX]" 2>/dev/null
        log "  已清除旧 DNS-Force 规则 (idx=$OLD_IDX)"
    fi

    # 新增 DNS 重定向规则（UDP）
    uci add firewall redirect > /dev/null
    uci set firewall.@redirect[-1].name='DNS-Force-UDP'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].dest_ip="$LAN_IP"
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'

    # 新增 DNS 重定向规则（TCP）
    uci add firewall redirect > /dev/null
    uci set firewall.@redirect[-1].name='DNS-Force-TCP'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].dest_ip="$LAN_IP"
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'

    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null
    log "  DNS 劫持规则已应用 (-> $LAN_IP:53)"
else
    log "[跳过] 未检测到 AGH 或 OpenClash，不应用 DNS 劫持规则"
fi

log "✅ DNS 配置完成！当前主服务: ${DNS_ACTIVE:-None}"
