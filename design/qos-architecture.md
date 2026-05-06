# QoS Hardening Architecture

<!-- FID: F-QOS01 -->

## 1. 架构重构
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 引入物理方向判定 `get_hqos_direction` 以替代废弃的内网猜测代码。
- 保证 `PPPQ_MODE` 和无 QoS 模式的原始行为隔离，彻底防堵状态机溢出风险。

## 2. 确定性 DSCP-to-QID 映射（唯一准绳）
<!-- CID: C-FQOS01-10 | commit: pending | 日期: 2026-05-06 -->

HNAT 内核通过 `iph->tos >> 2`（6-bit DSCP）确定硬件 QID，QoS 标记完全在 FORWARD 链完成：

| DSCP | iptables 规则 | QID | 调度器 | 触发路径 |
|------|--------------|-----|--------|---------|
| 0    | `static_vip_upload_q0` u32 / eqos chain -I HEAD | Q0 | sch0 SP | 110-119.10-39 或 comment=64/vip |
| 1    | `game_upload_109_q1` | Q1 | sch0 SP | 109.x UDP≤300B 上传 |
| 2-30 | eqos chain WRR per-user | Q2-Q30 | sch2 WRR | 哈希槽 `MD5(ip) % 29 + 2` |
| 31   | eqos chain -I HEAD + FORWARD -A tail | Q31 | sch2 WRR BE | 显式限速设备上传 |
| 32   | `static_vip_download_q32` u32 / eqos chain -I HEAD | Q32 | sch1 SP | VIP 下载 |
| 33   | `game_download_109_q33` | Q33 | sch1 SP | 109.x UDP≤300B 下载 |
| 34-62| eqos chain WRR per-user | Q34-Q62 | sch3 WRR | 哈希槽 `wrr_id + 32` |
| 63   | eqos chain -I HEAD + FORWARD -A tail | Q63 | sch3 WRR BE | 显式限速设备下载 |

**IPv4 默认（无 per-device 规则）**：DSCP=2（上传 Q2） / DSCP=34（下载 Q34）

**隔离保证**：
- Q0/Q1 和 Q32/Q33 为 SP（Strict Priority），任何情况下抢占 WRR 流量
- Q31/Q63 的 FORWARD 链末尾覆盖规则（`-A FORWARD`）保证限速设备不被游戏/VIP 规则旁路
- HNAT DSCP 读取路径：`hnat_hqos_ipv4_qid()` 从 `iblk2.qid` 读取绑定时的 QID，与 `iph->tos` 推导的期望 QID 对比，不一致则重新绑定

## 3. QDMA 调度器配置
<!-- CID: C-FQOS01-10 | commit: pending | 日期: 2026-05-06 -->

| 调度器 | 模式 | 队列 | 说明 |
|--------|------|------|------|
| sch0 | SP (Strict Priority) | Q0-Q1 | 上传 VIP+Game |
| sch1 | SP | Q32-Q33 | 下载 VIP+Game |
| sch2 | WRR | Q2-Q30, Q31 | 上传普通+限速 |
| sch3 | WRR | Q34-Q62, Q63 | 下载普通+限速 |

smarthqos=1 时：Q2-Q30 和 Q34-Q62 每个队列配置 min/max rate shaper（per-user 带宽隔离）。

## 4. IPv6 QoS 设计
<!-- CID: C-FQOS01-10 | commit: pending | 日期: 2026-05-06 -->

IPv6 无 DSCP 标记路径（故意 DSCP=0），HNAT 从 `skb->mark` 读 QID：

- **ip6tables eqos chain**（HEAD 插入）: MAC → `MARK --set-mark <wrr_id|31>`（上传）
- **ebtables nat eqos chain**: MAC → `mark --mark-set <wrr_dl|63>`（下载）
- **IPv6 fallback**（TAIL 追加，在 config_foreach 之后）: `--mark 0 → mark=2/34`（未知设备）
- eqos chain 的 per-device MAC 规则在 HEAD 插入，fallback 在 TAIL，确保 per-device 优先

## 5. TProxy/SSR Plus 兼容设计
<!-- CID: C-FQOS01-11 | BID: B-014 | commit: pending | 日期: 2026-05-06 -->

| 组件 | 保护机制 |
|------|---------|
| `loadbalance` PREROUTING NEW | `-m mark ! --mark 0x8000/0x8000` 全程携带 |
| `eqos add` WAN 接口绑定 PREROUTING | `-m mark ! --mark 0x8000/0x8000` 全程携带 |
| 内核 `mtk_hnat_tproxy_protection_v4` | NF_IP_PRI_MANGLE+1，UDP+0x8000 → `memset(FOE)` + `ct->mark |= 0x8000` |
| 内核 `mtk_hnat_tproxy_connmark_check_v4` | INT_MIN+1，检测 `ct->mark & 0x8000` → 提前 memset，消除 UNBIND 窗口 |
| `CONNMARK --restore-mark` | 携带 `$TPROXY_MARK_GUARD` 避免覆盖 TProxy fwmark |

**bit 15 (0x8000) 独占**：eqos 路由标记使用 20/21/22（bits 0-4），QoS DSCP 使用 bits 0-5，均不触碰 bit 15。

## 6. 链生命周期单一所有者
<!-- CID: C-FQOS01-07 | BID: B-010 | commit: pending | 日期: 2026-05-03 -->
- IPv6 `eqos` 链只由 `/usr/sbin/eqos` 管理（无 eqos_apply 链），init.d 不得二次 flush 或追加 FORWARD jump。
- Software tc 与 HNAT 语义 mark 隔离：软件限速只安装 tc class/filter，不追加旧 `MARK 0x99`。
- LuCI 包安装树只保留当前运行脚本，旧 `eqos_origin` 不进入 `root/usr/sbin`。

## 7. 构建配置与预安装脚本边界
<!-- CID: C-FQOS01-08 | BID: B-011 | commit: pending | 日期: 2026-05-03 -->
- `config-5.4` 与 `n60_pro_config_full_new` 的新增 QoS/Netfilter 依赖使用独立注释行解释用途，配置行本身不携带行内注释。
- `install_all_files` 以目录存在性和 glob 结果作为状态机入口，安装失败立即保留现场并返回非零。

## 8. 多 WAN 生命周期触发器
<!-- CID: C-FQOS01-09 | BID: B-012 | commit: pending | 日期: 2026-05-03 -->
- `service_triggers()` 从 `eqos.config.interface` 派生接口列表，和 `loadbalance` 使用的配置来源保持一致。
- 未配置接口列表时使用 `wan wan2..wan8` 兜底。
- sqm restart trigger 仅在 `/etc/init.d/sqm` 可执行时注册。
