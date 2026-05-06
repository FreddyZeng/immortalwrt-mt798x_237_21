# CAKE SQM 魔改逻辑深度分析

CAKE (Common Applications Kept Enhanced) 是 Linux 内核的软件 QoS 调度器，工作在 CPU 路径上。这个补丁对标准 CAKE 做了 6 处核心魔改。

## 魔改 1: VIP IP 直通最高优先级 (tin=7)

`cake_select_tin()` 是 CAKE 选择队列的入口函数。魔改在最前面插入了 VIP 检测：

```c
// 在所有标准 CAKE 分类逻辑之前执行
is_priority_ip = is_nat_target_ip_ipv4_k(skb, q);
if (is_priority_ip) {
    return &q->tins[highest_priority_tin];  // 直接返回 tin=7，跳过所有后续逻辑
}
```

### VIP 检测的三层穿透机制

```
数据包到达 CAKE
    │
    ▼
第 1 层: IP 头直接检查
  iph->saddr 或 iph->daddr 在 192.168.110-119.10-39?
    ├── ✅ 命中 → 返回 tin=7 最高优先级
    └── ❌ 未命中 (NAT 后 IP 变了)
         │
         ▼
第 2 层: conntrack 记录查找
  nf_ct_get(skb) 获取连接跟踪
  检查 original/reply tuple 的 IP
    ├── ✅ 命中 → 返回 tin=7
    └── ❌ 无 conntrack 记录
         │
         ▼
第 3 层: 手动 tuple 查找
  nf_ct_get_tuplepr() 构造 tuple
  nf_conntrack_find_get() 查表
    ├── ✅ 命中 → 返回 tin=7
    └── ❌ 全部未命中 → 走标准 CAKE 分类
```

**为什么需要三层？** 因为路由器做 NAT 后，出站包的源 IP 已经变成了 WAN 口 IP（不再是 192.168.110.x）。第 1 层只能匹配内网方向的包，外网回来的包必须通过 conntrack 的 NAT 记录追溯到原始内网 IP。

## 魔改 2: 非 VIP 降级保护

标准 CAKE 中，任何 DSCP=EF 的包都能进入 tin=7。魔改后，只有 VIP IP 才能进 tin=7，其他任何路径到达 tin=7 都被强制降到 tin=6：

```c
// skb->priority 路径
else if (TC_H_MAJ(skb->priority) == sch->handle ...) {
    tin = q->tin_order[TC_H_MIN(skb->priority) - 1];
    if (tin == highest_priority_tin) {
        tin = highest_priority_tin - 1;  // 强制降级！
    }
}
// mark 路径
else if (mark && mark <= q->tin_cnt) {
    tin = q->tin_order[mark - 1];
    if (tin == highest_priority_tin) {
        tin = highest_priority_tin - 1;  // 强制降级！
    }
}
// DSCP 路径
else {
    dscp = cake_handle_diffserv(skb, wash);
    tin = q->tin_index[dscp];
    if (tin == highest_priority_tin) {
        tin = highest_priority_tin - 1;  // 强制降级！
    }
}
```

**效果**：tin=7 是 VIP 专属通道，即使有人在包里伪造 DSCP EF 标记，也只能到 tin=6。

## 魔改 3: diffserv8 映射表修改

标准 CAKE 的 DSCP→tin 映射 vs 魔改后的：

| DSCP | 标准 CAKE | 魔改后 | 变化原因 |
|------|----------|--------|---------|
| CS0 (0) | tin=2 | tin=2 | 不变 |
| CS1 (8) | tin=1 | tin=0 | 背景流量降到最低 |
| EF (46) | tin=7 | tin=7 → 但被降级保护拦截到 tin=6 | EF 不再是最高，VIP 才是 |
| CS6 (48) | tin=6 | tin=5 | 网络控制降级 |
| CS7 (56) | tin=7 | tin=6 | 网络管理降级 |

核心思想：把标准的 "CS6/CS7 = 最高" 改成 "VIP IP = 最高"，原来的最高级全部往下挤一级。

## 魔改 4: tin=7 和 tin=2 特殊配置

```c
for (i = 0; i < q->tin_cnt; i++) {
    if (i == 7) {
        // VIP 专属 tin: 100% 带宽 + interval=10ms + quantum=65535
        cake_set_rate(b, q->rate_bps * 10 / 10, mtu,
                      us_to_ns(q->target), us_to_ns(10000));
        b->tin_quantum = 65535;  // 最大调度权重
    } else if (i == 2) {
        // 默认流量 tin: 90% 带宽 + quantum=65535
        cake_set_rate(b, q->rate_bps * 9 / 10, mtu,
                      us_to_ns(q->target), us_to_ns(100000));
        b->tin_quantum = 65535;
    } else {
        // 其他 tin: 90% 带宽 + 标准 quantum
        cake_set_rate(b, rate, mtu,
                      us_to_ns(q->target), us_to_ns(100000));
        b->tin_quantum = max_t(u16, 1U, quantum);
    }
}
```

