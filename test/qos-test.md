# QoS Hardening Tests

<!-- FID: F-QOS01 -->

## 1. 编译性测试
<!-- CID: C-FQOS01-01 | commit: pending | 日期: 2026-05-02 -->
- 修复 `IS_IPV4_DSLITE` 的 `else` 无 `if` 的编译错误。
- 保证无语法警告。

## 2. QoS 回归静态测试
<!-- CID: C-FQOS01-02 | BID: B-001 | commit: pending | 日期: 2026-05-02 -->

### 2a. 脚本语法检查

```sh
sh -n package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos
sh -n package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos
bash -n package/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/loadbalance
sh -n package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/dhcp_mark.sh
sh test/qos-regression.sh
```

### 2b. 当前队列布局（DSCP-to-QID 确定性映射）

**上传方向（sch0=SP Q0-Q1，sch2=WRR Q2-Q30，Q31=限速）**

| DSCP | QID | 调度器 | 说明 |
|------|-----|--------|------|
| 0    | Q0  | sch0 SP | VIP 上传（最高优先） |
| 1    | Q1  | sch0 SP | 109 游戏 UDP 上传 |
| 2-30 | Q2-Q30 | sch2 WRR | 普通 per-user 上传 |
| 31   | Q31 | sch2 WRR+限速 | 限速设备上传 |

**下载方向（sch1=SP Q32-Q33，sch3=WRR Q34-Q62，Q63=限速）**

| DSCP | QID | 调度器 | 说明 |
|------|-----|--------|------|
| 32   | Q32 | sch1 SP | VIP 下载（最高优先） |
| 33   | Q33 | sch1 SP | 109 游戏 UDP 下载 |
| 34-62 | Q34-Q62 | sch3 WRR | 普通 per-user 下载 |
| 63   | Q63 | sch3 WRR+限速 | 限速设备下载 |

**IPv4 默认（无 per-device 规则的普通设备）**：DSCP=2（上传 Q2）和 DSCP=34（下载 Q34）

**IPv6 默认（无 MAC 规则的设备）**：ip6tables eqos `--mark 0 → mark=2`（上传），ebtables eqos `--mark 0 → mark=34`（下载）

### 2c. 关键架构约束

- iptables FORWARD 使用 `DSCP --set-dscp` 直接标记，不使用 CONNMARK 位掩码做 QoS 分类。
- ip6tables FORWARD 设置 `--set-dscp 0`（故意），让 HNAT 从 `skb->mark` 读 QID；若 dscp≠0 则 HNAT 覆盖 mark 导致 per-device 隔离失效。
- 限速设备使用 iptables FORWARD DSCP=31/63 最终覆盖规则，保证即使命中 109 小包/静态 VIP 规则仍进入限速队列。
- HNAT `hnat_hqos_ipv4_queue_matches()` 在 `iph->tos==0`（VIP Q0）时快速返回 true，防止 keepalive 包的 ct->mark 污染 skb->mark 导致误判。

### 2d. 零遗留标记确认

- `0x01/0x01` 在所有脚本和内核代码中不得出现（旧 SSR Plus TProxy mark，已清零）。
- `0x8000/0x8000` 是 TProxy 双锁防护标记，`loadbalance` 和 `eqos add` WAN 接口绑定规则必须带 `-m mark ! --mark 0x8000/0x8000`。

## 3. 多 WAN 接口 CONNMARK 负载均衡测试
<!-- CID: C-FQOS01-05 | BID: B-009 | commit: pending | 日期: 2026-05-02 -->

> **注**: CONNMARK 在当前架构中仅用于多 WAN 负载均衡（不用于 QoS 分类）。

- `loadbalance` 的 PREROUTING NEW 连接使用 `CONNMARK --set-mark 2{idx}` 绑定到指定 WAN 路由表。
- `loadbalance` 的 POSTROUTING `CONNMARK --save-mark` 把 skb->mark 保存到 ct->mark，供 ESTABLISHED 连接恢复。
- `loadbalance` 和 `eqos add` 的 CONNMARK --restore-mark 规则必须带 `-m mark ! --mark 0x8000/0x8000` 保护 SSR Plus TProxy 流量。
- 验证 CONNMARK mark 格式：`2{idx}` = 20、21、22（idx=0,1,2），与 mwan3 bits[15:8] (0xFF00) 无冲突。

## 4. loadbalance POSIX 兼容性测试
<!-- CID: C-FQOS01-05 | BID: B-009 | commit: pending | 日期: 2026-05-02 -->
- `bash -n /usr/sbin/loadbalance` 必须通过（bash 语法检查；loadbalance 使用 bash 数组和 let，不兼容 POSIX sh）。
- 在 busybox ash 环境下通过 `bash /usr/sbin/loadbalance pppoe-wan,pppoe-wan2` 不得报错。

