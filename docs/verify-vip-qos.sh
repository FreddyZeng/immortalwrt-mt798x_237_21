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

    # ---- 真正的 VIP: 110-119 网段 AND 第四段 10-39 ----
    echo "━━━ ✅ 真实 VIP 设备 (192.168.110-119.10-39) ━━━"
    echo "$ALL" | awk '
    {
        # 匹配 src IP 192.168.{110-119}.{10-39}
        if (match($0, /192\.168\.1(1[0-9])\.([0-9]+)/, arr)) {
            seg3 = arr[1]+0
            seg4 = arr[2]+0
            if (seg3 >= 10 && seg3 <= 19 && seg4 >= 10 && seg4 <= 39) {
                print $0
            }
        }
    }' | head -10
    VIP_COUNT=$(echo "$ALL" | awk '
    {
        if (match($0, /192\.168\.1(1[0-9])\.([0-9]+)/, arr)) {
            seg3 = arr[1]+0
            seg4 = arr[2]+0
            if (seg3 >= 10 && seg3 <= 19 && seg4 >= 10 && seg4 <= 39) count++
        }
    }
    END{print count+0}')
    echo "(共 $VIP_COUNT 条 VIP 连接)"
    echo ""

    # ---- 110-119 网段但不在 10-39 范围（非 VIP，脚本 v1 的误报）----
    echo "━━━ ⚠️  110-119 网段但不是 VIP (.10-.39 以外) ━━━"
    echo "$ALL" | awk '
    {
        if (match($0, /192\.168\.1(1[0-9])\.([0-9]+)/, arr)) {
            seg3 = arr[1]+0
            seg4 = arr[2]+0
            if (!(seg3 >= 10 && seg3 <= 19 && seg4 >= 10 && seg4 <= 39)) {
                print $0
            }
        }
    }' | head -5
    NONVIP_COUNT=$(echo "$ALL" | awk '
    {
        if (match($0, /192\.168\.1(1[0-9])\.([0-9]+)/, arr)) {
            seg3 = arr[1]+0
            seg4 = arr[2]+0
            if (!(seg3 >= 10 && seg3 <= 19 && seg4 >= 10 && seg4 <= 39)) count++
        }
    }
    END{print count+0}')
    echo "(共 $NONVIP_COUNT 条 110-119 非 VIP 连接)"
    echo ""

    # ---- 109 网段 ----
    echo "━━━ 🎮 109 网段 (游戏加速区) ━━━"
    echo "$ALL" | grep "192\.168\.109\." | head -5
    NET109_COUNT=$(echo "$ALL" | grep -c "192\.168\.109\.")
    echo "(共 $NET109_COUNT 条 109 连接)"
    echo ""

    # ---- 其他普通设备 ----
    echo "━━━ 普通设备 (非 VIP) ━━━"
    OTHER_COUNT=$(echo "$ALL" | grep -v "192\.168\.10[9]\|192\.168\.1[1-9][0-9]\." | wc -l)
    echo "(共 $OTHER_COUNT 条普通连接，走 HNAT 默认队列)"
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
    # 提取 tin 统计
    tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | awk '
    /Tin [0-9]/{tin=$2}
    /pkts/{
        gsub(/[^0-9 ]/,"",$0)
        split($0,a," ")
        for(i=1;i<=8;i++) printf "Tin%d: %s pkts  ", i-1, a[i]
        print ""
    }
    /bytes/{
        split($0,a," ")
        for(i=2;i<=9;i++) {
            b=a[i]+0
            if(b>1048576) printf "Tin%d: %.1fMB  ", i-2, b/1048576
            else if(b>1024) printf "Tin%d: %.1fKB  ", i-2, b/1024
            else printf "Tin%d: %dB  ", i-2, b
        }
        print ""
    }' 2>/dev/null

    echo ""
    echo "━━━ Tin 7 (VIP 专属, interval=10ms) ━━━"
    tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | grep -A 20 "Tin 7" | grep -E "pkts|bytes|drops|pk_delay|interval|thresh" | head -8

    echo ""
    echo "━━━ Tin 2 (默认流量) ━━━"
    tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | grep -A 20 "Tin 2" | grep -E "pkts|bytes|drops|pk_delay|interval|thresh" | head -8
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
CAKE_SENT_A=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | grep "Sent" | awk '{print $2}')

sleep 3

Q0_B=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq0 2>/dev/null | awk '{print $3}')
Q32_B=$(grep "packet count" /sys/kernel/debug/hnat/qdma_txq32 2>/dev/null | awk '{print $3}')
CAKE_SENT_B=$(tc -s qdisc show dev "$CAKE_IF" 2>/dev/null | grep "Sent" | awk '{print $2}')

Q0_RATE=$(( (Q0_B - Q0_A) / 3 ))
Q32_RATE=$(( (Q32_B - Q32_A) / 3 ))
CAKE_RATE=$(( (CAKE_SENT_B - CAKE_SENT_A) / 3 ))

echo "  硬件加速 VIP 下行 (Queue 0):  $Q0_RATE 包/秒"
echo "  硬件加速 VIP 上行 (Queue 32): $Q32_RATE 包/秒"
if [ -n "$CAKE_IF" ]; then
    echo "  软件 SQM (CAKE) 吞吐:         $(( CAKE_RATE / 1024 )) KB/秒"
fi
echo ""
echo "  → Queue 0/32 > 0 = VIP 硬件加速正在工作"
echo "  → CAKE > 0     = HNAT 未命中流量走软件路径"
echo "============================================"
