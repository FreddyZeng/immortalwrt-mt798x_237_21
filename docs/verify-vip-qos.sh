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

    # HNAT 条目字段结构 (以空格分隔):
    # $1=NAPT(x):  $2=qid(y):  $3=SRC:port->DST:port  $4==>  $5=NSRC:port->NDST:port
    # 上传(LAN→WAN): $3 的第一个 IP 是内网设备 IP
    # 下载(WAN→LAN): $5 的第二个 IP (-> 后) 是内网设备 IP
    # 使用 $3/$5 字段索引，完全兼容 BusyBox awk

    # ---- 真实 VIP: 第三段 110-119, 第四段 10-39 ----
    echo "━━━ ✅ 110-119 真实 VIP (第四段 .10-.39) ━━━"
    echo "  ↑ 上传 (LAN→WAN):"
    echo "$ALL" | awk '{
        split($3,fw,"->"); split(fw[1],ip,":"); split(ip[1],oct,".")
        o3=oct[3]+0; o4=oct[4]+0
        if(o3>=110&&o3<=119&&o4>=10&&o4<=39) print "    "$0
    }' | head -5
    echo "  ↓ 下载 (WAN→LAN):"
    echo "$ALL" | awk '{
        split($5,fw,"->"); split(fw[2],ip,":"); split(ip[1],oct,".")
        o3=oct[3]+0; o4=oct[4]+0
        if(o3>=110&&o3<=119&&o4>=10&&o4<=39) print "    "$0
    }' | head -5
    VIP_UP=$(echo "$ALL" | awk '{split($3,fw,"->");split(fw[1],ip,":");split(ip[1],oct,".");o3=oct[3]+0;o4=oct[4]+0;if(o3>=110&&o3<=119&&o4>=10&&o4<=39)c++}END{print c+0}')
    VIP_DN=$(echo "$ALL" | awk '{split($5,fw,"->");split(fw[2],ip,":");split(ip[1],oct,".");o3=oct[3]+0;o4=oct[4]+0;if(o3>=110&&o3<=119&&o4>=10&&o4<=39)c++}END{print c+0}')
    echo "  (上传 $VIP_UP 条 / 下载 $VIP_DN 条，应全为 qid(0))"
    echo ""

    # ---- 110-119 非 VIP: 第三段 110-119, 第四段不在 10-39 ----
    echo "━━━ ⚠️  110-119 非 VIP (第四段 .40 以上) ━━━"
    echo "  ↑ 上传 (LAN→WAN):"
    echo "$ALL" | awk '{
        split($3,fw,"->"); split(fw[1],ip,":"); split(ip[1],oct,".")
        o3=oct[3]+0; o4=oct[4]+0
        if(o3>=110&&o3<=119&&!(o4>=10&&o4<=39)) print "    "$0
    }' | head -5
    echo "  ↓ 下载 (WAN→LAN):"
    echo "$ALL" | awk '{
        split($5,fw,"->"); split(fw[2],ip,":"); split(ip[1],oct,".")
        o3=oct[3]+0; o4=oct[4]+0
        if(o3>=110&&o3<=119&&!(o4>=10&&o4<=39)) print "    "$0
    }' | head -5
    NV_UP=$(echo "$ALL" | awk '{split($3,fw,"->");split(fw[1],ip,":");split(ip[1],oct,".");o3=oct[3]+0;o4=oct[4]+0;if(o3>=110&&o3<=119&&!(o4>=10&&o4<=39))c++}END{print c+0}')
    NV_DN=$(echo "$ALL" | awk '{split($5,fw,"->");split(fw[2],ip,":");split(ip[1],oct,".");o3=oct[3]+0;o4=oct[4]+0;if(o3>=110&&o3<=119&&!(o4>=10&&o4<=39))c++}END{print c+0}')
    echo "  (上传 $NV_UP 条 / 下载 $NV_DN 条，qid 应非 0)"
    echo ""

    # ---- 109 游戏加速区 ----
    echo "━━━ 🎮 109 游戏加速区 (UDP≤300B → qid(0)) ━━━"
    echo "  ↑ 上传 (LAN→WAN):"
    echo "$ALL" | awk '{
        split($3,fw,"->"); split(fw[1],ip,":"); split(ip[1],oct,".")
        if(oct[3]+0==109) print "    "$0
    }' | head -5
    echo "  ↓ 下载 (WAN→LAN):"
    echo "$ALL" | awk '{
        split($5,fw,"->"); split(fw[2],ip,":"); split(ip[1],oct,".")
        if(oct[3]+0==109) print "    "$0
    }' | head -5
    N109_UP=$(echo "$ALL" | awk '{split($3,fw,"->");split(fw[1],ip,":");split(ip[1],oct,".");if(oct[3]+0==109)c++}END{print c+0}')
    N109_DN=$(echo "$ALL" | awk '{split($5,fw,"->");split(fw[2],ip,":");split(ip[1],oct,".");if(oct[3]+0==109)c++}END{print c+0}')
    echo "  (上传 $N109_UP 条 / 下载 $N109_DN 条)"
