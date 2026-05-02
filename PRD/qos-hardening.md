# QoS Hardening PRD

<!-- FID: F-QOS01 -->

## 1. 核心需求
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
重构 MT798x HNAT 硬件流控的数据路径，实现精准的物理端口分流、消除内网子网猜测、修复编译语法错误，并保证关闭 QoS 后的安全降级。

## 2. 回归修复需求
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->
- IPv6 硬件限速设备的上行规则必须写入 DSCP 2；下行 MAC 规则产生的 mark 2 必须由 HNAT dscp_en 路径映射到 Q63。eqos 指定 VIP 下行必须通过可信 mark 46 保留 EF 并进入 Q32；未命中可信 VIP 标记的外部 EF46 仍必须降级为 DSCP44/Q34。
- 旧版 `comment` 文本配置必须归一化为硬件限速模式，避免非数字模式值中断 `eqos add`。
- CAKE 最高 tin 变量必须有确定初值，且只有 VIP 或 109 小 UDP 在多 tin 模式命中时能够直接进入最高 tin；该修复由补丁栈末尾的独立 CAKE 修复补丁承载。
- 现场验证脚本展示的 DSCP 队列含义必须以 HNAT `dscp_to_queue()` 为唯一准绳，避免把未映射的 DSCP 41-45 展示为固定优先队列。
