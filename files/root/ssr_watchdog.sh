#!/bin/sh

# === 配置区域 ===
# 基础网络检测目标
BASE_PING_HOST="119.29.29.29"

# 目标检测配置
HOST="www.google.com"
PORT="80"
TIMEOUT="5"    # 超时时间 5秒
TYPE="1"       # 1 代表走代理检测
MAX_FAIL="5"   # 【保持原设】SSR检测最大失败次数恢复为 5
# ================

# === 步骤 1: 基础网络连通性检查 ===
# 逻辑：检测 119.29.29.29，发送 3 个包 (-c 3)
# 如果 3 个包全部丢失 (Ping不通)，脚本直接退出，不执行后续操作。
if ! ping -c 3 -W 5 $BASE_PING_HOST > /dev/null 2>&1; then
    # 可以在这里加日志，或者直接退出
    # echo "Network down, skipping SSR check."
    exit 0
fi

# === 步骤 2: SSR 代理可用性检查 ===
# 只有 119.29.29.29 能 Ping 通，才会走到这里

FAIL_COUNT=0

# 循环检测 5 次 (对应 MAX_FAIL="5")
for i in 1 2 3 4 5
do
    # 执行检测命令
    /usr/bin/ssr-check $HOST $PORT $TIMEOUT $TYPE

    # 获取退出状态码 (0=成功, 非0=失败)
    RET_CODE=$?

    if [ $RET_CODE -eq 0 ]; then
        # 只要有一次成功，就认为网络正常，直接退出脚本
        exit 0
    else
        # 如果失败，计数器 +1
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # 稍微等待 2 秒再重试
        sleep 2
    fi
done

# === 步骤 3: 故障处理 ===
# 如果代码执行到这里，说明循环跑完了 5 次且全部失败
if [ $FAIL_COUNT -eq $MAX_FAIL ]; then
    # 记录日志
    echo "[$(date)] SSR Check failed 5 times. Restarting..." >> /var/log/ssr_watchdog.log

    # 执行重启
    /etc/init.d/shadowsocksr stop
    sleep 30
    /etc/init.d/shadowsocksr start
fi
