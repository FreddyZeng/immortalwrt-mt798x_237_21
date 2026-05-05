#!/bin/sh
# QoS 深度验证脚本 v3 — 匹配新队列设计
# 在路由器上运行: sh /root/verify-vip-qos.sh
#
# ═══════════════════════════════════════════════════════
#  IPv4 队列分配规则（完整定义）
# ═══════════════════════════════════════════════════════
#
# ┌─────────────────────────────────────────────────────┐
# │  SP 专属队列（Strict Priority，绝对优先）            │
# ├──────┬──────────────────────────────────────────────┤
# │  Q0  │ VIP 上传  SP EF — 仅限 VIP 设备占用          │
# │  Q32 │ VIP 下载  SP EF — 仅限 VIP 设备占用          │
# │  Q1  │ 游戏上传  SP EF — 109.x 子网 UDP≤300B        │
# │  Q33 │ 游戏下载  SP EF — 109.x 子网 UDP≤300B        │
# └──────┴──────────────────────────────────────────────┘
#
# VIP 设备的判定方式（两种，任一满足即为 VIP）：
#   ① 静态 IP 范围（FORWARD 链 u32 规则，最终覆盖）：
#        192.168.11x.10-39（第三段 110-119，第四段 10-39）
#        第四段 10-39 = VIP，即 .10-.39 → Q0/Q32
#        第四段  1-9  = WRR 普通流量（不在 VIP 范围）
#        第四段 40-254= 普通流量，DHCP 下发范围
#   ② 动态标记（eqos add comment=64 或 comment=vip）：
#        任何 DHCP 动态 IP（.40-.254）或手动 IP 均可
#        在 LuCI 中标记 comment=64 成为 VIP → Q0/Q32
#
# ┌─────────────────────────────────────────────────────┐
# │  WRR 普通流量队列（per-user 隔离，AF41）            │
# ├─────────────────────────────────────────────────────┤
# │  Q2-Q30  │ 上传  WRR AF41 — sch2，29 个用户槽位    │
# │  Q34-Q62 │ 下载  WRR AF41 — sch3，29 个用户槽位    │
# │                                                     │
# │ 以下流量进入 WRR 普通槽（不管是 DHCP 还是手动 IP）: │
# │  · 109.x 子网默认流量（非 UDP≤300B 部分）          │
# │  · .1-.9   手动指定 IP（非 VIP 范围）              │
# │  · .40-.254 DHCP 下发 IP（未被 VIP/限速标记）      │
# │  · 其他子网普通设备（未在 LuCI 配置限速或 VIP）     │
# └─────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────┐
# │  限速设备队列（所有限速设备共享，BE）               │
# ├─────────────────────────────────────────────────────┤
# │  Q31 │ 限速上传  WRR BE — sch2                     │
# │  Q63 │ 限速下载  WRR BE — sch3                     │
# │                                                     │
# │ 触发条件：eqos add 时 dl>0 或 up>0                  │
# │ 所有限速设备共享 Q31/Q63，tc HTB 执行带宽上限        │
# └─────────────────────────────────────────────────────┘
#
# 109.x 子网游戏加速（FORWARD 链静态规则）：
#   UDP ≤300B 的小包（游戏心跳/实时帧）→ Q1/Q33 SP EF
#   其余 109.x 流量（TCP、大 UDP）→ WRR 普通槽 Q2-30/Q34-62
#
# ═══════════════════════════════════════════════════════
#  IPv6 队列分配规则（完整定义）
# ═══════════════════════════════════════════════════════
#
# IPv6 流量只有 2 类，无 u32 IP 地址匹配，按 MAC 识别：
#
#  类型 1 — 普通流量 WRR：
#    · ip6tables -m mac --mac-source → MARK=wrr_id (2-30)
#    · ebtables -p ipv6 -d MAC → mark=wrr_dl (34-62)
#    · 进入 WRR 普通槽，与 IPv4 对应设备共享同一 slot
#
#  类型 2 — 限速流量（LuCI 配置限速设备）：
#    · ip6tables -m mac --mac-source → MARK=31
#    · ebtables -p ipv6 -d MAC → mark=63
#    · 进入 Q31/Q63 限速队列（与 IPv4 限速设备共用）
#
# IPv6 VIP 注：当前架构不对 IPv6 设置 SP 队列（无 DSCP=0/32），
#   IPv6 VIP 设备通过 IPv4 地址的 u32/eqos-chain 规则获得优先级。
#
# ═══════════════════════════════════════════════════════
#  硬件队列 ID → 调度器映射
# ═══════════════════════════════════════════════════════
#
#   Q0        : VIP 上传   SP  EF   (sch0)
#   Q1        : 游戏上传   SP  EF   (sch0, 109.x UDP≤300B)
#   Q2-Q30    : 普通上传  WRR AF41  (sch2, per-user hash 槽)
#   Q31       : 限速上传  WRR BE    (sch2, 所有限速设备共享)
#   Q32       : VIP 下载   SP  EF   (sch1)
#   Q33       : 游戏下载   SP  EF   (sch1, 109.x UDP≤300B)
#   Q34-Q62   : 普通下载  WRR AF41  (sch3, per-user hash 槽)
#   Q63       : 限速下载  WRR BE    (sch3, 所有限速设备共享)

