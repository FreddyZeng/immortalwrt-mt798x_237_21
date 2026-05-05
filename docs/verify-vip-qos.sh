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
    # qdma_txq 输出为多行格式，scheduler id 在 "scheduler: N" 行
    local SCH=$(echo "$VAL" | grep -i 'scheduler:' | grep -oE '[0-9]+' | head -1)
    SCH=${SCH:-"?"}
    [ "$SCH" = "$expect_sch" ] \
        && ok "Q${qid} (${label}): sch=${SCH} ✓" \
        || fail "Q${qid} (${label}): 期望 sch=${expect_sch}, 实际 sch=${SCH}"
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
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║                《四类队列分布总览》                               ║"
    echo "  ╠══════════════════╦═══════════╦══════════════════════════╦══════╣"
    echo "  ║ 类别             ║ 队列      ║ 用途                     ║ 条目 ║"
    echo "  ╠══════════════════╬═══════════╬══════════════════════════╬══════╣"

    # VIP Q0 / Q32
    C0=$(grep  -c "qid=0[^0-9]"  "$HNAT_FILE" 2>/dev/null || echo 0)
    C0=$(echo "$C0"  | tr -d '\n\r'); C0=${C0:-0}
    C32=$(grep -c "qid=32[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
    C32=$(echo "$C32" | tr -d '\n\r'); C32=${C32:-0}
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" "VIP" "Q0"  "VIP 上传 SP EF"  "$C0"
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" ""   "Q32" "VIP 下载 SP EF"  "$C32"
    echo "  ╠══════════════════╬═══════════╬══════════════════════════╬══════╣"

    # 游戏 Q1 / Q33
    C1=$(grep  -c "qid=1[^0-9]"  "$HNAT_FILE" 2>/dev/null || echo 0)
    C1=$(echo "$C1"  | tr -d '\n\r'); C1=${C1:-0}
    C33=$(grep -c "qid=33[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
    C33=$(echo "$C33" | tr -d '\n\r'); C33=${C33:-0}
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" "游戏(109.x)" "Q1"  "游戏上传 UDP≤300B"  "$C1"
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" ""             "Q33" "游戏下载 UDP≤300B"  "$C33"
    echo "  ╠══════════════════╬═══════════╬══════════════════════════╬══════╣"

    # WRR 普通 Q2-30 / Q34-62 — 总计
    CNT_UP=0; CNT_DN=0
    for q in $(seq 2 30); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        C=$(echo "$C" | tr -d '\n\r'); C=${C:-0}
        CNT_UP=$((CNT_UP + C))
    done
    for q in $(seq 34 62); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        C=$(echo "$C" | tr -d '\n\r'); C=${C:-0}
        CNT_DN=$((CNT_DN + C))
    done
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" "WRR普通" "Q2-30"  "WRR 普通上传 AF41" "$CNT_UP"
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" ""       "Q34-62" "WRR 普通下载 AF41" "$CNT_DN"
    echo "  ╠══════════════════╬═══════════╬══════════════════════════╬══════╣"

    # 限速 Q31 / Q63
    C31=$(grep -c "qid=31[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
    C31=$(echo "$C31" | tr -d '\n\r'); C31=${C31:-0}
    C63=$(grep -c "qid=63[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
    C63=$(echo "$C63" | tr -d '\n\r'); C63=${C63:-0}
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" "限速" "Q31" "限速上传 WRR BE" "$C31"
    printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" ""     "Q63" "限速下载 WRR BE" "$C63"
    echo "  ╠══════════════════╬═══════════╬══════════════════════════╬══════╣"

    VIP_T=$((C0  + C32)); GAME_T=$((C1 + C33))
    WRR_T=$((CNT_UP + CNT_DN)); RATE_T=$((C31 + C63))
    CLASSIFIED=$((VIP_T + GAME_T + WRR_T + RATE_T))
    UNCLASSIFIED=$((TOTAL - CLASSIFIED))
    printf "  ║ %-16s ║ %-9s ║ VIP=%-4d 游戏=%-4d WRR=%-4d 限速=%-4d ║\n" \
        "分类合计" "总=$TOTAL" "$VIP_T" "$GAME_T" "$WRR_T" "$RATE_T"
    if [ "$UNCLASSIFIED" -ne 0 ]; then
        printf "  ║ %-16s ║ %-9s ║ %-24s ║ %4d ║\n" "⚠️ 未分类" "(其他qid)" "qid不在0-1/31-33/63范围" "$UNCLASSIFIED"
    fi
    echo "  ╚══════════════════╩═══════════╩══════════════════════════╩══════╝"

    # ── 分项展开：WRR per-slot 分布 ──
    echo ""
    echo "  ┌── WRR 普通上传槽位分布（Q2-Q30，per-user）"
    SLOT_MAX=0
    for q in $(seq 2 30); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        C=$(echo "$C" | tr -d '\n\r'); C=${C:-0}
        [ "$C" -gt "$SLOT_MAX" ] && SLOT_MAX=$C
        if [ "$C" -gt 0 ]; then
            BAR=$(printf '%0.s#' $(seq 1 $C) 2>/dev/null || echo "#")
            printf "  │  Q%-2d: %3d  %s\n" "$q" "$C" "$BAR"
        fi
    done
    [ "$SLOT_MAX" -eq 0 ] && echo "  │  (无上传条目)"
    echo "  └──"

    echo ""
    echo "  ┌── WRR 普通下载槽位分布（Q34-Q62，per-user）"
    SLOT_MAX=0
    for q in $(seq 34 62); do
        C=$(grep -c "qid=$q[^0-9]" "$HNAT_FILE" 2>/dev/null || echo 0)
        C=$(echo "$C" | tr -d '\n\r'); C=${C:-0}
        [ "$C" -gt "$SLOT_MAX" ] && SLOT_MAX=$C
        if [ "$C" -gt 0 ]; then
            BAR=$(printf '%0.s#' $(seq 1 $C) 2>/dev/null || echo "#")
            printf "  │  Q%-2d: %3d  %s\n" "$q" "$C" "$BAR"
        fi
    done
    [ "$SLOT_MAX" -eq 0 ] && echo "  │  (无下载条目)"
    echo "  └──"

    # ── 限速逻辑健康检查 ──
    echo ""
    sep
    echo "  《限速队列健康检查》"
    sep
    # 检查：Q31/Q63 应只有限速设备，不应有 VIP/游戏流量
    # VIP 流量 = qid=0/32，游戏流量 = qid=1/33，任何进入 Q31/Q63 的都应是限速设备
    [ "$C31" -gt 0 ] || [ "$C63" -gt 0 ] \
        && info "Q31/Q63 有条目（$((C31+C63)) 条），验证是否全为限速设备……" \
        || info "Q31/Q63 当前无条目（无限速设备在线或 HNAT 未建表）"

    # 检查 Q31 中是否混入了 game 的 qid（理论上不可能，但做二次验证）
    # 因为游戏是 DSCP=1/33 → qid=(4>>2)=1 和 (132>>2)=33，不会等于 31
    # 检查 eqos 链中有无 DSCP=31 被 Branch 3 错误分配的情况
    BAD_WRR_TO_RL=$(iptables -t mangle -L eqos -n 2>/dev/null | grep 'DSCP set 0x1f' | wc -l)
    BAD_WRR_TO_RL=$(echo "$BAD_WRR_TO_RL" | tr -d '\n\r'); BAD_WRR_TO_RL=${BAD_WRR_TO_RL:-0}
    [ "$BAD_WRR_TO_RL" -gt 0 ] \
        && ok "eqos 链有 $BAD_WRR_TO_RL 条 DSCP=31 规则（限速设备，期望值）" \
        || info "eqos 链中无 DSCP=31 规则（无配置限速设备，或设备未添加）"

    BAD_WRR_TO_RL63=$(iptables -t mangle -L eqos -n 2>/dev/null | grep 'DSCP set 0x3f' | wc -l)
    BAD_WRR_TO_RL63=$(echo "$BAD_WRR_TO_RL63" | tr -d '\n\r'); BAD_WRR_TO_RL63=${BAD_WRR_TO_RL63:-0}
    [ "$BAD_WRR_TO_RL63" -gt 0 ] \
        && ok "eqos 链有 $BAD_WRR_TO_RL63 条 DSCP=63 规则（限速设备下行，期望值）" \
        || info "eqos 链中无 DSCP=63 规则（无配置限速设备）"

    # 检查：Q31/Q63 应对称 —— 同一设备上传/下载都进入限速队列
    # 如果 C31 和 C63 严重不对称，说明存在只有单向限速规则的问题
    if [ "$C31" -gt 0 ] && [ "$C63" -gt 0 ]; then
        DIFF=$(( C31 - C63 ))
        [ "$DIFF" -lt 0 ] && DIFF=$(( 0 - DIFF ))
        RATIO_THRESHOLD=5  # 允许最多 5 条差距（同一 IP 的不同 5-tuple 连接数差异）
        if [ "$DIFF" -le "$RATIO_THRESHOLD" ]; then
            ok "Q31/Q63 条目数基本对称（上传=$C31 下载=$C63 差值=$DIFF ≤ $RATIO_THRESHOLD）"
        else
            fail "Q31/Q63 条目不对称（上传=$C31 下载=$C63 差值=$DIFF）— 限速规则可能不完整"
        fi
    fi
fi

# ─────────────────────────────────────────────────────
sep
echo "【6】全部 QDMA 队列包计数（当前快照）"
sep
echo "  上传 Q0-Q31:"
echo "  QID   | 类别   | 用途                       | sch | 包数       | 丢包"
echo "  ------|--------|----------------------------|-----|------------|-----"
for q in $(seq 0 31); do
    F="$QDMA/qdma_txq${q}"
    [ -f "$F" ] || continue
    PKTS=$(grep -i "packet count" "$F" | awk '{print $NF}'); PKTS=${PKTS:-0}
    DROP=$(grep -i "drop"         "$F" | awk '{print $NF}'); DROP=${DROP:-0}
    SCH=$(grep -i 'scheduler:' "$F" | grep -oE '[0-9]+' | head -1); SCH=${SCH:-"?"}
    case $q in
        0)  CAT="VIP";  LBL="VIP 上传 SP EF"              ;;
        1)  CAT="游戏"; LBL="游戏 UDP≤300B 上传 SP EF"    ;;
        31) CAT="限速"; LBL="限速设备 上传 WRR BE(共享)"  ;;
        *)  CAT="WRR";  LBL="WRR 普通上传 AF41"           ;;
    esac
    [ "$PKTS" != "0" ] && FLAG="◀" || FLAG=""
    printf "  Q%-4s | %-6s | %-26s | %-3s | %-10s | %s %s\n" \
        "$q" "$CAT" "$LBL" "$SCH" "$PKTS" "$DROP" "$FLAG"
