#!/bin/sh
# VIP QoS 精确验证脚本 v2
# 在路由器上运行: sh /root/speed.sh

echo "============================================"
echo "  VIP QoS 精确验证 v2"
echo "============================================"
echo ""

# ==========================================
# 1. HNAT 条目精确分类
# ==========================================
echo "【1】HNAT 硬件加速条目精确分类"
echo "--------------------------------------------"

HNAT_FILE="/sys/kernel/debug/hnat/hnat_entry"
if [ ! -f "$HNAT_FILE" ]; then
    echo "⚠️  hnat_entry 不存在"
else
    ALL=$(cat "$HNAT_FILE")
    TOTAL=$(echo "$ALL" | wc -l)
    echo "总 HNAT 条目数: $TOTAL"
    echo ""
    echo "  队列说明: dscp_en=true 各流量期望 qid"
    echo "  ┌──────────────┬──────────────────────┬───────────────────────┐"
    echo "  │ 流量类型     │ 上传 LAN→WAN(Q0-Q12) │ 下载 WAN→LAN(Q32-Q44) │"
    echo "  ├──────────────┼──────────────────────┼───────────────────────┤"
    echo "  │ VIP/游戏UDP  │ qid(0)  → Q0  SP     │ qid(32) → Q32 SP      │"
    echo "  │ 普通流量     │ qid(11) → Q11 WRR    │ qid(43) → Q43 WRR     │"
    echo "  └──────────────┴──────────────────────┴───────────────────────┘"
    echo ""

    # 使用高精度 AWK 解析:
    # 1. 过滤掉无 NAT 转换的 LAN-to-LAN 互访流量 (通过判断 $3 和 $5 是否相等)
    # 2. 上传(LAN→WAN): 发生 Source NAT (fw1[1] != fw2[1])，且原始源 IP 是目标 LAN 设备
    # 3. 下载(WAN→LAN): 发生 Destination NAT (fw1[2] != fw2[2])，且转换后目标 IP 是目标 LAN 设备
    get_hnat_entries() {
        local dir=$1
        local type=$2
        echo "$ALL" | awk -v dir="$dir" -v type="$type" '{
            orig = ""; trans = "";
            if ($4 == "=>") { orig = $3; trans = $5; }
            else if ($3 == "=>") { orig = $2; trans = $4; }
            else next;
            
            split(orig, fw1, "->"); split(trans, fw2, "->");
            
            target_ip = "";
            if (dir == "UP" && fw1[1] != fw2[1]) {
                split(fw1[1], ip, ":");
                target_ip = ip[1];
            } else if (dir == "DN" && fw1[2] != fw2[2]) {
                split(fw2[2], ip, ":");
                target_ip = ip[1];
            } else {
                next;
            }
            
            split(target_ip, oct, ".");
            o1 = oct[1]+0; o2 = oct[2]+0; o3 = oct[3]+0; o4 = oct[4]+0;
            
            if (o1 != 192 || o2 != 168) next;
            
            is_vip = (o3 >= 110 && o3 <= 119 && o4 >= 10 && o4 <= 39);
            is_109 = (o3 == 109);
            
            if (type == "VIP" && is_vip) { print "    " $0; }
            else if (type == "109" && is_109) { print "    " $0; }
            else if (type == "NM" && !is_vip && !is_109) { print "    " $0; }
        }'
    }

    # ---- VIP: 192.168.110-119.10-39 ----
    echo "━━━ ✅ VIP 流量 (192.168.110-119.10-39) ━━━"
    echo "  期望: 上传 qid(0)/Q0 SP,  下载 qid(32)/Q32 SP"
    VIP_UP_ENTRIES=$(get_hnat_entries "UP" "VIP")
    VIP_DN_ENTRIES=$(get_hnat_entries "DN" "VIP")
    echo "  ↑ 上传 (LAN→WAN, 源IP在VIP范围):"
    [ -n "$VIP_UP_ENTRIES" ] && echo "$VIP_UP_ENTRIES" | head -5 || echo "    (无)"
    echo "  ↓ 下载 (WAN→LAN, 目标IP在VIP范围):"
    [ -n "$VIP_DN_ENTRIES" ] && echo "$VIP_DN_ENTRIES" | head -5 || echo "    (无)"
    VIP_UP=$(echo "$VIP_UP_ENTRIES" | grep -c "=>")
    VIP_DN=$(echo "$VIP_DN_ENTRIES" | grep -c "=>")
    echo "  (上传 $VIP_UP 条 / 下载 $VIP_DN 条 → 期望 qid(0)/qid(32))"
    echo ""

    # ---- 游戏加速区: 192.168.109.x ----
    echo "━━━ 🎮 游戏加速 (192.168.109.x) ━━━"
    echo "  ⚠️  仅 UDP≤300B 打 DSCP=46 → qid(0)/qid(32) SP"
    echo "  TCP/大包UDP 走普通通道 → qid(11)/qid(43) WRR"
    N109_UP_ENTRIES=$(get_hnat_entries "UP" "109")
    N109_DN_ENTRIES=$(get_hnat_entries "DN" "109")
    echo "  ↑ 上传 (LAN→WAN, 源IP为192.168.109.x):"
    [ -n "$N109_UP_ENTRIES" ] && echo "$N109_UP_ENTRIES" | head -5 || echo "    (无)"
    echo "  ↓ 下载 (WAN→LAN, 目标IP为192.168.109.x):"
    [ -n "$N109_DN_ENTRIES" ] && echo "$N109_DN_ENTRIES" | head -5 || echo "    (无)"
    N109_UP=$(echo "$N109_UP_ENTRIES" | grep -c "=>")
    N109_DN=$(echo "$N109_DN_ENTRIES" | grep -c "=>")
    echo "  (上传 $N109_UP 条 / 下载 $N109_DN 条 → UDP小包期望 qid(0)/qid(32), 其他期望 qid(11)/qid(43))"
    echo ""

    # ---- 普通流量: 192.168 网段, 非 VIP 非 109 ----
    echo "━━━ 📦 普通流量 (其他 192.168.x.x 设备) ━━━"
    echo "  期望: 上传 qid(11)/Q11 WRR, 下载 qid(43)/Q43 WRR"
    NM_UP_ENTRIES=$(get_hnat_entries "UP" "NM")
    NM_DN_ENTRIES=$(get_hnat_entries "DN" "NM")
    echo "  ↑ 上传 (LAN→WAN, 源IP为普通设备):"
    [ -n "$NM_UP_ENTRIES" ] && echo "$NM_UP_ENTRIES" | head -5 || echo "    (无)"
    echo "  ↓ 下载 (WAN→LAN, 目标IP为普通设备):"
    [ -n "$NM_DN_ENTRIES" ] && echo "$NM_DN_ENTRIES" | head -5 || echo "    (无)"
    NM_UP=$(echo "$NM_UP_ENTRIES" | grep -c "=>")
    NM_DN=$(echo "$NM_DN_ENTRIES" | grep -c "=>")
    echo "  (上传 $NM_UP 条 / 下载 $NM_DN 条 → 期望 qid(11)/qid(43))"