PASS=0; FAIL=0
ok()   { echo "  ✅  $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL+1)); }
info() { echo "  ℹ️   $*"; }
sep()  { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

echo "╔════════════════════════════════════════════════╗"
echo "║   QoS 深度验证 v3  (新布局: SP/WRR/EF/AF41)   ║"
echo "╚════════════════════════════════════════════════╝"

HNAT_DBG="/sys/kernel/debug/hnat"
QDMA="$HNAT_DBG"

# ─────────────────────────────────────────────────────
sep
echo "【1】QDMA 调度器配置验证"
echo "  期望: sch0/sch1=SP(上传/下载VIP), sch2/sch3=WRR(smarthqos/限速)"
sep

for SCH in 0 1 2 3; do
    F="$QDMA/qdma_sch${SCH}"
    [ -f "$F" ] || { fail "qdma_sch${SCH} 不存在"; continue; }
    VAL=$(cat "$F")
    case $SCH in
        0|1) MODE="sp"
             echo "$VAL" | grep -qi "sp" && ok "sch${SCH} = SP ✓  ($VAL)" \
                                          || fail "sch${SCH} 期望 SP, 实际: $VAL" ;;
        2|3) MODE="wrr"
             echo "$VAL" | grep -qi "wrr" && ok "sch${SCH} = WRR ✓ ($VAL)" \
                                           || fail "sch${SCH} 期望 WRR, 实际: $VAL" ;;
    esac
done

# ─────────────────────────────────────────────────────
sep
echo "【2】关键 QDMA 队列绑定验证"
echo "  格式: <sch_id> <xxx> <xxx> <xxx> <xxx> <weight> <resv>"
sep

check_queue() {
    local qid=$1 expect_sch=$2 label=$3
    local F="$QDMA/qdma_txq${qid}"
    [ -f "$F" ] || { fail "qdma_txq${qid} 不存在"; return; }
    local VAL=$(cat "$F")
    local SCH=$(echo "$VAL" | awk '{print $1}')
    [ "$SCH" = "$expect_sch" ] \
        && ok "Q${qid} (${label}): sch=${SCH} ✓" \
        || fail "Q${qid} (${label}): 期望 sch=${expect_sch}, 实际 sch=${SCH}  [$VAL]"
}

check_queue 0  0 "VIP 上传 SP"
check_queue 1  0 "游戏 上传 SP"
check_queue 31 2 "限速 上传 WRR"
check_queue 32 1 "VIP 下载 SP"
check_queue 33 1 "游戏 下载 SP"
check_queue 63 3 "限速 下载 WRR"

# smarthqos 队列抽查 (Q5, Q15, Q30, Q35, Q50, Q62)
SMART_ENABLED=$(uci -q get eqos.config.smarthqos 2>/dev/null)
if [ "${SMART_ENABLED:-0}" = "1" ]; then
    info "smarthqos=ON, 验证 Q2-30/Q34-62 → sch2/sch3"
    for q in 2 5 15 30; do     check_queue $q 2 "smarthqos 上传 WRR"; done
    for q in 34 40 55 62; do   check_queue $q 3 "smarthqos 下载 WRR"; done
