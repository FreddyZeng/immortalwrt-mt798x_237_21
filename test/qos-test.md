# QoS Hardening Tests

<!-- FID: F-QOS01 -->

## 1. 编译性测试
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 修复 `IS_IPV4_DSLITE` 的 `else` 无 `if` 的编译错误。
- 保证无语法警告。

## 2. QoS 回归静态测试
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->
- `sh -n package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos`
- `sh -n package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos`
- `sh test/qos-regression.sh`
- HNAT dscp_en 必须将 mark 2 映射到 Q31/Q63，覆盖 IPv6 下行 MAC 限速规则。
- CAKE 最高 tin 修复必须由 `9999995-fix-cake-highest-tin-guard.patch` 承载，并在 VIP、109 小 UDP、priority、mark、DSCP 路径同时检查 `q->tin_cnt > 1`。
- `docs/verify-vip-qos.sh` 的队列展示必须与 HNAT `dscp_to_queue()` 一致，Q1/Q33 为 CS6/CS7，Q2/Q34 为 CS4/CS5/VA，Q31/Q63 为 DSCP2/MARK2 限速队列。