| tin | 带宽 | interval | quantum | 用途 |
|-----|------|----------|---------|------|
| 7 (VIP) | 100% | 10ms | 65535 (最大) | VIP 独占，最激进排队 |
| 2 (默认) | 90% | 100ms | 65535 | 默认流量，大权重 |
| 其他 | 90% | 100ms | 标准 | 按比例分配 |

tin=7 interval=10ms 极其激进——标准 CoDel 是 100ms，这里压到 10ms，意味着排队超过 10ms 就开始丢包，保证 VIP 延迟极低。

## 魔改 5: CoDel 全局参数极端调优

```c
// 标准 CAKE:
q->interval = 100000;  // 100ms
q->target   =   5000;  // 5ms

// 魔改后:
q->interval = 10000;   // 10ms  ← 压缩 10 倍！
q->target   =  3000;   // 3ms   ← 压缩 40%
```

**CoDel 算法简述：** 如果队列中包的排队延迟超过 target 且持续 interval 时间，就开始丢包控制延迟。

**魔改效果：** 任何包只要排队超过 3ms 且持续 10ms，就会被丢弃。这对延迟极其敏感的游戏场景有利，但对大文件下载/视频会更激进地丢包。

## 魔改 6: 全局带宽预留

```c
// 标准:
u64 rate = q->rate_bps;

// 魔改:
u64 rate = q->rate_bps * 9 / 10;  // 只使用 90% 带宽
```

预留 10% 带宽作为缓冲，防止链路完全饱和导致排队延迟飙升。

## CAKE 和 HNAT 的关系总结

```
数据包到达路由器
       │
       ▼
┌─ HNAT PPE 检查 ─┐
│  已有 Flow Entry? │
│                   │
│  ✅ 是 (已 offload)│──→ 硬件直接转发（QDMA 队列）
│                   │    CAKE 完全不参与
│  ❌ 否 (新连接)    │
└───────┬───────────┘
        ▼
  走内核协议栈
        │
        ▼
┌─ iptables mangle (FORWARD) ──────────────────────┐
│  VIP 上传 (src 110-119.x)  → DSCP=0  (HNAT→Q0)  │
│  VIP 下载 (dst 110-119.x)  → DSCP=32 (HNAT→Q32) │
│  WRR 设备                  → DSCP=2-30/34-62     │
│  注：CAKE 分类独立使用 IP 范围检查，不依赖 DSCP 值 │
└────────┬──────────────────────────────────────────┘
         ▼
┌─ CAKE qdisc ─────────────────┐
│  is_nat_target_ip_ipv4_k()   │
│  VIP IP? → tin=7 (直通)       │
│  非 VIP? → 标准分类 + 降级保护 │
│  CoDel: 3ms/10ms 激进丢包    │
└────────┬─────────────────────┘
         ▼
┌─ HNAT POST_ROUTING hook ─┐
│  建流 offload → PPE       │
│  记录 qid (基于 DSCP)     │
│  后续包走硬件              │
└──────────────────────────┘
```

CAKE 只处理新连接的前几个包（HNAT offload 前）和无法 offload 的流量。一旦 HNAT 建流成功，后续包全走硬件 QDMA 队列，CAKE 不再参与。

## 109 网段增量补丁 (9999992)

在以上基础上，9999992 补丁新增了 192.168.109.0/24 网段的精细化控制：

- **仅 UDP 且包长 ≤ 300 字节** 的小包走 tin=7 最高优先级（初始实现）
- 大 UDP 和所有 TCP 走标准 CAKE 分类
- 通过通用函数指针架构 `ip_range_check_fn` 消除代码重复

## 后续修正补丁 (9999993~9999996)

**9999993** — `diffserv8[5]` 从 5→4，修正 LE PHB DSCP 的 tin 分配。

**9999994** — 修复 9999992 中 `nf_ct_put` 引用计数泄漏等多个小 Bug。

**9999995** — 为 `highest_priority_tin` 增加初始化（`= 0`）和 `tin_cnt > 1` 边界保护，
防止 besteffort 单 tin 模式下访问越界 tin 数组。

**9999996** — 109 网段游戏加速降为**第二优先级 (tin=6)**，避免与 VIP (tin=7) 争抢最高 tin：

```c
// 9999992 旧实现（已被取代）:
return &q->tins[highest_priority_tin];    // tin=7，与 VIP 同级

// 9999996 修正：
if (highest_priority_tin > 0)
    return &q->tins[highest_priority_tin - 1];  // tin=6，低于 VIP
else
    return &q->tins[highest_priority_tin];
```

**最终 tin 优先级层次（diffserv8 模式）：**

| tin | 用途 | 优先级 |
|-----|------|--------|
| 7 | 192.168.110-119.x VIP 专属（直通，不可伪造）| 最高 |
| 6 | 192.168.109.x 游戏小 UDP (≤300B)，第二优先 | 次高 |
| 5 | 标准 CAKE 高优先级流量 | 第三 |
| 2 | 默认/普通流量 (CS0，quantum=65535) | 大权重 WRR |
| 0 | 背景流量 (CS1 LE) | 最低 |