fi
echo ""
echo "【2】QDMA 全部硬件队列 (DSCP 映射)"
echo "--------------------------------------------"
echo "  上行 (LAN→WAN) Queue 0-12  [sch0/sch2 上传调度器]:"
echo "  Queue | DSCP | 流量类型           | 包数        | 丢包"
echo "  ------|------|--------------------|-----------|---------"

# 上行队列 Q0-Q12 DSCP 映射 (LAN→WAN, sch0=VIP SP / sch2=普通上传速率限制)
get_up_label() {
    case $1 in
        0)  echo "46     EF    ★VIP/游戏 SP最高   " ;;
        1)  echo "45            SP次高           " ;;
        2)  echo "44            SP              " ;;
        3)  echo "43            SP              " ;;
        4)  echo "42            SP              " ;;
        5)  echo "41            SP              " ;;
        6)  echo "48/56  CS6-7  网络控制 SP      " ;;
        7)  echo "40     CS5    SP              " ;;
        8)  echo "32-39  AF4x   高优视频 WRR     " ;;
        9)  echo "24-31  AF3x   普通视频 WRR     " ;;
        10) echo "16-23  AF2x   网页/应用 WRR    " ;;
        11) echo "0      BE    ★普通流量 WRR    " ;;
        12) echo "8-15   CS1    后台清道夫(低于BE)" ;;
    esac
}
for qid in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
    FILE="/sys/kernel/debug/hnat/qdma_txq${qid}"
    PKTS="N/A"; DROP="N/A"
    if [ -f "$FILE" ]; then
        PKTS=$(grep "packet count" "$FILE" | awk '{print $3}')
        DROP=$(grep "packet drop" "$FILE" | awk '{print $3}')
        [ -z "$PKTS" ] && PKTS="0"
        [ -z "$DROP" ] && DROP="0"
    fi
    LABEL=$(get_up_label $qid)
    printf "  Q%-5s | %s | %-10s | %-5s\n" "$qid" "$LABEL" "$PKTS" "$DROP"