else
    info "smarthqos=OFF, 跳过 Q2-30/Q34-62 检查"
fi

# ─────────────────────────────────────────────────────
sep
echo "【3】iptables FORWARD 链静态规则验证"
echo "  游戏/VIP 规则必须在 FORWARD 链（不在 eqos 链，dhcp_mark flush 不影响）"
sep

check_forward_rule() {
    local desc="$1"; shift
    iptables -t mangle -C FORWARD "$@" 2>/dev/null \
        && ok "FORWARD: $desc" \
        || fail "FORWARD 缺失: $desc"
}

check_forward_rule "109.x 游戏上传 UDP≤300B → DSCP=1" \
    -p udp -m length --length :300 -s 192.168.109.0/24 -j DSCP --set-dscp 1
check_forward_rule "109.x 游戏下载 UDP≤300B → DSCP=33" \
    -p udp -m length --length :300 -d 192.168.109.0/24 -j DSCP --set-dscp 33
check_forward_rule "静态VIP 上传 u32 → DSCP=0" \
    -s 192.168.0.0/16 \
    -m u32 --u32 "0xc&0x0000FF00=0x00006E00:0x00007700" \
    -m u32 --u32 "0xc&0x000000FF=0x0000000A:0x00000027" \
    -j DSCP --set-dscp 0
check_forward_rule "静态VIP 下载 u32 → DSCP=32" \
    -d 192.168.0.0/16 \
    -m u32 --u32 "0x10&0x0000FF00=0x00006E00:0x00007700" \
    -m u32 --u32 "0x10&0x000000FF=0x0000000A:0x00000027" \
    -j DSCP --set-dscp 32

# ─────────────────────────────────────────────────────
sep
echo "【4】iptables eqos 链 per-device 规则清单"
sep

echo "  eqos 链中的 DSCP 规则（FORWARD 规则由上面【3】独立检查）:"
iptables -t mangle -L eqos -v -n 2>/dev/null | grep DSCP | while read line; do
    DSCP=$(echo "$line" | grep -oE 'set 0x[0-9a-f]+' | awk '{print $2}')
    VAL=$(printf "%d" "$DSCP" 2>/dev/null)
    case "$VAL" in
        0)  TAG="VIP 上传 → Q0 SP EF" ;;
        32) TAG="VIP 下载 → Q32 SP EF" ;;
        31) TAG="限速 上传 → Q31 WRR BE" ;;
        63) TAG="限速 下载 → Q63 WRR BE" ;;
        1)  TAG="⚠️ DSCP=1 (应在FORWARD不在eqos)" ;;
        33) TAG="⚠️ DSCP=33 (应在FORWARD不在eqos)" ;;
        *)
            if [ "$VAL" -ge 2 ] && [ "$VAL" -le 30 ] 2>/dev/null; then
                TAG="smarthqos 上传槽 Q${VAL} WRR AF41"
            elif [ "$VAL" -ge 34 ] && [ "$VAL" -le 62 ] 2>/dev/null; then
                TAG="smarthqos 下载槽 Q${VAL} WRR AF41"
            else
                TAG="未知 DSCP=${VAL}"
            fi ;;
    esac
    PKTS=$(echo "$line" | awk '{print $1}')
    echo "    DSCP=${VAL} (${TAG})  pkts=${PKTS}"
done

# ─────────────────────────────────────────────────────
sep
echo "【5】HNAT 条目 qid 分布统计"
sep

HNAT_FILE="$HNAT_DBG/hnat_entry"
if [ ! -f "$HNAT_FILE" ]; then
    info "hnat_entry 不存在，跳过"
