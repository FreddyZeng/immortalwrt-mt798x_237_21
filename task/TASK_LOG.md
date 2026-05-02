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
