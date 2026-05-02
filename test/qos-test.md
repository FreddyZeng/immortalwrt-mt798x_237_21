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
- HNAT dscp_en 必须让限速 mark 2 优先映射到 Q31/Q63，并让 eqos 指定 VIP 下行可信 mark 46 映射到 Q32；mark 0 和其他 mark 必须回退到 DSCP/hash 映射，保证未命中可信 VIP 标记的下行 EF 降级为 DSCP44 后进入 Q34。
- 限速速度为 0 的方向必须取消对应 DSCP2/MARK2 分类；mark 2 和 mark 46 必须使用完整 `skb->mark` 精确匹配，防止其他 fwmark 低 6 位碰撞。
- CAKE 最高 tin 修复必须由 `9999995-fix-cake-highest-tin-guard.patch` 承载，并在 VIP、109 小 UDP、priority、mark、DSCP 路径同时检查 `q->tin_cnt > 1`。
- `docs/verify-vip-qos.sh` 的队列展示必须与 HNAT `dscp_to_queue()` 和可信 mark 例外一致，Q0 为上行 DSCP46，Q32 为可信 DSCP46/MARK46 VIP 下行，Q1/Q33 为 CS6/CS7，Q2/Q34 为 CS4/CS5/VA，Q31/Q63 为 DSCP2/MARK2 限速队列。