done

echo ""
echo "  下行 (WAN→LAN) Queue 32-44 [sch1/sch3 下载调度器]:"
echo "  Queue | DSCP | 流量类型           | 包数        | 丢包"
echo "  ------|------|--------------------|-----------|---------"

get_dn_label() {
    case $1 in
        32) echo "46     EF    ★VIP/游戏 SP最高   " ;;
        33) echo "45            SP次高           " ;;
        34) echo "44            SP              " ;;
        35) echo "43            SP              " ;;
        36) echo "42            SP              " ;;
        37) echo "41            SP              " ;;
        38) echo "48/56  CS6-7  网络控制 SP      " ;;
        39) echo "40     CS5    SP              " ;;
        40) echo "32-39  AF4x   高优视频 WRR     " ;;
        41) echo "24-31  AF3x   普通视频 WRR     " ;;
        42) echo "16-23  AF2x   网页/应用 WRR    " ;;
        43) echo "0      BE    ★普通流量下行 WRR    " ;;
        44) echo "8-15   CS1    后台清道夫(低于BE)" ;;
    esac
}
for qid in 32 33 34 35 36 37 38 39 40 41 42 43 44; do
    FILE="/sys/kernel/debug/hnat/qdma_txq${qid}"
    PKTS="N/A"; DROP="N/A"
    if [ -f "$FILE" ]; then
        PKTS=$(grep "packet count" "$FILE" | awk '{print $3}')
        DROP=$(grep "packet drop" "$FILE" | awk '{print $3}')
        [ -z "$PKTS" ] && PKTS="0"
        [ -z "$DROP" ] && DROP="0"
    fi
    LABEL=$(get_dn_label $qid)
    printf "  Q%-5s | %s | %-10s | %-5s\n" "$qid" "$LABEL" "$PKTS" "$DROP"
done
echo ""


# ==========================================
# 3. CAKE SQM 分 tin 详细数据
# ==========================================
echo "【3】CAKE SQM Tin 分类统计 (软件路径)"
echo "--------------------------------------------"
CAKE_IF=$(tc qdisc show 2>/dev/null | grep cake | awk '{print $5}' | head -1)
if [ -z "$CAKE_IF" ]; then
    echo "  CAKE 未运行"
else
    echo "接口: $CAKE_IF"
    echo ""
    echo "          Tin0      Tin1      Tin2      Tin3      Tin4      Tin5      Tin6  Tin7(VIP)"
    tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '
    /^  pkts /   { printf "  pkts:   "; for(i=2;i<=NF;i++) printf "%10s", $i; print "" }
    /^  bytes /  {
        printf "  bytes:  "
        for(i=2;i<=NF;i++) {
            b=$i+0
            if(b>=1073741824) s=sprintf("%.1fGB",b/1073741824)
            else if(b>=1048576) s=sprintf("%.1fMB",b/1048576)
            else if(b>=1024) s=sprintf("%.1fKB",b/1024)
            else s=sprintf("%dB",b)
            printf "%10s", s
        }
        print ""
    }
    /^  drops /  { printf "  drops:  "; for(i=2;i<=NF;i++) printf "%10s", $i; print "" }
    /^  interval / { printf "  intrvl: "; for(i=2;i<=NF;i++) printf "%10s", $i; print "" }
    '
    echo ""
    echo "━━━ Tin 7 (VIP专属) vs Tin 2 (默认流量) 对比 ━━━"
    tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '
    /^  pkts /    { t2_p=$4; t7_p=$9 }
    /^  bytes /   { t2_b=$4+0; t7_b=$9+0 }
    /^  drops /   { t2_d=$4; t7_d=$9 }
    /^  interval / { t7_i=$9 }
    END {
        printf "  Tin7 VIP  (interval=%-5s): %s 包 / %.2fMB / %s 丢包\n", t7_i, t7_p, t7_b/1048576, t7_d
        printf "  Tin2 默认 (interval=100ms): %s 包 / %.2fMB / %s 丢包\n", t2_p, t2_b/1048576, t2_d
    }'
fi
echo ""

