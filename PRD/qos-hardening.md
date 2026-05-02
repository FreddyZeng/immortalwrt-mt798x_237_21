# QoS Hardening PRD

<!-- FID: F-QOS01 -->

## 1. 核心需求
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
重构 MT798x HNAT 硬件流控的数据路径，实现精准的物理端口分流、消除内网子网猜测、修复编译语法错误，并保证关闭 QoS 后的安全降级。
