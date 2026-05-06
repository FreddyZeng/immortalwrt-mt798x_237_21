#!/bin/sh

ACTION=$2
MARK_FILE="/tmp/dhcp_mac_mark_mapping"  # 存储MAC和MARK映射关系的文件
LEASE_FILE="/tmp/dhcp.leases"           # DHCP leases 文件
# Marks 2-30: smarthqos per-user WRR slots (matches Q2-Q30 / Q34-Q62).
# Mark 1  is reserved for 109.x game upload  (Q1 SP).
# Mark 31 is reserved for explicitly rate-limited devices only (Q31 WRR).
MIN_MARK=2
MAX_MARK=30

# 定义哈希函数，将MAC地址转化为一个数值，限制在MIN_MARK到MAX_MARK之间
hash_mac() {
    MAC=$1
    MAC_HEX=$(echo "$MAC" | sed 's/://g')
    echo $(( 0x$MAC_HEX % 29 + MIN_MARK ))  # 29 slots: 2-30
}

# 从文件中加载当前的MAC-MARK映射
load_mapping() {
    if [ ! -f "$MARK_FILE" ]; then
        touch "$MARK_FILE"
    fi
    cat "$MARK_FILE"
}

# 分配普通 WRR mark (范围 MIN_MARK-MAX_MARK = 2-30)
# 超过 29 个 DHCP 设备时允许共享普通槽位，不能占用 Q31/Q63 限速队列。
allocate_mark() {
    MAC=$1
    hash_mac $MAC
}

# 保存MAC和MARK的映射
save_mapping() {
    MAC=$1
    MARK=$2
    echo "$MAC $MARK" >> "$MARK_FILE"
}

# 删除MAC对应的MARK映射
delete_mapping() {
    MAC=$1
    sed -i "/^$MAC /d" "$MARK_FILE"
}

# 处理现有的DHCP记录，确保已有设备保留其MARK
# $1: 以换行分隔的"已在eqos中显式配置的IP"列表（VIP/限速设备，必须跳过）
# $2: 以换行分隔的"已在eqos中显式配置的MAC"列表（VIP/限速设备，必须跳过）
process_existing_leases() {
    local eqos_ips="$1"
    local eqos_macs="$2"
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

        EXISTING_MARK=$(grep "^$MAC " "$MARK_FILE" | awk '{print $2}')
        if [ -z "$EXISTING_MARK" ]; then
            MARK_VALUE=$(allocate_mark $MAC)
            save_mapping $MAC $MARK_VALUE
        else
            MARK_VALUE=$EXISTING_MARK
        fi
        if [ "$MARK_VALUE" -lt "$MIN_MARK" ] || [ "$MARK_VALUE" -gt "$MAX_MARK" ]; then
            MARK_VALUE=$(allocate_mark $MAC)
            delete_mapping $MAC
            save_mapping $MAC $MARK_VALUE
        fi

        idpair=$((MARK_VALUE+32))
        # 幂等更新：先删除旧规则再追加（不影响其他设备的规则）
        iptables  -t mangle -D eqos -s $IP -j DSCP --set-dscp ${MARK_VALUE} 2>/dev/null
        iptables  -t mangle -D eqos -d $IP -j DSCP --set-dscp ${idpair}     2>/dev/null
        ip6tables -t mangle -D eqos -m mac --mac-source $MAC -j MARK --set-mark ${MARK_VALUE} 2>/dev/null
        ebtables  -t nat    -D eqos -p ipv6 -d $MAC -j mark --mark-set ${idpair} 2>/dev/null
        iptables  -t mangle -A eqos -s $IP -j DSCP --set-dscp ${MARK_VALUE}
        iptables  -t mangle -A eqos -d $IP -j DSCP --set-dscp ${idpair}
        ip6tables -t mangle -A eqos -m mac --mac-source $MAC -j MARK --set-mark ${MARK_VALUE}
        ebtables  -t nat    -A eqos -p ipv6 -d $MAC -j mark --mark-set ${idpair}
    done < "$LEASE_FILE"
}

if [ "$ACTION" = "init" ]; then
    rm -f /tmp/dhcp_mac_mark_mapping
    load_mapping

    # 从 eqos UCI 获取已显式配置的设备 IP 列表（VIP/限速）。
    # dhcp_mark 不得为这些 IP 分配 WRR slot，以免覆盖其已有的 SP/限速规则。
    eqos_ips=$(uci -q show eqos | grep "\.ip='" | sed "s/.*ip='//;s/'.*//")
    eqos_macs=$(uci -q show eqos | grep "\.mac='" | sed "s/.*mac='//;s/'.*//" | tr 'A-F' 'a-f')

    # 注意：不再执行 iptables -F eqos。
    # VIP/限速设备的规则由 'eqos add' 管理，全局 flush 会销毁这些规则。
    # dhcp_mark 只通过上面的幂等 delete+add 管理自己负责的 WRR per-lease 规则。
    process_existing_leases "$eqos_ips" "$eqos_macs"
fi
