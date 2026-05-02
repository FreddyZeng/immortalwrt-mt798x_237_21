# QoS Hardening Architecture

<!-- FID: F-QOS01 -->

## 1. 架构重构
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 引入物理方向判定 `get_hqos_direction` 以替代废弃的内网猜测代码。
- 保证 `PPPQ_MODE` 和无 QoS 模式的原始行为隔离，彻底防堵状态机溢出风险。

## 2. ct_mark 位域定义（唯一准绳）
<!-- CID: C-FQOS01-04 | commit: pending | 日期: 2026-05-02 -->

| 位域 | 掩码 | 含义 | 写入点 | 使用点 |
|------|------|------|--------|--------|
| `bits[5:0]` | `0x3F` | QoS 优先级（0x2E=VIP） | `eqos start` CONNMARK --set-xmark | HNAT: qos_mark==46→Q0/Q32 |
| `bit6` | `0x40` | 上行限速标记 | `eqos add` CONNMARK --set-xmark 0x40/0xC0 | HNAT: (qos_mark&0x40)&&UPLOAD→Q31 |
| `bit7` | `0x80` | 下行限速标记 | `eqos add` CONNMARK --set-xmark 0x80/0xC0 | HNAT: (qos_mark&0x80)&&DOWNLOAD→Q63 |
| `bits[7:6]` | `0xC0` | 双向限速（bit6+bit7）| `eqos add` CONNMARK --set-xmark 0xC0/0xC0 | 上行Q31 + 下行Q63 |
| `bits[15:8]` | `0xFF00` | 路由标记（多 WAN 出口） | `loadbalance` CONNMARK --set-xmark ${FW_MARK}/0xFF00 | `ip rule fwmark` 路由表选择 |

**隔离保证**：`0xFF00 & 0xFF = 0`，路由标记与 QoS 标记零重叠。VIP(0x2E) 的 bit6/bit7 均为 0，不会命中任何限速判断。

## 3. 回归修复设计
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->
- `eqos add` 在进入数值比较前统一归一化 QoS mode，非数字旧备注进入硬件限速模式。
- 方向感知 DSCP 同步：`eqos_apply` 中 `-i br-lan -m mark 0x40/0x40 → DSCP=2`（上行限速），`! -i br-lan -m mark 0x80/0x80 → DSCP=2`（下行限速），VIP mark=46 → DSCP=46 覆盖。HNAT 读取 `qos_mark = skb->mark & 0xFF` 进行方向感知队列分配，彻底消除旧 DSCP2/MARK2 单值的双向降级回归。
- `eqos add` 在安装限速分类前统一归一化上传/下载速度；上传为 0 时不安装 bit6，下载为 0 时不安装 bit7。
- CAKE 修复通过 `9999995-fix-cake-highest-tin-guard.patch` 叠加在既有 CAKE 补丁之后，将 `highest_priority_tin` 初始化为 0，限制 VIP/109 直达最高 tin 仅在多 tin 模式生效，并移除 `TC_PRIO_MAX` 对最高 tin 的直接绕过。
- `docs/verify-vip-qos.sh` 直接呈现 HNAT 映射后的 Q0-Q31/Q32-Q63 含义，普通流量展示为 hash 队列范围，可信 VIP 下行展示为 DSCP46/MARK46 到 Q32，限速设备展示为 MARK0xC0 到 Q63。

## 4. CONNMARK 首包还原设计
<!-- CID: C-FQOS01-05 | BID: B-008 | commit: pending | 日期: 2026-05-02 -->
**问题**：`CONNMARK --set-xmark` 仅写入 `ct->mark`，不修改当前包的 `skb->mark`（Linux 5.4 xt_connmark.c XT_CONNMARK_SET 分支无 nfmask 写回）。若 `eqos_apply` 的 restore-mark 仅覆盖 `ESTABLISHED,RELATED`，则 NEW 首包携带 mark=0 进入 HNAT 建表，VIP/限速队列漏判。

**修复**：`eqos_apply` 的 `CONNMARK --restore-mark --nfmask 0xFF --ctmask 0xFF` 覆盖 `NEW,ESTABLISHED,RELATED` 三态。执行顺序保证：FORWARD chain 中 eqos 链先于 eqos_apply 链，set-xmark 写入 ct_mark 后，同一包在 eqos_apply 阶段被 restore-mark(NEW) 正确还原到 skb->mark。

## 5. 多 WAN 兼容设计
<!-- CID: C-FQOS02-01 | BID: B-009 | commit: pending | 日期: 2026-05-02 -->
- `loadbalance` 完全重写为 POSIX sh，移除 bash 专有数组语法 `array=()`、`${//}` 字符串替换和 `let` 算术，改用 `tr ','  ' '`、`$(())`，添加 `#!/bin/sh` shebang。
- `init.d/eqos` 直接执行 `/usr/sbin/loadbalance`，不再通过 `bash` 调用。
- 路由 mark 格式 `printf "0x%02x00" "2${i}"`，确保 bits[15:8] 非零且各 WAN 接口互不重叠，掩码 `/0xFF00` 全程携带。
