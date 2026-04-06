#!/bin/sh
# setup-dns.sh - 智能 DNS 分层配置
# 适用: OpenWrt + AdGuardHome / OpenClash 组合
# 功能: 自动检测 DNS 服务，配置端口转发和防火墙规则

log() { echo "[$(date '+%H:%M:%S')] $1"; logger -t "setup-dns" "$1" 2>/dev/null || true; }

# 获取 LAN IP
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | awk -F'/' '{print $1}')
[ -z "$LAN_IP" ] && LAN_IP=$(ip addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.10.1"
log "LAN IP: $LAN_IP"

DNS_SERVICE=""

# ===================== 配置 AdGuardHome =====================
if [ -f /etc/init.d/adguardhome ]; then
    log "▶ 检测到 AdGuardHome"
    
    # 基础配置
    uci set adguardhome.config.enabled=1 2>/dev/null
    uci set adguardhome.config.port=3000 2>/dev/null
    uci commit adguardhome 2>/dev/null || true
    
    # 修改 YAML 配置 (上游 DNS)
    AGH_CFG="/etc/adguardhome/AdGuardHome.yaml"
    if [ -f "$AGH_CFG" ]; then
        # 备份
        cp "$AGH_CFG" "${AGH_CFG}.bak" 2>/dev/null || true
        
        # 设置上游 DNS (国内优化)
        cat > /tmp/agh_dns.tmp << 'DNSEOF'
upstream_dns:
  - tls://dns.alidns.com
  - tls://dot.pub
  - https://dns.alidns.com/dns-query
  - 119.29.29.29
  - 223.5.5.5
DNSEOF
        # 简单替换 (生产环境建议用 yq)
        sed -i '/^upstream_dns:/,/^[a-z]/{/^upstream_dns:/!{/^[^ ]/!d}}' "$AGH_CFG" 2>/dev/null
        sed -i '/^upstream_dns:/r /tmp/agh_dns.tmp' "$AGH_CFG" 2>/dev/null
        rm -f /tmp/agh_dns.tmp
        
        # 确保监听 53 端口
        sed -i 's/^  port: [0-9]\+/  port: 53/' "$AGH_CFG" 2>/dev/null
        log "  ✓ AGH 配置已更新"
    fi
    
    /etc/init.d/adguardhome restart 2>/dev/null
    sleep 2
    
    # 验证监听
    if netstat -lnup 2>/dev/null | grep -q ':53 .*adguard' || \
       ss -lnup 2>/dev/null | grep -q ':53 .*adguard'; then
        DNS_SERVICE="adguardhome"
        log "  ✓ AdGuardHome 监听 53 端口"
    else
        log "  ⚠ AdGuardHome 未监听 53，检查配置"
    fi
fi

# ===================== 配置 OpenClash =====================
if [ -f /etc/init.d/openclash ]; then
    log "▶ 检测到 OpenClash"
    
    if [ "$DNS_SERVICE" = "adguardhome" ]; then
        # AGH 已占 53，OC 用 7874
        uci set openclash.config.dns_port=7874 2>/dev/null
        log "  ✓ OpenClash DNS 端口: 7874 (AGH 占用 53)"
    else
        uci set openclash.config.dns_port=53 2>/dev/null
        log "  ✓ OpenClash DNS 端口: 53"
    fi
    
    uci set openclash.config.enable=1 2>/dev/null
    uci commit openclash 2>/dev/null
    /etc/init.d/openclash restart 2>/dev/null
    [ -z "$DNS_SERVICE" ] && DNS_SERVICE="openclash"
fi

# ===================== 防火墙 DNS 劫持 =====================
if [ -n "$DNS_SERVICE" ]; then
    log "▶ 应用 DNS 防火墙规则"
    
    # 清除旧规则
    uci show firewall 2>/dev/null | grep "redirect.*DNS-Force" | \
    awk -F'[.=]' '{print $3}' | sort -rn | \
    while read idx; do
        uci delete "firewall.@redirect[$idx]" 2>/dev/null || true
    done
    
    # 添加新规则 (UDP + TCP)
    for proto in udp tcp; do
        uci add firewall redirect
        uci set firewall.@redirect[-1].name="DNS-Force-${proto}"
        uci set firewall.@redirect[-1].src="lan"
        uci set firewall.@redirect[-1].proto="$proto"
        uci set firewall.@redirect[-1].src_dport="53"
        uci set firewall.@redirect[-1].dest_port="53"
        uci set firewall.@redirect[-1].dest_ip="$LAN_IP"
        uci set firewall.@redirect[-1].target="DNAT"
        uci set firewall.@redirect[-1].enabled="1"
    done
    
    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null
    log "  ✓ DNS 劫持规则已应用 (->$LAN_IP:53)"
fi

log "✅ DNS 配置完成 | 主服务: ${DNS_SERVICE:-None}"
exit 0
