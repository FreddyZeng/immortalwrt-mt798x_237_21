# 任务日志

> 按 CID 记录每次 commit 的详细信息。
> 格式参考: smart-commit SKILL.md §5.2

---

## [2026-05-02] C-FQOS01-01 | commit: pending

- **FID**: F-QOS01
- **CID**: C-FQOS01-01
- **类型**: refactor, fix
- **范围**: mtk_hnat
- **描述**: Dead code cleanup, syntax error fix, and fallback QoS logic refactoring.
- **改动文件**: hnat_nf_hook.c
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-test.md

## [2026-05-02] C-FQOS01-02 | commit: pending

- **FID**: F-QOS01
- **BID**: B-001
- **CID**: C-FQOS01-02
- **类型**: fix, test
- **范围**: luci-app-eqos-mtk, CAKE patch
- **描述**: Fix IPv6 hardware limit DSCP/mark queue binding, trusted VIP download Q32 marker, zero-speed limit cancellation, exact mark matching, legacy comment mode parsing, standalone CAKE highest tin guard patch, and verification DSCP queue labels.
- **改动文件**: root/usr/sbin/eqos, hnat_nf_hook.c, 9999995-fix-cake-highest-tin-guard.patch, docs/verify-vip-qos.sh, test/qos-regression.sh, PRD/design/test/task/bugs
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-test.md

## [2026-05-02] C-FQOS01-03 | commit: pending

- **FID**: F-QOS01
- **CID**: C-FQOS01-03
- **类型**: refactor
- **范围**: mtk_hnat
- **描述**: Refactor DOWNLOAD QoS marking logic to cleanly isolate IPv4 and IPv6 rule sets, resolving structural mixing of protocol-specific checks.
- **改动文件**: hnat_nf_hook.c
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-test.md

<!-- 新增 commit 记录在此下方添加 -->

## [2026-05-02] C-FQOS01-04 | commit: d6f47e1fce

- **FID**: F-QOS01
- **CID**: C-FQOS01-04
- **类型**: refactor
- **范围**: luci-app-eqos-mtk, tests
- **描述**: Refactor eqos ruleset to a unified CONNMARK architecture. Replaced all ebtables and IP-based DSCP rules with global CONNMARK tracking. Solved IPv6 hardware offload bypass issue and unified QoS tracking for both IPv4 and IPv6.
- **改动文件**: root/usr/sbin/eqos, root/etc/init.d/eqos, test/qos-regression.sh
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh

## [2026-05-02] B-002 | commit: d6f47e1fce

- **BID**: B-002
- **关联 FID**: F-QOS01
- **类型**: bugfix
- **范围**: luci-app-eqos-mtk, mtk_hnat
- **描述**: Add `0xFF` mask to `CONNMARK` operations and `skb->mark & 0xFF` kernel extraction to prevent catastrophic collision with `mwan3` multi-WAN routing marks (which use bits 8-13).
- **改动文件**: root/usr/sbin/eqos, hnat_nf_hook.c, test/qos-regression.sh
- **测试同步**: ✅ test/qos-regression.sh

## [2026-05-02] B-003 | commit: 7b3380f9fd

- **BID**: B-003
- **关联 FID**: F-QOS01
- **类型**: bugfix
- **范围**: luci-app-eqos-mtk
- **描述**: Fix first-packet hardware acceleration bypass. `CONNMARK --set-xmark` only sets the connection mark, leaving `skb->mark` as 0 for the first packet. This caused HNAT to program FOE to the wrong queue (Q33). Introduced `eqos_apply` chain to enforce `restore-mark` and DSCP sync after the connection mark is set.
- **改动文件**: root/usr/sbin/eqos, test/qos-regression.sh
- **测试同步**: ✅ test/qos-regression.sh

