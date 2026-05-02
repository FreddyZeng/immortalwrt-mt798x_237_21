# 变更索引

> 通过 FID 查看某个需求的所有相关改动。
> 格式参考: smart-commit SKILL.md §5.3

<!-- 下一个 FID 编号: F-002 -->
<!-- 下一个 BID 编号: B-002 -->

---

## F-QOS01: MT798x QoS Datapath Hardening 【活跃】
- PRD: PRD/qos-hardening.md
- Design: design/qos-architecture.md
- Test: test/qos-test.md
- ADRs: 
- Diagnostics: 
- Releases: 
- Changes:
  | CID | Commit | PR | 日期 | 描述 | 状态 |
  |-----|--------|-----|------|------|------|
  | C-FQOS01-01 | pending | - | 2026-05-02 | MT798x HNAT datapath dead-code cleanup, syntax fix, and fallback QoS refactoring | ✅ 已完成 |
  | C-FQOS01-02 | pending | - | 2026-05-02 | Fix QoS regression findings for IPv6 limit DSCP/mark, trusted VIP download Q32 marker, zero-speed limit cancellation, exact mark matching, legacy mode parsing, CAKE highest tin guard, and verification queue labels | ✅ 已完成 |
  | C-FQOS01-03 | pending | - | 2026-05-02 | Refactor DOWNLOAD QoS marking logic to cleanly isolate IPv4 and IPv6 rule sets | ✅ 已完成 |
  | C-FQOS01-04 | pending | - | 2026-05-02 | Refactor eqos ruleset to a unified CONNMARK architecture, solving IPv6 HNAT bypass | ✅ 已完成 |
- Bugs:
  | BID | 描述 | 引入者 | 修复者 | 状态 |
  |-----|------|--------|--------|------|
  | B-001 | QoS 回归审计修复 | C-FQOS01-01 | C-FQOS01-02 | 已修复 |
  | B-002 | CONNMARK 高位掩码防 mwan3 冲突 | C-FQOS01-04 | C-FQOS01-04 | 已修复 |
  | B-003 | 第一包漏判导致硬件卸载队列错误 | C-FQOS01-04 | C-FQOS01-04 | 已修复 |

<!-- 新增 Feature 在此下方添加 -->
