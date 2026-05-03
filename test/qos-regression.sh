#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EQOS="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos"
INITD="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos"
LOADBALANCE="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/loadbalance"
MAKEFILE="$ROOT/package/mtk/applications/luci-app-eqos-mtk/Makefile"
HNAT_HOOK="$ROOT/target/linux/mediatek/files-5.4/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c"
CAKE_PATCH="$ROOT/target/linux/mediatek/patches-5.4/9999995-fix-cake-highest-tin-guard.patch"
VERIFY_QOS="$ROOT/docs/verify-vip-qos.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fq 'case "$id" in' "$EQOS" ||
    fail "legacy comment mode normalization is missing"

grep -Fq 'legacy qos mode fallback' "$EQOS" ||
    fail "legacy comment fallback diagnostic log is missing"

grep -Fq 'case "$dl" in' "$EQOS" ||
    fail "download speed must be normalized before numeric comparisons"

grep -Fq 'case "$up" in' "$EQOS" ||
    fail "upload speed must be normalized before numeric comparisons"

grep -Fq '[ -n "$macaddr" ] && iptables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "configured VIP must guard MAC before installing CONNMARK 46"

grep -Fq '[ -n "$ip" ] && iptables -t mangle -A eqos -s $ip -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "configured IPv4-only VIP upload must install source-IP CONNMARK 46"

grep -Fq '[ "$ipv6_en" = "1" ] && [ -n "$macaddr" ] && ip6tables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "configured VIP must guard IPv6 MAC CONNMARK 46 by ipv6enabled and non-empty mac"

grep -Fq 'iptables -t mangle -I eqos -s 192.168.0.0/16 -m u32 --u32 "0xc&0x0000FF00=0x00006E00:0x00007700" -m u32 --u32 "0xc&0x000000FF=0x0000000A:0x00000027" -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "static VIP source range must install unified CONNMARK 46"

grep -Fq 'iptables  -t mangle -A eqos_apply -m mark --mark 46/0xFF -j DSCP --set-dscp 46' "$EQOS" ||
    fail "global mark 46 to DSCP 46 translation is missing in eqos_apply"

grep -Fq '[ "$ipv6_en" = "1" ] && [ -n "$macaddr" ] && ip6tables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark ${xmark}/0xC0' "$EQOS" ||
    fail "IPv6 hardware limit rule must set directional CONNMARK only with ipv6enabled and non-empty mac"

UP_LIMIT_BLOCK=$(sed -n '/if \[ \$xmark -ne 0 \]; then/,/fi/p' "$EQOS")
echo "$UP_LIMIT_BLOCK" | grep -Fq '[ -n "$macaddr" ] && iptables  -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark ${xmark}/0xC0' ||
    fail "unified limit CONNMARK 0xC0 MAC rule must guard non-empty mac"

echo "$UP_LIMIT_BLOCK" | grep -Fq '[ -n "$ip" ] && iptables  -t mangle -A eqos -s $ip -j CONNMARK --set-xmark ${xmark}/0xC0' ||
    fail "IPv4-only hardware upload limit must install source-IP CONNMARK 0xC0 rule"

grep -Fq 'dev_key="mac_${macaddr}"' "$EQOS" ||
    fail "hardware limit state key must prefer non-empty mac address"

grep -Fq 'dev_key="ip_${ip}"' "$EQOS" ||
    fail "hardware limit state key must fall back to IPv4 address"

grep -Fq 'old_up_file="/tmp/eqos_dev_up_${dev_key}"' "$EQOS" ||
    fail "hardware upload limit state file must use normalized device key"

grep -Fq 'old_dl_file="/tmp/eqos_dev_dl_${dev_key}"' "$EQOS" ||
    fail "hardware download limit state file must use normalized device key"

grep -Fq 'skip device without ip/mac' "$EQOS" ||
    fail "device add must reject empty ip and empty mac before rule generation"

if grep -Eq 'ebtables -t nat .* eqos' "$EQOS"; then
    fail "ebtables rules must be completely removed from eqos script"
fi

grep -Fq 'qos_mark = skb->mark & 0xFF;' "$HNAT_HOOK" ||
    fail "HNAT must safely extract lower 8 bits of skb mark for policy matching"

grep -Fq 'dir == HQOS_DOWNLOAD && qos_mark == 46' "$HNAT_HOOK" ||
    fail "HNAT must honor trusted VIP download mark 46"

grep -Fq 'dscp = (dscp & 0x03) | 0xB8;' "$HNAT_HOOK" ||
    fail "trusted VIP download mark 46 must preserve EF DSCP"

grep -Fq 'qid = 32;' "$HNAT_HOOK" ||
    fail "trusted VIP download mark 46 must map to Q32"

grep -Fq 'if ((qos_mark & 0x80) && dir == HQOS_DOWNLOAD)' "$HNAT_HOOK" ||
    fail "HNAT must honor mark 0x80 as hardware down limit"