<!-- 新增 commit 记录在此下方添加 -->
- [x] (2026-05-02) `B-004`: Fixed legacy `--set-mark` logic in `eqos` script which lacked masks and zeroed out upper routing bits used by `mwan3`. Replaced all `--set-mark 0x99` with `--set-xmark 0x99/0xFF` and `--set-mark 2"$interface"` with `--set-xmark 2"$interface"/0xFF00`.
- [x] (2026-05-02) `F-QOS02`: Refactored `loadbalance` and `eqos` scripts to migrate multi-WAN routing marks from 8-bit to 16-bit (`0x2X00/0xFF00`). This completely resolves the collision between QoS tagging (`0xFF` mask) and per-device WAN binding/load balancing marking, ensuring both systems can coexist.
| 2026-05-02T12:58:34Z | Fixed B-005 | CAKE vs HNAT Priority Asymmetry for 109 Subnet | F-QOS-AUDIT |
| 2026-05-02T13:08:00Z | Fixed B-006 | HNAT QoS 7 Logic Flaws (NEW Packet, Limit MAC, local scope, TC root) | F-QOS-AUDIT |
| 2026-05-02T13:12:00Z | Fixed B-007 | mtk_eth_soc.c semantic mark leak & eqos state file collision | F-QOS-AUDIT |

## [2026-05-03] C-FQOS01-07 | commit: pending

- **FID**: F-QOS01
- **BID**: B-010
- **CID**: C-FQOS01-07
- **类型**: fix, test
- **范围**: luci-app-eqos-mtk, tests, docs
- **描述**: Fix wide-baseline QoS audit regressions by making `/usr/sbin/eqos` the only IPv6 eqos chain owner, preventing Software tc from writing legacy MARK 0x99 into HNAT semantic mark bits, and deleting the shipped stale `eqos_origin` script.
- **改动文件**: root/usr/sbin/eqos, root/etc/init.d/eqos, test/qos-regression.sh, bugs/B-010.md, design/qos-architecture.md, test/qos-test.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh, test/qos-test.md

## [2026-05-03] C-FQOS01-08 | commit: pending

- **FID**: F-QOS01
- **BID**: B-011
- **CID**: C-FQOS01-08
- **类型**: fix, test
- **范围**: mt7986 kernel config, pre-install script, tests, docs
- **描述**: Fix build hygiene regressions by moving inline Kconfig/OpenWrt config comments to standalone comments and making `install_all_files` check directory/ipk existence before installation while preserving ipk files on opkg failure.
- **改动文件**: target/linux/mediatek/mt7986/config-5.4, n60_pro_config_full_new, install_all_files, test/qos-regression.sh, bugs/B-011.md, PRD/qos-hardening.md, design/qos-architecture.md, test/qos-test.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh, test/qos-test.md

## [2026-05-03] C-FQOS01-09 | commit: pending

- **FID**: F-QOS01
- **BID**: B-012
- **CID**: C-FQOS01-09
- **类型**: fix, test
- **范围**: luci-app-eqos-mtk init lifecycle, tests, docs
- **描述**: Fix multi-WAN lifecycle trigger coverage by deriving interface up triggers from `eqos.config.interface`, falling back to `wan..wan8`, and guarding sqm trigger registration by script existence.
- **改动文件**: root/etc/init.d/eqos, test/qos-regression.sh, bugs/B-012.md, PRD/qos-hardening.md, design/qos-architecture.md, test/qos-test.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh, test/qos-test.md

## [2026-05-06] C-FQOS01-10 | commit: pending

- **FID**: F-QOS01
- **BID**: B-013
- **CID**: C-FQOS01-10
- **类型**: fix, feat, test
- **范围**: luci-app-eqos-mtk eqos sbin, init.d, dhcp_mark.sh, tests, docs
- **描述**: 确定性 DSCP 架构终态 — 将 QoS 标记从 CONNMARK 全面迁移到纯 DSCP，实现 eqos add 三路分支（VIP Q0/Q32、限速 Q31/Q63、WRR Q2-30/Q34-62）；Branch 2 在 FORWARD 链末尾追加 DSCP=31/63 最终覆盖规则防止游戏/VIP 规则旁路；/tmp/rl_forward_ips 幂等清理；smarthqos Q2-30 per-queue shaper 配置。
- **改动文件**: root/usr/sbin/eqos, root/etc/init.d/eqos, root/etc/init.d/dhcp_mark.sh, test/qos-regression.sh, bugs/B-013.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ 架构描述更新为纯 DSCP
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh §8

