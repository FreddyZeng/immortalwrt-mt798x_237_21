# QoS Hardening PRD

<!-- FID: F-QOS01 -->

## 1. 核心需求
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
重构 MT798x HNAT 硬件流控的数据路径，实现精准的物理端口分流、消除内网子网猜测、修复编译语法错误，并保证关闭 QoS 后的安全降级。

## 2. 确定性 DSCP QoS 架构需求
<!-- CID: C-FQOS01-10 | BID: B-013 | commit: pending | 日期: 2026-05-06 -->

> **核心原则**：QoS 标记通过 iptables FORWARD 链 `DSCP --set-dscp` 完成，HNAT 内核通过 `iph->tos >> 2` 读取 DSCP 确定 QID，不使用 CONNMARK 做 QoS 分类。

### 2a. 队列布局（DSCP-to-QID 确定性映射）

| DSCP | QID | 调度器 | 优先级 | 说明 |
|------|-----|--------|--------|------|
| 0    | Q0  | sch0 SP | 最高 | VIP 设备上传 |
| 1    | Q1  | sch0 SP | 次高 | 109 游戏 UDP≤300B 上传 |
| 2-30 | Q2-Q30 | sch2 WRR | 普通 | per-user 上传（确定性哈希槽） |
| 31   | Q31 | sch2 WRR BE | 最低 | 限速设备上传 |
| 32   | Q32 | sch1 SP | 最高 | VIP 设备下载 |
| 33   | Q33 | sch1 SP | 次高 | 109 游戏 UDP≤300B 下载 |
| 34-62| Q34-Q62 | sch3 WRR | 普通 | per-user 下载（确定性哈希槽） |
| 63   | Q63 | sch3 WRR BE | 最低 | 限速设备下载 |

### 2b. FORWARD 链规则执行顺序（DSCP 最后匹配胜出）

1. 全局 fallback: `DSCP 2`（所有 LAN 上传）/ `DSCP 34`（所有 LAN 下载）
2. eqos chain: per-device 规则（VIP DSCP 0/32、限速 DSCP 31/63、WRR DSCP 2-30/34-62）
3. 游戏规则: 109.x UDP≤300B → DSCP 1/33
4. 静态 VIP u32: 192.168.110-119.10-39 → DSCP 0/32
5. **限速设备末尾覆盖**（`-A FORWARD`）: 明确限速 IP → DSCP 31/63（保证胜过游戏/VIP 规则）

### 2c. IPv6 QoS 路径

- iptables FORWARD: `DSCP --set-dscp 0`（故意），让 HNAT 从 `skb->mark` 读 QID
- ip6tables eqos chain: MAC 规则 `-j MARK --set-mark <wrr_id|31>`（HEAD 插入）
- ebtables nat eqos chain: `-j mark --mark-set <wrr_dl|63>`（下载方向 MAC → mark）
- IPv6 fallback: `--mark 0 → mark=2/34`，在 `config_foreach parse_device` 之后追加（TAIL）

### 2d. 限速设备硬件 shaper

- Q31/Q63 通过 `/sys/kernel/debug/hnat/qdma_txq31` 和 `qdma_txq63` 配置 `max_rate` shaper
- `max_rate = max(所有限速设备的 up)` 取最大值写入 Q31，dl 同理
- 多设备共享 Q31/Q63，WRR BE 调度确保拥塞时让位给 VIP 和普通 WRR

### 2e. TProxy/SSR Plus 兼容约束

- bit 15 (`0x8000/0x8000`) 专用于 SSR Plus TProxy fwmark，绝不被 eqos 覆盖
- 所有 PREROUTING mark/CONNMARK 规则必须携带 `-m mark ! --mark 0x8000/0x8000`
- 内核双钩子防护：`mtk_hnat_tproxy_protection_v4`（NF_IP_PRI_MANGLE+1）首包 memset FOE + 写 ct->mark|=0x8000；`mtk_hnat_tproxy_connmark_check_v4`（INT_MIN+1）后续包提前 memset，消除 UNBIND 可见窗口

### 2f. CAKE SQM 兼容

- VIP 流量（110-119.10-39）在 CAKE 中进入 tin 7（最高 tin）
- 109 游戏 UDP≤300B 进入 tin 6（次高 tin），不与 VIP 争抢 tin 7
- 所有 VIP/游戏 CAKE tin 逻辑在 `q->tin_cnt > 1` 时才激活，单 tin 模式完全降级

## 3. 多 WAN 兼容需求
<!-- CID: C-FQOS01-11 | commit: pending | 日期: 2026-05-06 -->
- `loadbalance` 脚本使用 bash（需 `+bash` 包依赖），使用 bash 数组语法 `array=()` 和 `let`。
- 路由标记格式 `2"$i"`（20/21/22），`ip rule fwmark 2"$i" table 2"$i"0`（路由表 200/210/220）。
- 多 WAN 负载均衡使用 `--mode nth --every $PPP_NUM --packet $i` 轮询分配新连接。
- WAN 接口路由查询使用 `ip route show default dev $var`（精确接口匹配，避免前缀误配）。
- `loadbalance` 和 `eqos add` 的所有 PREROUTING NEW mark/CONNMARK 规则必须携带 `$TPROXY_MARK_GUARD`。

## 4. 宽基线回归需求
<!-- CID: C-FQOS01-07 | BID: B-010 | commit: pending | 日期: 2026-05-03 -->
- IPv6 `eqos` 链只由 `/usr/sbin/eqos` 管理（无 eqos_apply 链）；init.d 不得二次 flush 或追加 FORWARD jump。
- Software tc 模式不得写入旧 `MARK 0x99` 规则；旧 MARK 只能被清理，不能作为新规则安装。
- LuCI 包安装树不得携带旧版 `eqos_origin` 运行脚本。

## 5. 构建与预安装稳定性需求
<!-- CID: C-FQOS01-08 | BID: B-011 | commit: pending | 日期: 2026-05-03 -->
- MT7986 内核配置与 N60 PRO 构建配置新增项必须保持 `CONFIG_SYMBOL=value` 纯值格式，说明文字只能写在独立注释行。
- 预安装脚本必须区分目录不存在、目录为空、存在 ipk、安装失败四种状态；仅在存在 ipk 且 `opkg install` 成功后清理 `/etc/pre_install`。

## 6. 多 WAN 生命周期触发需求
<!-- CID: C-FQOS01-09 | BID: B-012 | commit: pending | 日期: 2026-05-03 -->
- 接口 up trigger 必须覆盖 `eqos.config.interface` 中配置的全部 WAN 接口；未配置时必须覆盖 `wan..wan8`。
- `sqm` 联动 trigger 必须在 `/etc/init.d/sqm` 存在且可执行时注册，避免无 sqm 镜像出现无效 trigger 动作。