# 检查 CONNMARK 还原规则的掩码保护以及在 eqos_apply 中的延迟应用
RESTORE_MARK_CMD="iptables -t mangle -A eqos_apply -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j CONNMARK --restore-mark --nfmask 0xFF --ctmask 0xFF"
grep -Fq "$RESTORE_MARK_CMD" "$EQOS" ||
    fail "eqos_apply MUST use --nfmask 0xFF --ctmask 0xFF restore-mark to apply ctmark to ALL packets"
grep -Fq 'qid = 63;  // [HNAT-C-FQOS01-05-①] 下行限速 → Q63' "$HNAT_HOOK" ||
    fail "HNAT mark 0x80 fallback must map to Q63"

grep -Fq 'qid = dscp_to_queue(dscp, hash_ip);' "$HNAT_HOOK" ||
    fail "HNAT mark 0/default path must fall back to DSCP mapping"

grep -Fq '+	u8 highest_priority_tin = 0;' "$CAKE_PATCH" ||
    fail "CAKE highest_priority_tin must be initialized"

grep -Fq 'q->tin_cnt > 1 && is_nat_target_ip_ipv4_k(skb, q)' "$CAKE_PATCH" ||
    fail "CAKE VIP highest tin path must require multi-tin mode"

grep -Fq 'q->tin_cnt > 1 && is_nat_target_ip_109_k(skb)' "$CAKE_PATCH" ||
    fail "CAKE 109 small UDP highest tin path must require multi-tin mode"

TIN_GUARDS=$(grep -Fc 'q->tin_cnt > 1 && tin == highest_priority_tin' "$CAKE_PATCH")
[ "$TIN_GUARDS" -eq 3 ] ||
    fail "CAKE highest tin downgrade guards must cover priority, mark, and DSCP paths"

grep -Fq -- '-	else if (skb->priority == TC_PRIO_MAX) {' "$CAKE_PATCH" ||
    fail "CAKE patch must remove TC_PRIO_MAX highest tin bypass"

if grep -Eq '^\+.*skb->priority == TC_PRIO_MAX' "$CAKE_PATCH"; then
    fail "TC_PRIO_MAX must not bypass VIP-only highest tin protection"
fi

grep -Fq '48/56  CS6-7  网络控制 SP' "$VERIFY_QOS" ||
    fail "verification script Q1/Q33 label must match HNAT DSCP mapping"

grep -Fq '46/MARK46 EF 可信VIP下行 SP' "$VERIFY_QOS" ||
    fail "verification script Q32 label must show trusted VIP download queue"

grep -Fq '32/40/44 CS4/5/VA 实时 SP' "$VERIFY_QOS" ||
    fail "verification script Q2/Q34 label must match HNAT DSCP mapping"

grep -Fq 'MARK0xC0 LIMIT 限速设备 WRR' "$VERIFY_QOS" ||
    fail "verification script Q63 label must show DSCP2/MARK0xC0 limit queue"

if grep -Eq 'echo "4[1-5][[:space:]]+SP' "$VERIFY_QOS"; then
    fail "verification script still uses obsolete DSCP 41-45 SP labels"
fi

grep -Fq 'kmod-sched-flower' "$MAKEFILE" ||
    fail "software tc IPv6 mode must depend on kmod-sched-flower"

grep -Fq 'protocol ipv6 u32' "$EQOS" ||
    fail "software tc must redirect IPv6 ingress to IFB"

grep -Fq 'protocol ipv6 flower dst_mac $macaddr' "$EQOS" ||
    fail "software tc IPv6 download filter must match dst_mac"

grep -Fq 'protocol ipv6 flower src_mac $macaddr' "$EQOS" ||
    fail "software tc IPv6 upload filter must match src_mac"

if grep -Fq '2>/dev/null || true' "$EQOS"; then
    fail "software tc IPv6 rule installation must not silently ignore failures"
fi

if grep -Fq 'iptables-save -t mangle' "$LOADBALANCE"; then
    fail "loadbalance migration cleanup must not scan and broadly delete PREROUTING rules"
fi

grep -Fq 'for _packet in 0 1 2 3 4 5 6 7; do' "$LOADBALANCE" ||
    fail "loadbalance exact cleanup must enumerate compressed nth packet indexes independently"

grep -Fq 'for _mark_idx in 0 1 2 3 4 5 6 7; do' "$LOADBALANCE" ||
    fail "loadbalance exact cleanup must enumerate route mark cfg indexes independently"

grep -Fq -- '--packet "$_packet"' "$LOADBALANCE" ||
    fail "loadbalance exact cleanup must match nth packet with independent packet index"

grep -Fq '0x20 + _mark_idx' "$LOADBALANCE" ||
    fail "loadbalance exact cleanup must compute xmark from independent mark index"

if grep -Fq -- '--packet "$_ci"' "$LOADBALANCE"; then
    fail "loadbalance cleanup must not bind nth packet index to cfg index"
fi