## [2026-05-06] C-FQOS01-11 | commit: pending

- **FID**: F-QOS01
- **BID**: B-014
- **CID**: C-FQOS01-11
- **类型**: fix, security, test
- **范围**: luci-app-eqos-mtk loadbalance, eqos sbin, init.d, tests, docs
- **描述**: TProxy/SSR Plus bit 0x8000 全链路保护 — loadbalance 和 eqos add 所有 PREROUTING NEW mark 规则添加 `-m mark ! --mark 0x8000/0x8000`；DHCP hotplug 使用 `cmp -s` 幂等安装避免 dnsmasq 竞争；IPv6 fallback `--mark 0` 规则移至 `config_foreach` 之后追加（避免 `-F eqos` 清除）；iface hotplug 仅对配置接口触发 eqos start。
- **改动文件**: root/usr/sbin/loadbalance, root/usr/sbin/eqos, root/etc/init.d/eqos, test/qos-regression.sh, bugs/B-014.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ TProxy 兼容性约束章节
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh §9

## [2026-05-06] C-FQOS01-12 | commit: pending

- **FID**: F-QOS01
- **BID**: B-015
- **CID**: C-FQOS01-12
- **类型**: fix, test
- **范围**: luci-app-eqos-mtk loadbalance, test/qos-test.md, bugs
- **描述**: loadbalance grep 前缀匹配 Bug 修复 — 将 `ip route show | grep default | grep $var` 改为 `ip route show default dev $var`，防止 pppoe-wan 误匹配 pppoe-wan2；所有 iptables -D 操作补充 2>/dev/null；qos-test.md 中三处 loadbalance 语法检查改为 bash -n/bash（脚本使用 bash 数组和 let，不兼容 sh）；创建 B-015 Bug 文档；CHANGE_INDEX 补全 C-FQOS01-10/11/12 和 B-013/14/15 条目。
- **改动文件**: root/usr/sbin/loadbalance, test/qos-test.md, test/qos-regression.sh, bugs/B-015.md, task/CHANGE_INDEX.md, task/TASK_LOG.md
- **PRD 同步**: ✅ N/A（loadbalance 实现细节）
- **方案同步**: ✅ N/A
- **测试同步**: ✅ test/qos-regression.sh — `absent 'grep default | grep $var'` 断言

## [2026-05-18] C-FQOS01-14 | commit: pending

- **FID**: F-QOS01
- **BID**: B-017
- **CID**: C-FQOS01-14
- **类型**: fix
- **范围**: hnat_nf_hook.c tproxy_protection_v4
- **描述**: 移除 tproxy_protection_v4 中 `ct->mark |= 0x8000` 写入块（B-017）。
  该写入通过 SSR Plus CONNMARK --restore-mark 规则将 0x8000 传播到同一连接所有后续 ESTABLISHED 数据包，
  导致 tproxy_protection_v4 在每个 ESTABLISHED 包上重复 memset(FOE,0)，HNAT 永远无法 BIND 这些流量，
  偶发产生 TCP 连接延迟抖动（浏览器访问 URL 短时间无响应，新打开 URL 恢复）。
  tproxy_protection_v4 已通过 skb->mark & 0x8000 直接判断（iptables TPROXY 设置），
  无需将状态持久化到 ct->mark；原消费者 mtk_hnat_tproxy_connmark_check_v4 已于 8fb160ffb5 删除。
- **改动文件**: target/linux/mediatek/files-5.4/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c
- **日志 TAG**: [HNAT-TPX-B017-01]
- **PRD 同步**: ✅ N/A（内核路径优化）
- **方案同步**: ✅ N/A
- **测试同步**: ✅ 验证：建立 TCP 连接后多个数据包 FOE 条目保持 BIND 状态