fi
echo ""

# ==========================================
# 2. QDMA 队列对比（VIP SP 队列 vs 默认队列）
# ==========================================
echo "【2】QDMA 硬件队列统计"
echo "--------------------------------------------"
echo "━━━ VIP 专属队列 (Strict Priority) ━━━"
for qid in 0 32; do
    FILE="/sys/kernel/debug/hnat/qdma_txq${qid}"
    if [ -f "$FILE" ]; then
        PKTS=$(grep "packet count" "$FILE" | awk '{print $3}')
        DROP=$(grep "packet drop" "$FILE" | awk '{print $3}')
        DIR=$([ "$qid" = "0" ] && echo "下行 WAN→LAN" || echo "上行 LAN→WAN")
        echo "  Queue $qid ($DIR): $PKTS 包, 丢包 $DROP"
    fi
done

echo ""
echo "━━━ 普通队列 (对比基准) ━━━"
for qid in 1 2 3; do
    FILE="/sys/kernel/debug/hnat/qdma_txq${qid}"
    if [ -f "$FILE" ]; then
        PKTS=$(grep "packet count" "$FILE" | awk '{print $3}')
        echo "  Queue $qid: $PKTS 包"
    fi
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
Q0_A=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq0 2>/dev/null | awk '{print $3}')
Q32_A=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq32 2>/dev/null | awk '{print $3}')
CAKE_SENT_A=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '/^ Sent /{print $2}')

sleep 3

Q0_B=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq0 2>/dev/null | awk '{print $3}')
Q32_B=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq32 2>/dev/null | awk '{print $3}')
CAKE_SENT_B=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '/^ Sent /{print $2}')

calc_pps() {
    A=$1 B=$2
    [ -n "$A" ] && [ -n "$B" ] && [ "$B" -ge "$A" ] 2>/dev/null \
        && echo $(( (B - A) / 3 )) || echo "N/A"
}

Q0_RATE=$(calc_pps "$Q0_A" "$Q0_B")
Q32_RATE=$(calc_pps "$Q32_A" "$Q32_B")
CAKE_RATE=$(calc_pps "$CAKE_SENT_A" "$CAKE_SENT_B")

echo "  硬件加速 VIP 下行 (Queue 0):  ${Q0_RATE} 包/秒"
echo "  硬件加速 VIP 上行 (Queue 32): ${Q32_RATE} 包/秒"
if [ -n "$CAKE_IF" ]; then
    if [ "$CAKE_RATE" = "N/A" ]; then
        echo "  软件 SQM (CAKE) 吞吐:         N/A"
    else
        echo "  软件 SQM (CAKE) 吞吐:         $(( CAKE_RATE / 1024 )) KB/秒"
    fi
fi
echo ""
echo "  → Queue 0/32 > 0 = VIP 硬件加速正在工作"
echo "  → CAKE > 0       = HNAT 未命中流量走软件路径"
echo "============================================"
