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

## 5. 宽基线链顺序与遗留脚本回归测试
<!-- CID: C-FQOS01-07 | BID: B-010 | commit: pending | 日期: 2026-05-03 -->
- `init.d/eqos` 不得在 `/usr/sbin/eqos start` 后再次 flush 或追加 IPv6 `eqos` FORWARD jump；IPv6 链顺序必须由 `/usr/sbin/eqos` 单点安装为 `eqos -> eqos_apply`。
- Software tc 模式不得追加旧 `MARK --set-xmark 0x99/0xFF` 规则，只允许清理历史残留；否则低 8 位 bit7 会被 HNAT 误判为下行限速。
- `root/usr/sbin` 不得安装 `eqos_origin` 旧脚本。

## 6. 构建配置与预安装脚本回归测试
<!-- CID: C-FQOS01-08 | BID: B-011 | commit: pending | 日期: 2026-05-03 -->
- `target/linux/mediatek/mt7986/config-5.4` 与 `n60_pro_config_full_new` 不得出现 `CONFIG_*=y/m` 后跟行内注释的配置行。
- `install_all_files` 必须通过 `sh -n`，必须先检查 `/etc/pre_install` 目录和 `*.ipk` 是否存在，且 `opkg install` 失败时必须返回非零并保留目录。

## 7. 多 WAN 接口触发器回归测试
<!-- CID: C-FQOS01-09 | BID: B-012 | commit: pending | 日期: 2026-05-03 -->
- `init.d/eqos` 的 `service_triggers()` 必须读取 `eqos.config.interface` 并循环注册 trigger，不能只硬编码 `wan/wan2/wan3`。
- 未配置接口列表时必须有 `wan..wan8` 兜底；sqm trigger 必须有 `/etc/init.d/sqm` 可执行检查。

## 8. 新队列布局回归测试
<!-- CID: C-FQOS01-10 | BID: B-013 | commit: pending | 日期: 2026-05-06 -->
- DHCP 自动 WRR 只能分配 `2-30`，下载映射只能为 `34-62`；超过 29 个设备时共享普通 WRR 槽位，禁止使用 `31/63`。
- `dhcp_mark.sh` 必须同时按 IP 和 MAC 跳过 UCI 中显式配置的 VIP/限速设备，避免覆盖 `eqos add` 管理的规则。
- `eqos add` 在状态切换前必须清理同一 MAC 的所有 IPv6 WRR/限速旧规则，再安装新状态规则。
- 显式限速设备必须拥有精确 IP 的 FORWARD 最终覆盖规则，保证即使命中 109 小包或静态 VIP 规则，最终仍进入 `Q31/Q63`；状态切换和 stop/start 必须清理旧覆盖规则。
- MAC-only 设备必须用 MAC 作为 WRR hash key，IPv4 DSCP 规则必须在 IP 非空时才安装。
- HNAT 允许上传和下载出口 DSCP 重标记为 EF/AF41/BE，但 `mtk_hnat_dscp_update()` 在 HQOS 模式下必须比较队列 qid 是否变化，不能把合法出口重标记误判为原始 skb TOS 变化。

## 9. SSR Plus/TProxy 兼容回归测试
<!-- CID: C-FQOS01-11 | BID: B-014 | commit: pending | 日期: 2026-05-06 -->
- `init.d/eqos` 禁止执行 `iptables -t mangle -F PREROUTING`，避免清空 SSR Plus、PassWall、OpenClash 等透明代理/TProxy 规则。
- eqos 多 WAN 负载均衡重建时只能删除自己安装的精确 PREROUTING/POSTROUTING 规则，再调用 `loadbalance` 重建。
- 诊断日志必须包含 `[EQOS-B014-*]`，用于在路由器上通过 `logread` 追踪清理过程。
- IPv6 `eqos` 链创建和 `FORWARD`/`POSTROUTING` jump 重建必须幂等，不能在启动日志里产生 chain already exists 噪声或重复 jump。

## 3. CONNMARK 首包还原测试
<!-- CID: C-FQOS01-05 | BID: B-008 | commit: pending | 日期: 2026-05-02 -->
- `eqos_apply` 的 `CONNMARK --restore-mark` 必须覆盖 `NEW,ESTABLISHED,RELATED` 三态。
- 通过 `iptables -t mangle -L eqos_apply -n` 确认 ctstate NEW 在 restore-mark 规则中存在。
- 验证：新建连接首包 → eqos 链写 ct_mark → eqos_apply restore(NEW) → skb->mark 正确 → HNAT FOE 建表使用正确队列。

## 4. loadbalance POSIX 兼容性测试
<!-- CID: C-FQOS01-05 | BID: B-009 | commit: pending | 日期: 2026-05-02 -->
- `sh -n /usr/sbin/loadbalance` 必须通过（POSIX sh 语法检查）。
- 在 busybox ash 环境下执行 `sh /usr/sbin/loadbalance pppoe-wan,pppoe-wan2` 不得报错。
- 验证 FW_MARK 格式：`printf "0x%02x00" $((0x20 + idx))`；idx=0 → `0x2000`，idx=1 → `0x2100`，均在 0xFF00 掩码范围内且不与 QoS 低8位重叠。
