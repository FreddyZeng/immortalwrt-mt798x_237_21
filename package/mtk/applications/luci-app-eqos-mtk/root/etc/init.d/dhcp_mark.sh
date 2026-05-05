#!/bin/sh

ACTION=$2
MARK_FILE="/tmp/dhcp_mac_mark_mapping"  # 存储MAC和MARK映射关系的文件
LEASE_FILE="/tmp/dhcp.leases"           # DHCP leases 文件
# Marks 2-30: smarthqos per-user WRR slots (matches Q2-Q30 / Q34-Q62).
# Mark 1  is reserved for 109.x game upload  (Q1 SP).
# Mark 31 is reserved for rate-limited overflow (Q31 WRR).
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

# 检查mark是否被占用
is_mark_in_use() {
    MARK=$1
    grep -q " $MARK$" "$MARK_FILE"
    return $?
}

# 分配一个可用的mark (范围 MIN_MARK-MAX_MARK = 2-30)
# 溢出时返回 31 (WRR overflow, shared with rate-limited devices)
allocate_mark() {
    MAC=$1
    MARK=$(hash_mac $MAC)
    retries=0
    max_retries=28  # 29 slots (2-30), max 28 linear probes

    while is_mark_in_use $MARK; do
        MARK=$((MARK + 1))
        retries=$((retries + 1))
        if [ "$MARK" -gt $MAX_MARK ]; then
            MARK=$MIN_MARK  # wrap within 2-30
        fi
        if [ "$retries" -ge "$max_retries" ]; then
            # All 29 slots full: overflow to Q31/Q63 (shared WRR pool)
            MARK=31
            break
        fi
    done
    echo $MARK
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
process_existing_leases() {
    while read -r line; do
        IP=$(echo "$line" | awk '{print $3}')
        MAC=$(echo "$line" | awk '{print $2}')
        EXISTING_MARK=$(grep "^$MAC " "$MARK_FILE" | awk '{print $2}')
        if [ -z "$EXISTING_MARK" ]; then
            # 如果没有记录，分配新的MARK
            MARK_VALUE=$(allocate_mark $MAC)
            save_mapping $MAC $MARK_VALUE
        else
            # 使用现有的MARK
            MARK_VALUE=$EXISTING_MARK
        fi
	    idpair=$((MARK_VALUE+32))
        # 添加iptables规则，基于MAC和IP地址给这个设备打上MARK
	iptables -t mangle -D eqos -s $IP -j DSCP --set-dscp ${MARK_VALUE}
	iptables -t mangle -D eqos -d $IP -j DSCP --set-dscp ${idpair}
	ip6tables -t mangle -D eqos -m mac --mac-source $MAC -j MARK --set-mark ${MARK_VALUE}
	ebtables -t nat -D eqos -p ipv6 -d $MAC -j mark --mark-set ${idpair}
	iptables -t mangle -A eqos -s $IP -j DSCP --set-dscp ${MARK_VALUE}
	iptables -t mangle -A eqos -d $IP -j DSCP --set-dscp ${idpair}
	ip6tables -t mangle -A eqos -m mac --mac-source $MAC -j MARK --set-mark ${MARK_VALUE}
	ebtables -t nat -A eqos -A ipv6 -d $MAC -j mark --mark-set ${idpair}
    done < "$LEASE_FILE"
}

if [ "$ACTION" = "init" ]; then
    rm /tmp/dhcp_mac_mark_mapping
    load_mapping
    iptables -t mangle -F eqos
    ip6tables -t mangle -F eqos
    ebtables -t nat  -F eqos
    process_existing_leases
fi

