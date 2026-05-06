# Bug 记录索引

| BID | 标题 | 关联 FID | 修复 CID | 状态 |
|-----|------|----------|----------|------|
| [B-001](B-001.md) | QoS 回归审计修复（旧 DSCP2/MARK2 双向降级） | F-QOS01 | C-FQOS01-02 | ✅ 已修复 |
| B-002 | CONNMARK 高位掩码防 mwan3 冲突 | F-QOS01 | C-FQOS01-04 | ✅ 已修复 |
| B-003 | 首包进入 HNAT 建表时 mark=0 漏判（eqos_apply 未覆盖 NEW 状态） | F-QOS01 | C-FQOS01-05 | ✅ 已修复 |
| [B-004](B-004.md) | 遗留 --set-mark 破坏 mwan3 路由标记（无掩码覆盖低8位） | F-QOS01 | C-FQOS01-04 | ✅ 已修复 |
| [B-005](B-005.md) | CAKE vs HNAT Priority Asymmetry for 109 Subnet | F-QOS01 | F-QOS-AUDIT | ✅ 已修复 |
| B-006 | HNAT QoS 7 Logic Flaws | F-QOS01 | F-QOS-AUDIT | ✅ 已修复 |
| B-007 | mtk_eth_soc.c mark leak & state collision（CPU TX 路径语义 mark 误当 qid） | F-QOS01 | C-FQOS01-04 | ✅ 已修复 |
| B-008 | loadbalance/eqos 顶层使用 local 关键字导致运行时失败 | F-QOS01 | C-FQOS01-05 | ✅ 已修复 |
| B-009 | loadbalance 依赖 bash 专有语法但包未声明 +bash 依赖 | F-QOS01 | C-FQOS01-05 | ✅ 已修复 |
| [B-010](B-010.md) | IPv6 链顺序被 init.d 二次管理破坏、Software tc 旧 MARK 污染 HNAT、eqos_origin 被安装 | F-QOS01 | C-FQOS01-07 | ✅ 已修复 |
| [B-011](B-011.md) | Kconfig 行内注释可能导致依赖失效，预安装脚本失败后删除 ipk 现场 | F-QOS01 | C-FQOS01-08 | ✅ 已修复 |
| [B-012](B-012.md) | 多 WAN 接口 up trigger 只覆盖 wan1-3，wan4-8 或自定义接口恢复不触发重建 | F-QOS01 | C-FQOS01-09 | ✅ 已修复 |
| [B-013](B-013.md) | 限速设备在命中游戏/VIP 高优先规则后 DSCP=31/63 最终覆盖缺失，Q31/Q63 限速器被旁路 | F-QOS01 | C-FQOS01-10 | ✅ 已修复 |
| [B-014](B-014.md) | TProxy/SSR Plus bit 0x8000 冲突、DHCP hotplug 非幂等安装、IPv6 fallback 位置错误、接口触发不过滤 | F-QOS01 | C-FQOS01-11 | ✅ 已修复 |
| [B-015](B-015.md) | loadbalance grep $var 前缀匹配：pppoe-wan 误匹配 pppoe-wan2，路由表 200 使用错误网关 | F-QOS01 | C-FQOS01-12 | ✅ 已修复 |
