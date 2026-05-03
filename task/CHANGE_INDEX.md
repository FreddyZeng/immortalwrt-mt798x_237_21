# 变更索引

> 通过 FID 查看某个需求的所有相关改动。
> 格式参考: smart-commit SKILL.md §5.3

<!-- 下一个 FID 编号: F-002 -->
<!-- 下一个 BID 编号: B-013 -->
<!-- 下一个 CID 编号: C-FQOS01-10 -->

---

## F-QOS01: MT798x QoS Datapath Hardening 【活跃】
- PRD: PRD/qos-hardening.md
- Design: design/qos-architecture.md
- Test: test/qos-regression.sh
- ADRs:
- Diagnostics:
- Releases:
- Changes:
  | CID | Commit | PR | 日期 | 描述 | 状态 |
  |-----|--------|-----|------|------|------|
  | C-FQOS01-01 | pending | - | 2026-05-02 | MT798x HNAT datapath dead-code cleanup, syntax fix, and fallback QoS refactoring | ✅ 已完成 |
  | C-FQOS01-02 | pending | - | 2026-05-02 | Fix QoS regression: replace DSCP2/MARK2 with direction-aware 0x40/0x80 bit-field CONNMARK; trusted VIP CONNMARK 46; CAKE highest tin guard; verify queue labels | ✅ 已完成 |
  | C-FQOS01-03 | pending | - | 2026-05-02 | Refactor DOWNLOAD QoS marking logic to cleanly isolate IPv4 and IPv6 rule sets | ✅ 已完成 |
  | C-FQOS01-04 | pending | - | 2026-05-02 | Refactor eqos ruleset to unified CONNMARK architecture with 0x40/0x80/0xC0 direction bits; directional DSCP sync in eqos_apply; exhaustive atomic rule deletion; VIP CONNMARK 46/0xFF; ebtables removed | ✅ 已完成 |
  | C-FQOS02-01 | pending | - | 2026-05-02 | Migrate Multi-WAN loadbalance and eqos routing marks to bits[15:8] (0xFF00) to isolate from QoS bits[7:0] | ✅ 已完成 |
  | C-FQOS01-05 | pending | - | 2026-05-02 | Fix eqos_apply restore-mark to cover NEW ctstate (首包 HNAT 建表漏判); rewrite loadbalance as POSIX sh (remove bash dependency); init.d drops bash hardcall | ✅ 已完成 |
  | C-FQOS01-06 | pending | - | 2026-05-02 | Sync PRD/design docs to current 0x40/0x80/0xC0 architecture; add ct_mark bit-field table; remove all DSCP2/MARK2 references | ✅ 已完成 |
  | C-FQOS01-07 | pending | - | 2026-05-03 | Fix wide-baseline QoS audit regressions: single-owner IPv6 chain lifecycle, remove software tc legacy MARK writes, delete shipped eqos_origin backup script | ✅ 已完成 |
  | C-FQOS01-08 | pending | - | 2026-05-03 | Fix wide-baseline build hygiene regressions: remove Kconfig inline value comments and make pre-install ipk script fail-safe | ✅ 已完成 |
  | C-FQOS01-09 | pending | - | 2026-05-03 | Fix multi-WAN interface lifecycle triggers to cover configured interfaces and wan..wan8 fallback | ✅ 已完成 |
- Bugs:
  | BID | 描述 | 引入者 | 修复者 | 状态 |
  |-----|------|--------|--------|------|
  | B-001 | QoS 回归审计修复（旧 DSCP2/MARK2 双向降级） | C-FQOS01-01 | C-FQOS01-02 | 已修复 |
  | B-002 | CONNMARK 高位掩码防 mwan3 冲突 | C-FQOS01-04 | C-FQOS01-04 | 已修复 |
  | B-003 | 首包进入 HNAT 建表时 mark=0 漏判（eqos_apply 未覆盖 NEW 状态） | C-FQOS01-04 | C-FQOS01-05 | 已修复 |
  | B-004 | 遗留 --set-mark 破坏 mwan3 路由标记（无掩码覆盖低8位） | C-FQOS01-04 | C-FQOS01-04 | 已修复 |
  | B-005 | CAKE vs HNAT Priority Asymmetry | F-QOS-AUDIT | F-QOS-AUDIT | 已修复 |
  | B-006 | HNAT QoS 7 Logic Flaws | F-QOS-AUDIT | F-QOS-AUDIT | 已修复 |
  | B-007 | mtk_eth_soc.c mark leak & state collision（CPU TX 路径语义 mark 误当 qid） | F-QOS-AUDIT | C-FQOS01-04 | 已修复 |
	  | B-008 | loadbalance/eqos 顶层使用 local 关键字导致运行时失败 | C-FQOS01-04 | C-FQOS01-05 | 已修复 |
	  | B-009 | loadbalance 依赖 bash 专有语法但包未声明 +bash 依赖 | C-FQOS02-01 | C-FQOS01-05 | 已修复 |
	  | B-010 | IPv6 链顺序被 init.d 二次管理破坏、Software tc 旧 MARK 污染 HNAT、eqos_origin 被安装 | C-FQOS01-06 | C-FQOS01-07 | 已修复 |
	  | B-011 | Kconfig 行内注释可能导致依赖失效，预安装脚本失败后删除 ipk 现场 | C-FQOS01-07 | C-FQOS01-08 | 已修复 |
	  | B-012 | 多 WAN 接口 up trigger 只覆盖 wan1-3，wan4-8 或自定义接口恢复不触发重建 | C-FQOS01-08 | C-FQOS01-09 | 已修复 |

<!-- 新增 Feature 在此下方添加 -->