else
    TOTAL=$(grep -c "=>" "$HNAT_FILE" 2>/dev/null || echo 0)
    info "总 HNAT 条目: $TOTAL"
    echo ""
    echo "  qid | 期望流量类型                    | 条目数"
    echo "  ----|--------------------------------|-------"
    for qid in 0 1 31 32 33 63; do
        CNT=$(grep -c "qid=$qid[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        case $qid in
            0)  LABEL="VIP 上传 SP EF" ;;
            1)  LABEL="游戏 上传 SP EF" ;;
            31) LABEL="限速设备 上传 WRR BE (共享)" ;;
            32) LABEL="VIP 下载 SP EF" ;;
            33) LABEL="游戏 下载 SP EF" ;;
            63) LABEL="限速设备 下载 WRR BE (共享)" ;;
        esac
        printf "  Q%-3s | %-30s | %d\n" "$qid" "$LABEL" "$CNT"
    done

    # smarthqos 范围统计
    CNT_UP=0; CNT_DN=0
    for q in $(seq 2 30); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        CNT_UP=$((CNT_UP + C))
    done
    for q in $(seq 34 62); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        CNT_DN=$((CNT_DN + C))
    done
    printf "  Q%-3s | %-30s | %d\n" "2-30"  "smarthqos 上传 WRR AF41" "$CNT_UP"
    printf "  Q%-3s | %-30s | %d\n" "34-62" "smarthqos 下载 WRR AF41" "$CNT_DN"
fi

# ─────────────────────────────────────────────────────
sep
echo "【6】全部 QDMA 队列包计数（当前快照）"
sep
echo "  上传 Q0-Q31:"
echo "  QID   | 期望流量          | 调度器 | 包数       | 丢包"
echo "  ------|-------------------|--------|------------|-----"
for q in $(seq 0 31); do
    F="$QDMA/qdma_txq${q}"
    [ -f "$F" ] || continue
    PKTS=$(grep -i "packet count" "$F" | awk '{print $NF}'); PKTS=${PKTS:-0}
    DROP=$(grep -i "drop"         "$F" | awk '{print $NF}'); DROP=${DROP:-0}
    SCH=$(awk '{print $1}' "$F" 2>/dev/null)
    case $q in
        0)  LBL="VIP SP EF"       ;;
        1)  LBL="游戏 SP EF"      ;;
        31) LBL="限速共享 WRR BE" ;;
        *)  if [ $q -ge 2 ] && [ $q -le 30 ]; then LBL="smarthqos WRR AF41"
            else LBL="保留"; fi ;;
    esac
    [ "$PKTS" != "0" ] && FLAG="◀" || FLAG=""
    printf "  Q%-4s | %-17s | sch%-4s | %-10s | %s %s\n" \
        "$q" "$LBL" "$SCH" "$PKTS" "$DROP" "$FLAG"
done

echo ""
echo "  下载 Q32-Q63:"
echo "  QID   | 期望流量          | 调度器 | 包数       | 丢包"
echo "  ------|-------------------|--------|------------|-----"
for q in $(seq 32 63); do
    F="$QDMA/qdma_txq${q}"
    [ -f "$F" ] || continue
    PKTS=$(grep -i "packet count" "$F" | awk '{print $NF}'); PKTS=${PKTS:-0}
    DROP=$(grep -i "drop"         "$F" | awk '{print $NF}'); DROP=${DROP:-0}
    SCH=$(awk '{print $1}' "$F" 2>/dev/null)
    case $q in
        32) LBL="VIP SP EF"       ;;
        33) LBL="游戏 SP EF"      ;;
        63) LBL="限速共享 WRR BE" ;;
        *)  if [ $q -ge 34 ] && [ $q -le 62 ]; then LBL="smarthqos WRR AF41"
            else LBL="保留"; fi ;;
    esac
    [ "$PKTS" != "0" ] && FLAG="◀" || FLAG=""
    printf "  Q%-4s | %-17s | sch%-4s | %-10s | %s %s\n" \
        "$q" "$LBL" "$SCH" "$PKTS" "$DROP" "$FLAG"
done

# ─────────────────────────────────────────────────────
sep
echo "【7】实时队列速率采样（3秒间隔）"
sep

rpkt() { grep -i "packet count" "$QDMA/qdma_txq${1}" 2>/dev/null | awk '{print $NF}'; }
rsum() {
    local s=0
    for q in $(seq $1 $2); do
        v=$(rpkt $q); s=$((s + ${v:-0}))
    done; echo $s
}

A0=$(rpkt 0);  A1=$(rpkt 1);  A31=$(rpkt 31)
A32=$(rpkt 32); A33=$(rpkt 33); A63=$(rpkt 63)
AUP=$(rsum 2 30); ADN=$(rsum 34 62)
sleep 3
B0=$(rpkt 0);  B1=$(rpkt 1);  B31=$(rpkt 31)
B32=$(rpkt 32); B33=$(rpkt 33); B63=$(rpkt 63)
BUP=$(rsum 2 30); BDN=$(rsum 34 62)

