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
- `sh -n package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/loadbalance`
- `sh test/qos-regression.sh`
- HNAT 方向感知位掩码：`(qos_mark & 0x40) && UPLOAD → Q31`（上行限速），`(qos_mark & 0x80) && DOWNLOAD → Q63`（下行限速）；VIP 可信 mark 46 映射到 Q32；mark 0 和其他 mark 回退到 `dscp_to_queue()`，未命中可信 VIP 标记的外部下行 EF 降级为 DSCP44/Q34。
- 限速速度为 0 的方向不得安装对应 bit（up=0 不安装 0x40，dl=0 不安装 0x80）；ct_mark 使用 `/0xFF` 和 `/0xC0` 精确掩码，防止 mwan3 bits[15:8] (0xFF00) 与 QoS bits[7:0] 碰撞。
- CAKE 最高 tin 修复必须由 `9999995-fix-cake-highest-tin-guard.patch` 承载，并在 VIP、109 小 UDP、priority、mark、DSCP 路径同时检查 `q->tin_cnt > 1`。
- `docs/verify-vip-qos.sh` 的队列展示必须与 HNAT `dscp_to_queue()` 和可信 mark 例外一致：Q0 为上行 VIP DSCP46，Q32 为可信 DSCP46/MARK46 VIP 下行，Q1/Q33 为 CS6/CS7，Q2/Q34 为 CS4/CS5/VA，Q31/Q63 为 MARK0x40/MARK0x80 方向限速队列。

## 3. CONNMARK 首包还原测试
<!-- CID: C-FQOS01-05 | BID: B-008 | commit: pending | 日期: 2026-05-02 -->
- `eqos_apply` 的 `CONNMARK --restore-mark` 必须覆盖 `NEW,ESTABLISHED,RELATED` 三态。
- 通过 `iptables -t mangle -L eqos_apply -n` 确认 ctstate NEW 在 restore-mark 规则中存在。
- 验证：新建连接首包 → eqos 链写 ct_mark → eqos_apply restore(NEW) → skb->mark 正确 → HNAT FOE 建表使用正确队列。

## 4. loadbalance POSIX 兼容性测试
<!-- CID: C-FQOS01-05 | BID: B-009 | commit: pending | 日期: 2026-05-02 -->
- `sh -n /usr/sbin/loadbalance` 必须通过（POSIX sh 语法检查）。
- 在 busybox ash 环境下执行 `sh /usr/sbin/loadbalance pppoe-wan,pppoe-wan2` 不得报错。
- 验证 FW_MARK 格式：`printf "0x%02x00" "20"` → `0x2000`，`printf "0x%02x00" "21"` → `0x2100`，均在 0xFF00 掩码范围内且不与 QoS 低8位重叠。