## 5. 宽基线链顺序与遗留脚本回归测试
<!-- CID: C-FQOS01-07 | BID: B-010 | commit: pending | 日期: 2026-05-03 -->
- `init.d/eqos` 不得在 `/usr/sbin/eqos start` 后对 ip6tables eqos 链进行额外 flush（`ip6tables -F eqos` 在 `start_service` 中执行一次，之后 config_foreach 写入 per-device 规则，最后写入 IPv6 fallback）。
- IPv6 per-device MAC MARK 规则（WRR/限速）必须用 `-I eqos 1`（HEAD 插入），IPv6 fallback `--mark 0` 规则必须用 `-A eqos`（TAIL 追加）。这保证 per-device 规则先于 fallback 执行，且 fallback 的 `--mark 0` 条件不覆盖已设置的 wrr_id。
- 不得存在旧 `MARK --set-xmark 0x99/0xFF` 规则（检查历史残留）。
- `root/usr/sbin` 不得安装 `eqos_origin` 旧脚本。

## 6. 构建配置与预安装脚本回归测试
<!-- CID: C-FQOS01-08 | BID: B-011 | commit: pending | 日期: 2026-05-03 -->
- `target/linux/mediatek/mt7986/config-5.4` 与 `n60_pro_config_full_new` 不得出现 `CONFIG_*=y/m` 后跟行内注释的配置行。
- `install_all_files` 必须通过 `sh -n`，必须先检查 `/etc/pre_install` 目录和 `*.ipk` 是否存在，且 `opkg install` 失败时必须返回非零并保留目录。

## 7. 多 WAN 接口触发器回归测试
<!-- CID: C-FQOS01-09 | BID: B-012 | commit: pending | 日期: 2026-05-03 -->
- `init.d/eqos` 的 `service_triggers()` 必须读取 `eqos.config.interface` 并循环注册 trigger，不能只硬编码 `wan/wan2/wan3`。
- 未配置接口列表时必须有 `wan..wan8` 兜底；sqm trigger 必须有 `/etc/init.d/sqm` 可执行检查。

## 8. 新队列布局回归测试
<!-- CID: C-FQOS01-10 | BID: B-013 | commit: pending | 日期: 2026-05-06 -->
- DHCP 自动 WRR 只能分配 `2-30`，下载映射只能为 `34-62`；超过 29 个设备时共享普通 WRR 槽位，禁止使用 `31/63`。
- `dhcp_mark.sh` 必须同时按 IP 和 MAC（`grep -qxF`，精确全行匹配）跳过 UCI 中显式配置的 VIP/限速设备，避免覆盖 `eqos add` 管理的规则。
- `eqos add` 在状态切换前必须清理同一 MAC 的所有 IPv6 WRR/限速旧规则（seq 2-31/34-63 循环删除），再安装新状态规则。
- 显式限速设备必须拥有精确 IP 的 FORWARD 最终覆盖规则（DSCP=31/63），保证即使命中 109 小包或静态 VIP 规则，最终仍进入 Q31/Q63；状态切换和 stop/start 必须清理旧覆盖规则（`/tmp/rl_forward_ips` 持久化）。
- MAC-only 设备必须用 MAC 作为 WRR hash key，IPv4 DSCP 规则必须在 IP 非空时才安装。
- HNAT `mtk_hnat_dscp_update()` 在 HQOS+dscp_en 模式下必须比较 `hnat_hqos_ipv4_qid(entry)` 与 `skb_qid`（基于 iph->tos 推导），不能把合法出口 DSCP 重标记误判为队列变化。

## 9. SSR Plus/TProxy 兼容回归测试
<!-- CID: C-FQOS01-11 | BID: B-014 | commit: pending | 日期: 2026-05-06 -->
- `init.d/eqos` 禁止执行 `iptables -t mangle -F PREROUTING`，避免清空 SSR Plus、PassWall、OpenClash 等透明代理/TProxy 规则。
- eqos 多 WAN 负载均衡重建时只能删除自己安装的精确 PREROUTING/POSTROUTING 规则，再调用 `loadbalance` 重建。
- `loadbalance` 和 `eqos add` WAN 接口绑定的 PREROUTING mark/CONNMARK 规则必须带 `-m mark ! --mark 0x8000/0x8000`，不能覆盖 SSR Plus UDP TProxy 的 `fwmark 0x8000/0x8000`（bit15 专用）。
- `init.d/eqos` 安装 `/etc/hotplug.d/dhcp/99-eqos` 时不得重启 dnsmasq，避免与 SSR Plus 重建 dnsmasq.d 竞争。
- `iface/10-eqos` 只能在配置的 eqos WAN/loadbalance 接口 `ifup` 时触发 `/etc/init.d/eqos start`，不得因 `lan/iptv/zerotier/loopback` 等接口事件反复重建 mangle 规则。
- 内核双钩子 TProxy 防护：`mtk_hnat_tproxy_protection_v4`（NF_IP_PRI_MANGLE+1）首包 memset FOE 并写 ct->mark|=0x8000；`mtk_hnat_tproxy_connmark_check_v4`（INT_MIN+1，从 pre_routing 调用）后续包通过 ct->mark 检测提前 memset FOE，消除 UNBIND 可见窗口。
- 诊断日志必须包含 `[EQOS-B014-*]`，用于在路由器上通过 `logread` 追踪清理过程。
- IPv6 `eqos` 链创建和 `FORWARD`/`POSTROUTING` jump 重建必须幂等，不能产生 chain already exists 噪声或重复 jump。
- IPv6 fallback mark 规则（`--mark 0 → mark=2/34`）必须在 `config_foreach parse_device` 之后追加（init.d/eqos），不能放在 `iptables_start_inital()`（会被 `ip6tables -F eqos` 清除）。