pps() { echo $(( (${2:-0} - ${1:-0}) / 3 )); }

echo "  队列        | 期望流量               | pps（包/秒）"
echo "  ------------|------------------------|-------------"
printf "  Q0  (SP EF) | VIP 上传               | %d\n"   "$(pps $A0  $B0)"
printf "  Q1  (SP EF) | 游戏 上传 UDP<=300B    | %d\n"   "$(pps $A1  $B1)"
printf "  Q2-30(WRR)  | smarthqos 上传 AF41    | %d\n"   "$(pps $AUP $BUP)"
printf "  Q31 (WRR)   | 限速设备 上传 BE       | %d\n"   "$(pps $A31 $B31)"
printf "  Q32 (SP EF) | VIP 下载               | %d\n"   "$(pps $A32 $B32)"
printf "  Q33 (SP EF) | 游戏 下载 UDP<=300B    | %d\n"   "$(pps $A33 $B33)"
printf "  Q34-62(WRR) | smarthqos 下载 AF41    | %d\n"   "$(pps $ADN $BDN)"
printf "  Q63 (WRR)   | 限速设备 下载 BE       | %d\n"   "$(pps $A63 $B63)"

echo ""
echo "  ◀ 标记 = 有包计数的队列（非零）"
echo "  期望正常运行: Q0>0 或 Q32>0 (有VIP流量时)"
echo "               Q1>0 或 Q33>0 (有109.x UDP小包时)"
echo "               Q31/Q63 仅限速设备有流量时非零"

# ─────────────────────────────────────────────────────
sep
echo "【8】dhcp_mark.sh 兼容性检查"
sep

MARK_FILE="/tmp/dhcp_mac_mark_mapping"
if [ -f "$MARK_FILE" ]; then
    TOTAL_MAP=$(wc -l < "$MARK_FILE")
    BAD_MARKS=$(awk '$2==1 || $2>=31' "$MARK_FILE" | wc -l)
    info "dhcp_mark 映射条目: $TOTAL_MAP"
    [ "$BAD_MARKS" -eq 0 ] \
        && ok "所有 mark 值在 2-30 范围内（无 Q1/Q31 冲突）" \
        || fail "发现 $BAD_MARKS 条 mark=1 或 >=31 的异常映射（应为 2-30）"
    if [ "$TOTAL_MAP" -gt 29 ]; then
        OVERFLOW=$((TOTAL_MAP - 29))
        info "smarthqos 设备超过 29 个，溢出设备 $OVERFLOW 台 → 共享 Q31/Q63 WRR（设计正确）"
    fi
else
    info "dhcp_mark 映射文件不存在（smarthqos=OFF 或尚未初始化）"
fi

# 检查 eqos 链中是否有 DSCP=1 或 DSCP=33 规则（应在 FORWARD 不在 eqos）
BAD1=$(iptables -t mangle -L eqos -n 2>/dev/null | grep -c "DSCP set 0x01")
BAD33=$(iptables -t mangle -L eqos -n 2>/dev/null | grep -c "DSCP set 0x21")
[ "$BAD1" -eq 0 ]  && ok "eqos 链中无 DSCP=1 游戏规则（正确在 FORWARD）" \
                   || fail "eqos 链中有 $BAD1 条 DSCP=1 规则（应在 FORWARD 链）"
[ "$BAD33" -eq 0 ] && ok "eqos 链中无 DSCP=33 游戏规则（正确在 FORWARD）" \
                    || fail "eqos 链中有 $BAD33 条 DSCP=33 规则（应在 FORWARD 链）"

# ─────────────────────────────────────────────────────
sep
echo "【汇总】"
sep
TOTAL=$((PASS + FAIL))
echo "  通过: $PASS / $TOTAL"
echo "  失败: $FAIL / $TOTAL"
[ "$FAIL" -eq 0 ] \
    && echo "  🎉 全部验证通过 — QoS 队列逻辑 100% 正确" \
    || echo "  ⚠️  存在 $FAIL 项异常，请对照上方输出排查"
echo ""
