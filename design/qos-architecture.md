# QoS Hardening Architecture

<!-- FID: F-QOS01 -->

## 1. 架构重构
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 引入物理方向判定 `get_hqos_direction` 以替代废弃的内网猜测代码。
- 保证 `PPPQ_MODE` 和无 QoS 模式的原始行为隔离，彻底防堵状态机溢出风险。

## 2. 回归修复设计
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->
- `eqos add` 在进入数值比较前统一归一化 QoS mode，非数字旧备注进入硬件限速模式。
- IPv6 限速上行规则使用 `DSCP --set-dscp 2`；HNAT 在 dscp_en 路径优先识别限速 mark 2 并映射到 Q31/Q63，同时识别 eqos 指定 VIP 下行的可信 mark 46 并映射到 Q32。mark 0 和其他 mark 回退到 DSCP/hash 映射，未命中可信 mark 46 的外部下行 EF 先降级为 DSCP44 后进入 Q34。
- CAKE 修复通过 `9999995-fix-cake-highest-tin-guard.patch` 叠加在既有 CAKE 补丁之后，将 `highest_priority_tin` 初始化为 0，限制 VIP/109 直达最高 tin 仅在多 tin 模式生效，并移除 `TC_PRIO_MAX` 对最高 tin 的直接绕过。
- `docs/verify-vip-qos.sh` 直接呈现 HNAT 映射后的 Q0-Q31/Q32-Q63 含义，普通流量展示为 hash 队列范围，可信 VIP 下行展示为 DSCP46/MARK46 到 Q32，限速下行展示为 DSCP2/MARK2 到 Q63。
