#!/bin/sh
# VIP QoS 验证脚本 - 在路由器上运行
# 用法: sh verify-vip-qos.sh

echo "============================================"
echo "  VIP QoS 完整验证"
echo "============================================"
echo ""

# ==========================================
# 1. iptables mangle 规则检查
# ==========================================
echo "【1】iptables mangle 规则 (DSCP 标记)"
echo "--------------------------------------------"
iptables -t mangle -L eqos -v -n 2>/dev/null
if [ $? -ne 0 ]; then
    echo "⚠️  eqos 链不存在，检查 eqos 服务是否启动"
    echo "   运行: /etc/init.d/eqos start"
fi
echo ""

# ==========================================
# 2. DSCP 标记实时验证
# ==========================================
echo "【2】DSCP 标记验证 (抓包检查)"
echo "--------------------------------------------"

# 检查 110 网段 VIP
echo "--- 110 网段 VIP 设备 (应该看到 DSCP=0x2e=46) ---"
echo "  从 VIP 设备 ping 外网，同时运行:"
echo "  tcpdump -i br-lan -c 5 'src net 192.168.110.0/24' -v 2>&1 | grep -i tos"
echo ""

# 检查 109 网段
echo "--- 109 网段设备 (UDP≤300B 应该有 DSCP=46) ---"
echo "  tcpdump -i br-lan -c 10 'src net 192.168.109.0/24 and udp' -v 2>&1 | grep -i tos"
echo ""

# ==========================================
# 3. QDMA 硬件队列状态
# ==========================================
echo "【3】QDMA 硬件队列计数器"
echo "--------------------------------------------"

# VIP 队列 (Queue 0 和 Queue 32)
echo "--- VIP 队列 (Queue 0 - 下行 SP) ---"
if [ -f /sys/kernel/debug/hnat/qdma_txq0 ]; then
    cat /sys/kernel/debug/hnat/qdma_txq0
else
    echo "⚠️  debugfs 文件不存在"
fi
echo ""

echo "--- VIP 队列 (Queue 32 - 上行 SP) ---"
if [ -f /sys/kernel/debug/hnat/qdma_txq32 ]; then
    cat /sys/kernel/debug/hnat/qdma_txq32
else
    echo "⚠️  debugfs 文件不存在"
fi
echo ""

# 默认队列对比
echo "--- 默认队列 (Queue 1 - 对比用) ---"
if [ -f /sys/kernel/debug/hnat/qdma_txq1 ]; then
    cat /sys/kernel/debug/hnat/qdma_txq1
fi
echo ""

# ==========================================
# 4. HNAT 加速状态
# ==========================================
echo "【4】HNAT 硬件加速状态"
echo "--------------------------------------------"
if [ -f /sys/kernel/debug/hnat/hnat_entry ]; then
    TOTAL=$(cat /sys/kernel/debug/hnat/hnat_entry | wc -l)
    VIP_ENTRIES=$(cat /sys/kernel/debug/hnat/hnat_entry | grep -E "192\.168\.11[0-9]\." | head -5)
    NET109_ENTRIES=$(cat /sys/kernel/debug/hnat/hnat_entry | grep -E "192\.168\.109\." | head -5)
    echo "总 HNAT 条目数: $TOTAL"
    echo ""
    echo "--- VIP (110-119) HNAT 条目 (前5条) ---"
    if [ -n "$VIP_ENTRIES" ]; then
        echo "$VIP_ENTRIES"
    else
        echo "  (无 VIP 设备活跃连接)"
    fi
    echo ""
    echo "--- 109 网段 HNAT 条目 (前5条) ---"
    if [ -n "$NET109_ENTRIES" ]; then
        echo "$NET109_ENTRIES"
    else
        echo "  (无 109 设备活跃连接)"
    fi
else
    echo "⚠️  hnat_entry debugfs 不存在"
fi
echo ""

# ==========================================
# 5. CAKE SQM 状态 (如果启用)
# ==========================================
echo "【5】CAKE SQM 队列状态"
echo "--------------------------------------------"
# 查找 CAKE qdisc
CAKE_IF=$(tc qdisc show 2>/dev/null | grep cake | awk '{print $5}' | head -1)
if [ -n "$CAKE_IF" ]; then
    echo "CAKE 运行在: $CAKE_IF"
    tc -s qdisc show dev $CAKE_IF 2>/dev/null | head -30
    echo ""
    echo "--- 各 tin 统计 ---"
    tc -s class show dev $CAKE_IF 2>/dev/null | head -40
else
    echo "  CAKE 未启用 (纯硬件 QoS 模式)"
fi
echo ""

# ==========================================
# 6. eqos 服务状态
# ==========================================
echo "【6】eqos 服务配置"
echo "--------------------------------------------"
if [ -f /etc/config/eqos ]; then
    echo "--- eqos 配置 ---"
    cat /etc/config/eqos
else
    echo "⚠️  eqos 配置文件不存在"
fi
echo ""

# ==========================================
# 7. 实时流量测试指引
# ==========================================
echo "============================================"
echo "  实时验证步骤"
echo "============================================"
echo ""
echo "步骤 1: 记录当前 VIP 队列包计数"
echo "  cat /sys/kernel/debug/hnat/qdma_txq0"
echo ""
echo "步骤 2: 从 VIP 设备 (110-119 网段) 发起流量"
echo "  例: ping 8.8.8.8 或 下载文件"
echo ""
echo "步骤 3: 再次读取 VIP 队列包计数"
echo "  cat /sys/kernel/debug/hnat/qdma_txq0"
echo "  → 如果计数增加，说明 VIP 流量确实走了硬件最高优先队列"
echo ""
echo "步骤 4: 对比测试 - 从非 VIP 设备发流量"
echo "  cat /sys/kernel/debug/hnat/qdma_txq1  (默认队列)"
echo "  → 非 VIP 流量应该走默认队列，不走 Queue 0"
echo ""
echo "步骤 5: 109 网段 UDP 小包测试"
echo "  从 109 设备: nping --udp -p 12345 --data-length 100 8.8.8.8"
echo "  检查 qdma_txq0 是否增加 (应该增加)"
echo ""
echo "  从 109 设备: nping --udp -p 12345 --data-length 500 8.8.8.8"
echo "  检查 qdma_txq0 是否增加 (不应该增加，走默认队列)"
echo ""