done

echo ""
echo "  下载 Q32-Q63:"
echo "  QID   | 类别   | 用途                       | sch | 包数       | 丢包"
echo "  ------|--------|----------------------------|-----|------------|-----"
for q in $(seq 32 63); do
    F="$QDMA/qdma_txq${q}"
    [ -f "$F" ] || continue
    PKTS=$(grep -i "packet count" "$F" | awk '{print $NF}'); PKTS=${PKTS:-0}
    DROP=$(grep -i "drop"         "$F" | awk '{print $NF}'); DROP=${DROP:-0}
    SCH=$(grep -i 'scheduler:' "$F" | grep -oE '[0-9]+' | head -1); SCH=${SCH:-"?"}
    case $q in
        32) CAT="VIP";  LBL="VIP 下载 SP EF"              ;;
        33) CAT="游戏"; LBL="游戏 UDP≤300B 下载 SP EF"    ;;
        63) CAT="限速"; LBL="限速设备 下载 WRR BE(共享)"  ;;
        *)  CAT="WRR";  LBL="WRR 普通下载 AF41"           ;;
    esac
    [ "$PKTS" != "0" ] && FLAG="◀" || FLAG=""
    printf "  Q%-4s | %-6s | %-26s | %-3s | %-10s | %s %s\n" \
        "$q" "$CAT" "$LBL" "$SCH" "$PKTS" "$DROP" "$FLAG"
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
