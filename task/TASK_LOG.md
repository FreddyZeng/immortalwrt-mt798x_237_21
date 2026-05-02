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

## [2026-05-02] C-FQOS01-04 | commit: pending

- **FID**: F-QOS01
- **CID**: C-FQOS01-04
- **类型**: refactor
- **范围**: luci-app-eqos-mtk, tests
- **描述**: Refactor eqos ruleset to a unified CONNMARK architecture. Replaced all ebtables and IP-based DSCP rules with global CONNMARK tracking. Solved IPv6 hardware offload bypass issue and unified QoS tracking for both IPv4 and IPv6.
- **改动文件**: root/usr/sbin/eqos, root/etc/init.d/eqos, test/qos-regression.sh
- **PRD 同步**: ✅ PRD/qos-hardening.md
- **方案同步**: ✅ design/qos-architecture.md
- **测试同步**: ✅ test/qos-regression.sh
