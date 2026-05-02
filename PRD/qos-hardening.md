# QoS Hardening PRD

<!-- FID: F-QOS01 -->

## 1. 核心需求
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
重构 MT798x HNAT 硬件流控的数据路径，实现精准的物理端口分流、消除内网子网猜测、修复编译语法错误，并保证关闭 QoS 后的安全降级。

## 2. 回归修复需求
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->
- 硬件限速设备的上行规则必须通过 `CONNMARK --set-xmark 0x40/0xC0` 写入 bit6；下行规则通过 `CONNMARK --set-xmark 0x80/0xC0` 写入 bit7；双向限速写入 `0xC0`。HNAT `hnat_nf_hook.c` 按方向感知模式匹配：`(qos_mark & 0x40) && UPLOAD → Q31`，`(qos_mark & 0x80) && DOWNLOAD → Q63`，消除旧 DSCP2/MARK2 的双向降级回归。
- eqos 指定 VIP 设备通过 `CONNMARK --set-xmark 46/0xFF` 写入 ct_mark；`eqos_apply` 中 `CONNMARK --restore-mark --nfmask 0xFF --ctmask 0xFF` 覆盖 `NEW,ESTABLISHED,RELATED` 三种状态（NEW 状态必须覆盖，否则首包 skb->mark 为 0 导致 HNAT 建表时漏判），将 ct_mark=46 还原到 skb->mark；HNAT 识别 `qos_mark == 46 && dir == DOWNLOAD` 映射 Q32，未命中可信 VIP 标记的外部下行 EF 降级为 DSCP44/Q34。
- 硬件限速速度为 0 的方向不得安装对应的限速 bit（up=0 不安装 0x40，dl=0 不安装 0x80）；ct_mark 使用 `0xC0` 掩码与 VIP 的 `0xFF` 掩码精确隔离，防止 mwan3 路由 bits[15:8] (0xFF00) 与 QoS bits[7:0] 碰撞。
- 旧版 `comment` 文本配置必须归一化为硬件限速模式，避免非数字模式值中断 `eqos add`。
- CAKE 最高 tin 变量必须有确定初值，且只有 VIP 或 109 小 UDP 在多 tin 模式命中时能够直接进入最高 tin；该修复由补丁栈末尾的独立 CAKE 修复补丁承载。
- 现场验证脚本展示的 DSCP 队列含义必须以 HNAT `dscp_to_queue()` 为唯一准绳，避免把未映射的 DSCP 41-45 展示为固定优先队列。

## 3. 多 WAN 兼容需求
<!-- CID: C-FQOS02-01 | commit: pending | 日期: 2026-05-02 -->
- `loadbalance` 脚本必须为 POSIX sh 兼容（不得使用 bash 专有数组语法 `array=()`），避免在无 bash 固件上运行失败。
- 路由标记使用 `bits[15:8]` (掩码 `0xFF00`)，与 QoS 语义标记 `bits[7:0]` 完全隔离；`iptables --set-xmark` 和 `ip rule fwmark` 均需携带 `/0xFF00` 掩码，防止覆盖 QoS 低位。
- `init.d/eqos` 调用 loadbalance 不得硬依赖 `bash`，直接执行 POSIX 脚本。
