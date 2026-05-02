# QoS Hardening Architecture

<!-- FID: F-QOS01 -->

## 1. 架构重构
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 引入物理方向判定 `get_hqos_direction` 以替代废弃的内网猜测代码。
- 保证 `PPPQ_MODE` 和无 QoS 模式的原始行为隔离，彻底防堵状态机溢出风险。
