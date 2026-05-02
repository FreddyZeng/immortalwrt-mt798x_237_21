#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EQOS="$ROOT/package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos"
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

grep -Fq 'iptables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "configured VIP must install unified CONNMARK 46"

grep -Fq 'ip6tables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "configured VIP must install unified IPv6 CONNMARK 46"

grep -Fq 'iptables -t mangle -I eqos -s 192.168.0.0/16 -m u32 --u32 "0xc&0x0000FF00=0x00006E00:0x00007700" -m u32 --u32 "0xc&0x000000FF=0x0000000A:0x00000027" -j CONNMARK --set-xmark 46/0xFF' "$EQOS" ||
    fail "static VIP source range must install unified CONNMARK 46"

grep -Fq 'iptables -t mangle -A eqos -m mark --mark 46/0xFF -j DSCP --set-dscp 46' "$EQOS" ||
    fail "global mark 46 to DSCP 46 translation is missing"

grep -Fq 'ip6tables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 2/0xFF' "$EQOS" ||
    fail "IPv6 hardware limit rule must set CONNMARK 2"

UP_LIMIT_BLOCK=$(sed -n '/if \[ \$up -ne 0 \] || \[ \$dl -ne 0 \]; then/,/fi/p' "$EQOS")
echo "$UP_LIMIT_BLOCK" | grep -Fq 'iptables -t mangle -A eqos -m mac --mac-source $macaddr -j CONNMARK --set-xmark 2/0xFF' ||
    fail "unified limit CONNMARK 2 rule must be installed"

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

grep -Fq 'if (qos_mark == 2)' "$HNAT_HOOK" ||
    fail "HNAT must honor mark 2 as hardware limit fallback"
# 检查 CONNMARK 还原规则的掩码保护
RESTORE_MARK_CMD="iptables -t mangle -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark --nfmask 0xFF --ctmask 0xFF"
grep -Fq "$RESTORE_MARK_CMD" "$EQOS" ||
    fail "Global CONNMARK restore rule MUST use --nfmask 0xFF --ctmask 0xFF to protect upper bits"
grep -Fq 'qid = (dir == HQOS_DOWNLOAD) ? 63 : 31;' "$HNAT_HOOK" ||
    fail "HNAT mark 2 fallback must map to Q31/Q63"

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

grep -Fq '2/MARK2 LIMIT 限速设备 WRR' "$VERIFY_QOS" ||
    fail "verification script Q63 label must show DSCP2/MARK2 limit queue"

if grep -Eq 'echo "4[1-5][[:space:]]+SP' "$VERIFY_QOS"; then
    fail "verification script still uses obsolete DSCP 41-45 SP labels"
fi

echo "qos regression checks passed"