grep -Fq 'while ip rule del fwmark "2${_ci}" table "2${_ci}0"' "$LOADBALANCE" ||
    fail "loadbalance must cleanup legacy low-bit fwmark rules"

grep -Fq 'while ip rule del fwmark ${_om}/0xff00 table "2${_ci}0"' "$LOADBALANCE" ||
    fail "loadbalance must cleanup all masked high-bit fwmark rules with table match"

grep -Fq 'while ip rule del fwmark "2${_ci}" table "2${_ci}0"' "$INITD" ||
    fail "init.d stop must cleanup legacy low-bit fwmark rules"

grep -Fq 'cleanup_eqos_route_tables "eqos_start"' "$EQOS" ||
    fail "eqos start must cleanup stale device WAN route tables before rebuilding rules"

grep -Fq 'cleanup_eqos_route_tables "eqos_stop"' "$EQOS" ||
    fail "eqos stop must cleanup device WAN route tables when called directly"

grep -Fq -- '-m comment --comment "eqos_lb"' "$LOADBALANCE" ||
    fail "loadbalance route mark rules must be tagged with eqos_lb comment"

grep -Fq -- '-m comment --comment "eqos_lb"' "$INITD" ||
    fail "init.d stop must delete the same comment-tagged eqos_lb rules it installs"

grep -Fq 'iptables -t mangle -A PREROUTING -j eqos_dev' "$EQOS" ||
    fail "eqos_dev PREROUTING jump must append safely before loadbalance inserts eqos_lb at rule 1"

if grep -Fq 'iptables -t mangle -I PREROUTING 2 -j eqos_dev' "$EQOS"; then
    fail "eqos_dev PREROUTING jump must not use fragile fixed insertion index 2"
fi

grep -Fq 'iface_list=$(uci -q get eqos.config.interface | tr' "$EQOS" ||
    fail "device WAN route install must resolve interface mapping from eqos config"

grep -Fq 'iface_list="wan wan2 wan3 wan4 wan5 wan6 wan7 wan8"' "$EQOS" ||
    fail "device WAN route install must provide wan/wan2 fallback mapping"

grep -Fq 'ip rule add fwmark ${mark}/0xff00 table "$table"' "$EQOS" ||
    fail "device WAN binding must create independent high-bit ip rule"

grep -Fq 'eqos_default_route_for_iface()' "$EQOS" ||
    fail "device WAN binding must resolve actual default route dev and gateway"

DEV_ROUTE_BLOCK=$(sed -n '/install_eqos_dev_route()/,/^}/p' "$EQOS")

if echo "$DEV_ROUTE_BLOCK" | grep -Fq 'ip route flush table "$table"'; then
    fail "device WAN route install must not flush active table before replacement route succeeds"
fi

grep -Fq 'ip route replace default via "$gateway" dev "$route_dev" table "$table"' "$EQOS" ||
    fail "device WAN binding must replace default route before installing policy rule when gateway is present"

grep -Fq 'ip route replace default dev "$route_dev" table "$table"' "$EQOS" ||
    fail "device WAN binding must support point-to-point default routes without gateway"

ROUTE_LINE=$(echo "$DEV_ROUTE_BLOCK" | grep -n 'ip route replace default via "$gateway" dev "$route_dev" table "$table"' | head -1 | cut -d: -f1)
RULE_LINE=$(echo "$DEV_ROUTE_BLOCK" | grep -n 'ip rule add fwmark ${mark}/0xff00 table "$table"' | head -1 | cut -d: -f1)
[ -n "$ROUTE_LINE" ] && [ -n "$RULE_LINE" ] && [ "$ROUTE_LINE" -lt "$RULE_LINE" ] ||
    fail "device WAN route install must create/replace route before adding fwmark policy rule"

grep -Fq 'CONNMARK --save-mark --nfmask 0xFF00 --ctmask 0xFF00' "$EQOS" ||
    fail "eqos device WAN binding must save high-bit connmark independently from loadbalance"

grep -Fq 'iptables -t mangle -A eqos_dev -s $ip -m conntrack --ctstate NEW -j CONNMARK --save-mark --nfmask 0xFF00 --ctmask 0xFF00' "$EQOS" ||
    fail "eqos device WAN binding must scope CONNMARK save to the configured device IP"

if grep -Fq 'iptables -t mangle -A POSTROUTING -m conntrack --ctstate NEW \' "$EQOS"; then
    fail "eqos_dev must not install broad POSTROUTING save-mark rules"
fi

grep -Fq 'skip device WAN binding with legacy nonnumeric interface' "$EQOS" ||
    fail "eqos device WAN binding must reject legacy textual interface values"

grep -Fq 'skip device WAN binding without IPv4 source' "$EQOS" ||
    fail "eqos device WAN binding must reject MAC-only or IPv6-only route binding"

grep -Fq 'skip device WAN binding with out-of-range interface' "$EQOS" ||
    fail "eqos device WAN binding must reject interface indexes outside 0-7"

echo "qos regression checks passed"
