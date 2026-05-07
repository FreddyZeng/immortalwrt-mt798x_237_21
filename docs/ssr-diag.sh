#!/bin/sh
# ═══════════════════════════════════════════════════════
#  SSR Plus 断线诊断监控脚本
#  用法: sh ssr-diag.sh [后台运行: sh ssr-diag.sh &]
#  日志: /tmp/ssr-diag.log
# ═══════════════════════════════════════════════════════

LOG=/tmp/ssr-diag.log
INTERVAL=10          # 采样间隔（秒）
SSR_LOG=/var/log/ssrplus.log
SSR_LOG_LINES=0      # 上次已读行数（用于检测新事件）

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

sep() {
    echo "────────────────────────────────────────────────" | tee -a "$LOG"
}

# ── 查找 Xray 进程 PID（兼容 OpenWrt busybox，无 pgrep -f）──
get_xray_pid() {
    ps 2>/dev/null | grep -v grep | grep -E 'xray|v2ray' | awk '{print $1}' | head -1
}

echo "" >> "$LOG"
sep
log "【SSR-DIAG 启动】采样间隔=${INTERVAL}s  日志=$LOG"
sep

# 记录初始状态
log "当前代理相关进程:"
ps 2>/dev/null | grep -v grep | grep -E 'xray|v2ray|ssr' | while read -r line; do
    log "  $line"
done
XRAY_PID=$(get_xray_pid)
log "初始 Xray PID: ${XRAY_PID:-未找到（SSR可能未启动）}"
log "初始 conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
log "初始内存: $(free -m | awk '/Mem/{printf "total=%sMB used=%sMB free=%sMB", $2,$3,$4}')"
SSR_LOG_LINES=$(wc -l < "$SSR_LOG" 2>/dev/null || echo 0)


# ── 主监控循环 ───────────────────────────────────────────
while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # 1. conntrack 使用量
    CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 65536)
    CT_PCT=$((CT_COUNT * 100 / CT_MAX))

    # 2. 内存
    MEM_FREE=$(free -m 2>/dev/null | awk '/Mem/{print $4}')
    MEM_USED=$(free -m 2>/dev/null | awk '/Mem/{print $3}')

    # 3. Xray 进程状态
    NEW_XRAY_PID=$(get_xray_pid)
    XRAY_MEM=""
    if [ -n "$NEW_XRAY_PID" ]; then
        XRAY_MEM=$(cat /proc/$NEW_XRAY_PID/status 2>/dev/null | awk '/VmRSS/{print $2" "$3}')
        XRAY_THREADS=$(cat /proc/$NEW_XRAY_PID/status 2>/dev/null | awk '/Threads/{print $2}')
    fi

    # 4. 检测 SSR 日志新事件（不需要 tail -f）
    CURRENT_LINES=$(wc -l < "$SSR_LOG" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINES" -gt "$SSR_LOG_LINES" ]; then
        NEW_EVENTS=$(tail -n $((CURRENT_LINES - SSR_LOG_LINES)) "$SSR_LOG" 2>/dev/null)
        SSR_LOG_LINES=$CURRENT_LINES

        # 检测到崩溃事件
        if echo "$NEW_EVENTS" | grep -qi "error\|restart\|fail"; then
            sep
            log "⚠️  【崩溃事件检测】"
            log "崩溃时 conntrack: $CT_COUNT/$CT_MAX ($CT_PCT%)"
            log "崩溃时内存: used=${MEM_USED}MB free=${MEM_FREE}MB"
        log "崩溃时 Xray PID: ${NEW_XRAY_PID:-已退出}  内存: ${XRAY_MEM:-N/A}  线程: ${XRAY_THREADS:-N/A}"
        log "崩溃时进程列表:"
        ps 2>/dev/null | grep -v grep | grep -E 'xray|v2ray|ssr' | while read -r line; do
            log "  $line"
        done
            log "SSR 新日志:"
            echo "$NEW_EVENTS" | while read -r line; do
                log "  > $line"
            done
            # 保存内核日志快照
            log "dmesg 最新10行:"
            dmesg | tail -10 | while read -r line; do
                log "  [dmesg] $line"
            done
            # 保存 iptables SSR 规则状态
            log "NAT PREROUTING SSR 规则数: $(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 'REDIRECT\|ssrplus' || echo 0)"
            sep
        elif echo "$NEW_EVENTS" | grep -qi "start\|started"; then
            log "✅ SSR 重启完成: $(echo "$NEW_EVENTS" | grep -i "started" | tail -1)"
        fi
    fi

    # 5. 检测 Xray PID 变化（进程重启）
    if [ -n "$XRAY_PID" ] && [ "$NEW_XRAY_PID" != "$XRAY_PID" ]; then
        log "⚠️  Xray PID 变化: $XRAY_PID → ${NEW_XRAY_PID:-已退出}"
    fi
    XRAY_PID="$NEW_XRAY_PID"

    # 6. conntrack 高水位告警（>80%）
    if [ "$CT_PCT" -gt 80 ]; then
        log "🔴 conntrack 高水位告警: $CT_COUNT/$CT_MAX ($CT_PCT%)"
    fi

    # 7. 内存告警（剩余 < 50MB）
    if [ -n "$MEM_FREE" ] && [ "$MEM_FREE" -lt 50 ]; then
        log "🔴 内存不足告警: free=${MEM_FREE}MB"
    fi

    # 8. 定期状态快照（每60秒）
    MINUTE=$(date '+%S')
    if [ "$MINUTE" = "00" ] || [ "$MINUTE" = "30" ]; then
        log "📊 状态 | conntrack=$CT_COUNT/$CT_MAX($CT_PCT%) | mem=used=${MEM_USED}MB,free=${MEM_FREE}MB | xray=${NEW_XRAY_PID:-无}(${XRAY_MEM:-N/A})"
    fi

    sleep "$INTERVAL"
done
