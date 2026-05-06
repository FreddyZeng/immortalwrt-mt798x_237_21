#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EQOS="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos"
DHCP_MARK="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/dhcp_mark.sh"
INITD="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos"
VERIFY_QOS="$ROOT/docs/verify-vip-qos.sh"
HNAT_HOOK="$ROOT/target/linux/mediatek/files-5.4/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

contains() {
    grep -Fq "$1" "$2" || fail "$3"
}

absent() {
    if grep -Fq "$1" "$2"; then
        fail "$3"
    fi
}

sh -n "$EQOS"
sh -n "$DHCP_MARK"
sh -n "$INITD"
sh -n "$VERIFY_QOS"

absent 'iptables -t mangle -F PREROUTING' "$INITD" \
    "eqos init script must not flush full PREROUTING chain and break SSR Plus/TProxy rules"
contains 'cleanup_loadbalance_rules()' "$INITD" \
    "eqos init script must cleanup only its own loadbalance PREROUTING rules"
contains '[EQOS-B014-03] cleanup loadbalance rules' "$INITD" \
    "loadbalance cleanup must have traceable diagnostic logging"

contains 'hash_mac $MAC' "$DHCP_MARK" \
    "DHCP ordinary WRR mark allocation must stay in hash range Q2-Q30"
absent 'MARK=31' "$DHCP_MARK" \
    "DHCP ordinary devices must never allocate Q31/Q63 rate-limit queues"
contains 'eqos_macs=$(uci -q show eqos' "$DHCP_MARK" \
    "dhcp_mark must collect explicitly configured MAC devices"
contains 'if echo "$eqos_macs" | grep -qxF "$MAC_LC"; then' "$DHCP_MARK" \
    "dhcp_mark must skip explicit VIP/rate-limit devices by MAC"
contains 'if [ "$MARK_VALUE" -lt "$MIN_MARK" ] || [ "$MARK_VALUE" -gt "$MAX_MARK" ]; then' "$DHCP_MARK" \
    "dhcp_mark must normalize stale invalid marks back into Q2-Q30"

contains 'cleanup_ipv6_mac_rules()' "$EQOS" \
    "eqos must define a full IPv6 MAC cleanup helper"
contains 'for d in $(seq 2 31); do' "$EQOS" \
    "IPv6 upload cleanup must cover WRR and rate-limit marks"
contains 'for d in $(seq 34 63); do' "$EQOS" \
    "IPv6 download cleanup must cover WRR and rate-limit marks"
contains 'cleanup_ipv6_mac_rules "$macaddr"' "$EQOS" \
    "eqos add must cleanup old IPv6 MAC state before installing a new state"
contains 'ensure_forward_rule()' "$EQOS" \
    "static FORWARD rules must be installed through an idempotent checked helper"
contains 'ensure_forward_rule "game_download_109_q33"' "$EQOS" \
    "109.x UDP download acceleration rule must be explicitly installed"
contains '[EQOS-B013-07] static FORWARD rule install failed' "$EQOS" \
    "static FORWARD rule installation failures must be logged"
contains 'rl_forward_file="/tmp/rl_forward_ips"' "$EQOS" \
    "eqos must track rate-limit FORWARD override IPs for start/stop cleanup"
contains 'cleanup_recorded_ipv4_forward_rules' "$EQOS" \
    "eqos start/stop must remove stale rate-limit FORWARD overrides"
contains 'cleanup_ipv4_forward_device_rules "$ip"' "$EQOS" \
    "eqos state transitions must cleanup exact IPv4 FORWARD override rules"
contains 'iptables -t mangle -A FORWARD -s "$ip" -j DSCP --set-dscp 31' "$EQOS" \
    "rate-limited upload must get final FORWARD override after static game/VIP rules"
contains 'iptables -t mangle -A FORWARD -d "$ip" -j DSCP --set-dscp 63' "$EQOS" \
    "rate-limited download must get final FORWARD override after static game/VIP rules"
contains '[EQOS-B013-04] install rate-limit final override' "$EQOS" \
    "rate-limit final override must have traceable diagnostic logging"
contains 'hash_key="${ip:-$macaddr}"' "$EQOS" \
    "MAC-only devices must use MAC as deterministic WRR hash key"
contains 'eqos add: skip device without ip/mac' "$EQOS" \
    "eqos add must reject empty device identity"
contains 'if [ -n "$ip" ]; then' "$EQOS" \
    "IPv4 DSCP rules must be guarded for MAC-only IPv6 devices"

contains 'hnat_hqos_ipv4_qid' "$HNAT_HOOK" \
    "HNAT must reconstruct stored HQOS qid for DSCP update checks"
contains 'hnat_hqos_ipv4_queue_matches' "$HNAT_HOOK" \
    "HNAT must compare HQOS queue identity instead of egress remark DSCP"
contains 'skb_qid = (iph->tos >> 2) & MTK_QDMA_TX_MASK;' "$HNAT_HOOK" \
    "HNAT HQOS update must derive current queue from skb DSCP"
contains 'if (!hnat_hqos_ipv4_queue_matches(skb, entry, iph))' "$HNAT_HOOK" \
    "HNAT HQOS update must only invalidate when queue identity changes"
absent 'if (IS_IPV4_GRP(entry) && entry->ipv4_hnapt.iblk2.dscp != iph->tos)' "$HNAT_HOOK" \
    "HNAT must not unconditionally compare rewritten egress DSCP with skb TOS"

contains '不会占用 Q31/Q63' "$VERIFY_QOS" \
    "verification script must document that DHCP overflow never uses rate-limit queues"
contains 'awk '\''$2==1 || $2>=31'\''' "$VERIFY_QOS" \
    "verification script must fail any DHCP mark that enters Q1/Q31+"
contains '限速最终覆盖 上传 ${ip} → DSCP=31' "$VERIFY_QOS" \
    "verification script must check final rate-limit upload override rules"
contains '限速最终覆盖 下载 ${ip} → DSCP=63' "$VERIFY_QOS" \
    "verification script must check final rate-limit download override rules"
absent 'dhcp_mark.sh 为每个 DHCP 设备调用 eqos add' "$VERIFY_QOS" \
    "verification text must not claim dhcp_mark calls eqos add"

echo "PASS: QoS regression checks"
