#!/bin/sh

ACTION=$2
LEASE_FILE="/tmp/dhcp.leases"           # DHCP leases 文件

# Marks 2-30: smarthqos per-user WRR slots (matches Q2-Q30 / Q34-Q62).
# Mark 1  is reserved for 109.x game upload  (Q1 SP).
# Mark 31 is reserved for explicitly rate-limited devices only (Q31 WRR).
MIN_MARK=2
MAX_MARK=30

# 将MAC地址哈希到 MIN_MARK-MAX_MARK (2-30, 共 29 个槽位)。
# 哈希是确定性的，同一 MAC 永远返回同一 WRR 槽位；
# 超过 29 个设备时允许哈希碰撞共享槽位（无 Q31/Q63 限速风险）。
hash_mac() {
    local MAC=$1
    local MAC_HEX
    MAC_HEX=$(echo "$MAC" | sed 's/://g')
    echo $(( 0x$MAC_HEX % 29 + MIN_MARK ))  # 29 slots: 2-30
}

# 处理现有的DHCP记录，为每个租约安装 WRR DSCP/MARK 规则。
# $1: 以换行分隔的"已在eqos中显式配置的IP"列表（VIP/限速设备，必须跳过）
# $2: 以换行分隔的"已在eqos中显式配置的MAC"列表（VIP/限速设备，必须跳过）
process_existing_leases() {
    local eqos_ips="$1"
    local eqos_macs="$2"
    local line IP MAC MAC_LC MARK_VALUE idpair

    while read -r line; do
        IP=$(echo "$line" | awk '{print $3}')
        MAC=$(echo "$line" | awk '{print $2}')
        MAC_LC=$(echo "$MAC" | tr 'A-F' 'a-f')

        # 跳过已在 eqos UCI 中显式配置的设备（VIP/限速）。
        # 这些设备由 'eqos add' 管理自己的 iptables 规则，
        # dhcp_mark 不得覆盖它们。
        if echo "$eqos_ips" | grep -qxF "$IP"; then
            continue
        fi
        if echo "$eqos_macs" | grep -qxF "$MAC_LC"; then
            continue
        fi

        MARK_VALUE=$(hash_mac "$MAC")
        idpair=$((MARK_VALUE + 32))

        # 幂等更新：先删除旧规则再追加（不影响其他设备的规则）
        iptables  -t mangle -D eqos -s "$IP" -j DSCP --set-dscp "$MARK_VALUE" 2>/dev/null
        iptables  -t mangle -D eqos -d "$IP" -j DSCP --set-dscp "$idpair"     2>/dev/null
        ip6tables -t mangle -D eqos -m mac --mac-source "$MAC" -j MARK --set-mark "$MARK_VALUE" 2>/dev/null
        ebtables  -t nat    -D eqos -p ipv6 -d "$MAC" -j mark --mark-set "$idpair" 2>/dev/null
        iptables  -t mangle -A eqos -s "$IP" -j DSCP --set-dscp "$MARK_VALUE"
        iptables  -t mangle -A eqos -d "$IP" -j DSCP --set-dscp "$idpair"
        ip6tables -t mangle -A eqos -m mac --mac-source "$MAC" -j MARK --set-mark "$MARK_VALUE"
        ebtables  -t nat    -A eqos -p ipv6 -d "$MAC" -j mark --mark-set "$idpair"
    done < "$LEASE_FILE"
}

if [ "$ACTION" = "init" ]; then
    # 清理遗留的状态文件（旧版本线性探针架构遗留，当前纯哈希无需持久化）
    rm -f /tmp/dhcp_mac_mark_mapping

    # 从 eqos UCI 获取已显式配置的设备 IP 和 MAC 列表（VIP/限速）。
    # dhcp_mark 不得为这些设备分配 WRR slot，以免覆盖其已有的 SP/限速规则。
    eqos_ips=$(uci -q show eqos | grep "\.ip='" | sed "s/.*ip='//;s/'.*//")
    eqos_macs=$(uci -q show eqos | grep "\.mac='" | sed "s/.*mac='//;s/'.*//g" | tr 'A-F' 'a-f')

    # 注意：不执行 iptables -F eqos。
    # VIP/限速设备的规则由 'eqos add' 管理，全局 flush 会销毁这些规则。
    # dhcp_mark 只通过幂等 delete+add 管理自己负责的 WRR per-lease 规则。
    process_existing_leases "$eqos_ips" "$eqos_macs"
fi