# ==========================================
# 4. iptables 流量统计
# ==========================================
echo "【4】iptables DSCP 标记命中统计"
echo "--------------------------------------------"
iptables -t mangle -L eqos -v -n 2>/dev/null | awk '
/DSCP/ {
    pkts=$1; bytes=$2
    if ($0 ~ /192\.168\.109/) {
        dir=($0 ~ /0\.0\.0\.0\/0.*192\.168\.109/) ? "109网段下行(UDP≤300B)" : "109网段上行(UDP≤300B)"
        printf "  %-30s %s pkts / %s\n", dir, pkts, bytes
    } else if ($0 ~ /0\.0\.0\.0\/0.*192\.168\.0\.0/) {
        printf "  %-30s %s pkts / %s\n", "VIP 下行(110-119.10-39)", pkts, bytes
    } else if ($0 ~ /192\.168\.0\.0.*0\.0\.0\.0/) {
        printf "  %-30s %s pkts / %s\n", "VIP 上行(110-119.10-39)", pkts, bytes
    }
}'
echo ""

# ==========================================
# 5. 实时吞吐对比（连续2次采样）
# ==========================================
echo "【5】实时吞吐量采样 (3秒间隔)"
echo "--------------------------------------------"
# 读取 QDMA 包计数，重试一次避免 sysfs 瞬间返回空
read_pkts() {
    VAL=$(grep "packet count" "$1" 2>/dev/null | awk '{print $3}')
    [ -z "$VAL" ] && VAL=$(grep "packet count" "$1" 2>/dev/null | awk '{print $3}')
    echo "${VAL:-0}"
}

Q0_A=$(read_pkts /sys/kernel/debug/hnat/qdma_txq0)
Q32_A=$(read_pkts /sys/kernel/debug/hnat/qdma_txq32)
Q11_A=$(read_pkts /sys/kernel/debug/hnat/qdma_txq11)
Q43_A=$(read_pkts /sys/kernel/debug/hnat/qdma_txq43)
CAKE_SENT_A=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '/^ Sent /{print $2}')
CAKE_SENT_A=${CAKE_SENT_A:-0}

sleep 3

Q0_B=$(read_pkts /sys/kernel/debug/hnat/qdma_txq0)
Q32_B=$(read_pkts /sys/kernel/debug/hnat/qdma_txq32)
Q11_B=$(read_pkts /sys/kernel/debug/hnat/qdma_txq11)
Q43_B=$(read_pkts /sys/kernel/debug/hnat/qdma_txq43)
CAKE_SENT_B=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '/^ Sent /{print $2}')
CAKE_SENT_B=${CAKE_SENT_B:-0}

calc_pps() {
    local A=$(echo "$1" | tr -cd '0-9')
    local B=$(echo "$2" | tr -cd '0-9')
    A=${A:-0}
    B=${B:-0}
    local DIFF=$(( B - A ))
    if [ "$DIFF" -lt 0 ]; then
        echo "0"
    else
        echo $(( DIFF / 3 ))
    fi
}

Q0_RATE=$(calc_pps "$Q0_A" "$Q0_B")
Q32_RATE=$(calc_pps "$Q32_A" "$Q32_B")
Q11_RATE=$(calc_pps "$Q11_A" "$Q11_B")
Q43_RATE=$(calc_pps "$Q43_A" "$Q43_B")
CAKE_RATE=$(calc_pps "$CAKE_SENT_A" "$CAKE_SENT_B")

echo "  硬件加速 VIP   上行 (Queue  0, sch0 SP): ${Q0_RATE} 包/秒"
echo "  硬件加速 VIP   下行 (Queue 32, sch1 SP): ${Q32_RATE} 包/秒"
echo "  硬件加速 普通  上行 (Queue 11, sch2 WRR): ${Q11_RATE} 包/秒"
echo "  硬件加速 普通  下行 (Queue 43, sch3 WRR): ${Q43_RATE} 包/秒  ← dscp_en 验证关键"
if [ -n "$CAKE_IF" ]; then
    if [ "$CAKE_RATE" = "N/A" ]; then
        echo "  软件 SQM (CAKE) 吞吐:         N/A"
    else
        echo "  软件 SQM (CAKE) 吞吐:         $(( CAKE_RATE / 1024 )) KB/秒"
    fi
fi
echo ""
echo "  → Queue 0:  上行 VIP SP > 0  = VIP 硬件加速上行正在工作"
echo "  → Queue 32: 下行 VIP SP > 0  = VIP 硬件加速下行正在工作"
echo "  → Queue 11: 上行普通 WRR > 0 = 普通流量上行已分离"
echo "  → Queue 43: 下行普通 WRR > 0 = dscp_en 已生效，下行不再混入 Q11"
echo "  → CAKE > 0  = HNAT 未命中流量走软件路径"
echo "============================================"
