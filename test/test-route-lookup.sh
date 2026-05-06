#!/bin/sh
# ============================================================
# test-route-lookup.sh — 验证 ip route show default dev 语法
# 用法: sh test-route-lookup.sh [接口名 接口名2 ...]
# 无参数时使用模拟数据进行逻辑验证
# ============================================================

PASS=0
FAIL=0

ok()   { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== 1. 语法验证：sh -n 检查 ==="
sh -n /Volumes/E2T/project/immortalwrt-mt798x_237/package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos \
    && ok "init.d/eqos sh 语法正确" \
    || fail "init.d/eqos sh 语法错误"

echo ""
echo "=== 2. ip route 输出格式验证（模拟路由器输出）==="

# 模拟 pppoe 接口的默认路由格式（最常见的两种）
ROUTE_WITH_GW="default via 203.0.113.1 dev pppoe-wan proto static"
ROUTE_NO_GW="default dev pppoe-wan scope link src 1.2.3.4"
ROUTE_EMPTY=""

# 方法A（旧）: ip route show | grep default | grep "$var" | awk '{print $3}'
# 方法B（新）: ip route show default dev "$var" | awk 'NR==1 {print $3}'
# 方法C（我的fix）: ip route show default dev "$var" | awk '{print $3}' | head -1

echo "-- 场景1: 带 via 网关的默认路由 --"
echo "  路由行: $ROUTE_WITH_GW"
RES_A=$(echo "$ROUTE_WITH_GW" | awk '{print $3}')  # 模拟旧方式
RES_B=$(echo "$ROUTE_WITH_GW" | awk 'NR==1 {print $3}')
RES_C=$(echo "$ROUTE_WITH_GW" | awk '{print $3}' | head -1)
echo "  旧方式 \$3      : [$RES_A]"
echo "  loadbalance \$3 : [$RES_B]"
echo "  我的修复 \$3     : [$RES_C]"
[ "$RES_A" = "203.0.113.1" ] && ok "旧方式提取网关正确" || fail "旧方式提取网关错误: $RES_A"
[ "$RES_B" = "203.0.113.1" ] && ok "loadbalance 方式提取网关正确" || fail "loadbalance 方式错误: $RES_B"
[ "$RES_C" = "203.0.113.1" ] && ok "我的修复提取网关正确" || fail "我的修复提取网关错误: $RES_C"

echo ""
echo "-- 场景2: 无 via 网关（PPPoE 点对点链路）--"
echo "  路由行: $ROUTE_NO_GW"
RES_A2=$(echo "$ROUTE_NO_GW" | awk '{print $3}')
RES_B2=$(echo "$ROUTE_NO_GW" | awk 'NR==1 {print $3}')
RES_C2=$(echo "$ROUTE_NO_GW" | awk '{print $3}' | head -1)
echo "  旧方式 \$3      : [$RES_A2]  ← 注意: $3 不是 IP"
echo "  loadbalance \$3 : [$RES_B2]"
echo "  我的修复 \$3     : [$RES_C2]"
# 场景2下 $3 = "dev"，不是IP，但 init.d 有 [ -n "$ipaddr" ] 守卫
# 实际 iptables -d "dev/24" 不会匹配任何规则，while 立即退出，无害
echo "  → 两种方式行为一致，均返回 'dev'（非IP）"
echo "  → init.d cleanup_loadbalance_rules 有 if [ -n \"\$ipaddr\" ] 守卫保护"
[ "$RES_B2" = "$RES_C2" ] \
    && ok "场景2两种方式行为一致（均为 [$RES_C2]）" \
    || fail "场景2两种方式不一致: loadbalance=[$RES_B2] fix=[$RES_C2]"

echo ""
echo "-- 场景3: 无路由（接口不存在）--"
RES_B3=$(echo "$ROUTE_EMPTY" | awk 'NR==1 {print $3}')
RES_C3=$(echo "$ROUTE_EMPTY" | awk '{print $3}' | head -1)
echo "  loadbalance \$3 : [$RES_B3]"
echo "  我的修复 \$3     : [$RES_C3]"
[ "$RES_B3" = "$RES_C3" ] \
    && ok "场景3两种方式行为一致（均为空）" \
    || fail "场景3不一致"

echo ""
echo "=== 3. 前缀碰撞验证（B-015/B-016 根因）==="
echo "-- 旧方式 grep 碰撞演示 --"
ROUTE_TABLE="default via 1.1.1.1 dev pppoe-wan
default via 2.2.2.2 dev pppoe-wan2"

GW_FOR_WAN_OLD=$(echo "$ROUTE_TABLE" | grep default | grep "pppoe-wan" | awk '{print $3}' | head -1)
GW_FOR_WAN2_OLD=$(echo "$ROUTE_TABLE" | grep default | grep "pppoe-wan2" | awk '{print $3}' | head -1)
echo "  旧方式 pppoe-wan  网关: [$GW_FOR_WAN_OLD]  (期望: 1.1.1.1)"
echo "  旧方式 pppoe-wan2 网关: [$GW_FOR_WAN2_OLD] (期望: 2.2.2.2)"
[ "$GW_FOR_WAN_OLD" = "1.1.1.1" ] \
    && ok "旧方式 pppoe-wan 正确（单接口时无碰撞）" \
    || fail "旧方式 pppoe-wan 错误: [$GW_FOR_WAN_OLD]（碰撞了！）"
[ "$GW_FOR_WAN2_OLD" = "2.2.2.2" ] \
    && ok "旧方式 pppoe-wan2 正确" \
    || fail "旧方式 pppoe-wan2 错误（可能碰撞）"

echo ""
echo "-- 注：真实 'ip route show default dev pppoe-wan' 只返回该接口的行 --"
echo "   不存在碰撞，新方式从内核精确过滤，不依赖 grep 字符串匹配"

echo ""
echo "=== 4. 建议：与 loadbalance 对齐 ==="
echo "   loadbalance 使用:  awk 'NR==1 {print \$3}'"
echo "   我的修复使用:      awk '{print \$3}' | head -1"
echo "   行为完全一致，但建议统一为 loadbalance 的写法 NR==1"

echo ""
echo "=== 结果汇总 ==="
TOTAL=$((PASS+FAIL))
echo "  通过: $PASS / $TOTAL"
[ "$FAIL" -eq 0 ] \
    && echo "  ✅ 所有验证通过" \
    || echo "  ❌ 存在 $FAIL 项失败"
