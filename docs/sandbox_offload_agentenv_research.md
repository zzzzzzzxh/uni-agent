# AgentEnv 运行态卸载与恢复能力核查

核查日期：2026-10-21。本文只记录公开官方文档与源码核查阶段的证据；后续部署、实测与实现见 [结果报告](sandbox_offload_results.md)，不能把源码能力核实当成性能测量。

方案决策：本轮 Demo 已选定 AgentEnv 为唯一后端，按下述固定 revision 设计同节点 pause/resume 实验。具体接线与验收见 [调度方案](sandbox_offload_design.md) 和 [Demo 规格](sandbox_offload_demo_plan.md)；对其他后端的比较不构成本轮依赖。

## 结论

AgentEnv **已有运行态快照、真正卸载与恢复的实现链路**。控制面 `pause` 会保存 VM 状态、内存和可写磁盘状态，持久化暂停记录，再停止 Firecracker 并释放该运行实例的设备与网络资源；`resume` 创建新运行实例并加载保存状态。它适合作为后续验证候选，但不能直接证明当前 OpenYuanRong / `akernel_sdk` endpoint 也有该能力。[A1][A2][A3][A4]

必须区分三件事：

| 操作 | AgentEnv 的实际行为 | 能否作为模型推理期间的资源卸载 |
| --- | --- | --- |
| `snapshot create` | 暂停捕获，再原地恢复；原沙箱返回 Running；生成可复用快照 | 单独执行不能，源 VM 仍在运行 |
| 控制面 `pause` / `resume` | 保存当前状态、停止 VM；随后新建运行实例恢复 | 能作为候选，物理释放量和恢复成本待测 |
| 底层 Firecracker 原地 `pause` / `resume` | 暂停与恢复 vCPU，原实例继续存在 | 不能等同于完整 offload；必须走停止 VM 的控制面路径 |

第一、三行的差别可由 `FirecrackerSandbox::snapshot` 和两个不同的 resume 路径直接复核。[A3][A4]

**最重要的限制**：普通 pause 的产物属于沙箱 persister，而不是已发布的共享 snapshot repository；支持 OSS 快照不等于普通 pause 已提供跨节点恢复。暂停成功的 API 响应也不足以证明所有资源都已回收，因为部分清理失败只记录日志。[A2][A5][A6]

## 版本与证据范围

| 来源 | Revision | 本轮状态 |
| --- | --- | --- |
| 既有本地证据目录 `artifacts/sandbox_concurrency_research/repos/AgentEnv` | `0a7338443eb67137492326dfa53f511ae5db128d` | 已核对 remote 为官方仓库；`git status --short` 为空；没有更新 checkout |
| 2026-10-21 在线官方 main | `a27b2db909b035f58696ba8798ea0e285c7bfa17` | 提交时间为 2026-10-20；GitHub compare 显示比本地版本前进 221 个提交；本文最新能力与行号以该 SHA 为准 |

版本查询入口：[官方 main 提交](https://api.github.com/repos/kvcache-ai/AgentENV/commits/main)、[固定版本比较](https://github.com/kvcache-ai/AgentENV/compare/0a7338443eb67137492326dfa53f511ae5db128d...a27b2db909b035f58696ba8798ea0e285c7bfa17)。本文所有源码链接均固定 SHA，避免 main 变化后结论失去版本依据。

旧版 `docs/src/concepts/sandboxes.md` 曾笼统声称恢复包含打开的网络连接；最新版工作说明只承诺文件系统、进程、环境变量和内存恢复。结合新实例、新网络 namespace 和可变 host IP 的实现，本方案不能承诺外部 TCP / WebSocket 会话透明存续。[A1][A7][A18]

## 从 API 到实际资源释放

### 暂停

公开入口是 `POST /sandboxes/{sandboxID}/pause`；成功返回 204，不存在返回 404，状态冲突返回 409，其余失败返回 500。[A8]

执行顺序如下：[A2][A3]

1. CAS 将 Running 改为 Pausing。同一沙箱重复 pause 会等待已有暂停操作，已 Paused 则直接成功。
2. 固定恢复所依赖的镜像引用，并分配暂停产物目录；这些步骤失败时回到 Running。
3. 从运行集合和代理路由表摘除实例，调用后端 pause。
4. 对可写持久卷执行同步，再暂停 VM；保存 VM state、内存页对应的 OverlayBD 层及文件系统状态。增量内存捕获利用 dirty ranges；不能仅凭分配内存大小估算本次写盘量。
5. 写入 paused state、持久记录与 Paused 元数据。
6. 停止 Firecracker，释放 ublk 设备引用和网络 slot，发布 Pause 事件。

`service.rs:1612-1626` 中，Paused 元数据先于 `stop()` 完成写入；`stop()` 失败只告警，最终仍可能返回成功。`resources.rs:62-129` 也对设备释放失败采取日志告警。因此，**Paused 状态、204 响应、allocated 指标下降是逻辑证据，不是物理内存和设备释放的充分证据**。后续 Demo 必须检查 Firecracker 进程退出、设备引用与宿主机指标。[A2][A5]

底层停止过程先发送 SIGTERM，超时后尝试 SIGKILL 并等待退出；设备清理在 VM 停止之后执行。异常析构不能替代正常清理：文档注释明确指出部分 daemon 管理的设备可跨沙箱 drop 存活。[A5][A9]

### 恢复

公开入口是 `POST /sandboxes/{sandboxID}/resume`；成功返回 201 和沙箱模型，可设置恢复后的 timeout。[A8]

该 `/resume` 入口在固定版 OpenAPI 中已标记弃用。本轮 Demo 使用推荐的 `POST /v2/sandboxes/{sandboxID}/connect`：Paused 恢复为 201，已运行实例为 200；仍须执行工具就绪检查。这里保留旧入口说明用于对应此前的实现证据。[固定版 OpenAPI](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/api/openapi.yml#L1715-L2358)

控制面检查 Paused 状态和虚拟化模式，CAS 到 Resuming，标记持久记录，再进入 `launch_sandbox`。该路径恢复 rootfs / 挂载设备，申请网络 slot，构造新的 envd client，加载 file-backed 内存快照，恢复 VM，等待 envd 就绪后发布 Running 和路由。同一沙箱的并发 resume 共享进行中的恢复过程。[A2][A4][A10]

这仍不是工具服务 SLA：envd ready 不代表 `swe-rex` 的 8000 端口、外部转发、应用状态和第一条真实命令都已就绪；这些必须另外验证。内存采用 file-backed 设备，底层可能在后续访问中继续产生缺页和存储读取，因此只测 resume API 返回时间会漏掉第一条工具命令的恢复成本。[A4][A10]

### 资源释放边界

| 资源 | 代码支持的判断 | 不能据此声称的收益 | 后续应观测 |
| --- | --- | --- | --- |
| 沙箱 vCPU 执行 | VM 停止后 guest 不再运行 | 释放物理 CPU 核，或释放 Ray task 已申请的 CPU | VM 线程消失、CPU time、宿主调度压力 |
| guest / VMM 私有内存 | Firecracker 退出可解除该进程的内存映射 | 节省量等于沙箱配置内存；整机 used memory 必然降至相同数值 | 进程 PSS、cgroup anon/file、MemAvailable、增量对照 |
| 宿主 page cache / 共享内存页 | 快照和存储可共享宿主 page cache | pause 清空 page cache，或共享页可按每 VM RSS 重复计费 | file cache、共享设备持有者、缓存热/冷分组 |
| ublk / rootfs / memory 设备 | 正常 stop 释放设备或引用；共享引用不等于销毁所有底层对象 | 设备、daemon 与缓存总开销归零 | 活跃设备、引用、daemon RSS、warm pool 库存 |
| 网络 | 释放本次实例的 network slot；恢复可分配不同 host IP | 旧 tunnel、socket、TCP 会话永远可用 | 重连次数、外部健康检查、旧连接失败类型 |
| active 资源账本 | Paused 不计入 active allocated CPU/memory | 所有配额和 admission 槽都已释放 | active 与 including-paused 两类指标 |
| 存储 | 快照和暂停记录继续占磁盘；后续恢复需读入 | offload 同时释放磁盘 | 逻辑快照大小、物理分配字节、写读字节、IOPS、带宽 |
| 远端模型 GPU / KV cache | 本次核查没有与模型服务资源生命周期联动的证据 | 卸载沙箱就释放推理 GPU 或 KV cache | 模型侧单独记账 |

表中 CPU、内存与设备结论来自停止与资源管理路径；缓存结论来自官方架构说明。宿主观测方法与不能推导的收益是本次设计判断。[A4][A5][A9][A11]

AgentEnv 在 `orchestrator/metrics.rs:58-109` 将 Paused 与 active 资源拆分，保留 `paused_allocated_cpu` 和 `paused_allocated_memory_bytes`。调度器另有 `MaxSandboxCountIncludingPaused`、`MaxAllocatedCPUIncludingPaused`、`MaxAllocatedMemoryBytesIncludingPaused`，可将暂停沙箱仍计入上限。因此需要区分“物理资源减小”“active 账本减小”和“可再放置的资源容量增大”。[A12][A13]

## 持久性、网络与兼容性

- **进程连续性**：公开文档承诺恢复暂停时刻的进程和内存；这支持进程内哨兵、随机状态、工作目录及打开文件偏移的后续验证。它不证明外部数据库事务、锁租约、HTTP 请求等副作用可回滚。[A1]
- **普通 pause 持久性**：`persisted_sandbox_store_path` 下的 `records.db` 与每代 artifact 支持服务重启恢复；不是共享 repository 的 committed snapshots。默认节点文件丢失后的恢复能力未被证明。[A6]
- **跨节点恢复**：已发布 snapshot 可使用共享 POSIXFS / OSS 和节点本地缓存；同一个 paused sandbox 的自动迁移、owner 切换、网络身份及故障转移，需要独立验证，不能由共享 snapshot 能力推导。[A6][A14]
- **网络身份**：同一 sandbox ID 跨周期保持；`sandboxInstanceId` 每次 start/resume 更新，过期 stop hook 必须按实例代际过滤。`hostInteractionIp` 可变化，命令连接和 `swe-rex` 客户端需要重建或重新解析目标。[A7]
- **兼容性**：KVM 与 PVM 暂停产物不可互相恢复；恢复还需要可用的 ublk daemon 及匹配的运行依赖。本轮没有证明跨 CPU 架构、任意 Firecracker/内核版本或 GPU 设备状态可恢复。[A4][A15]
- **保留成本**：快照存储、基础镜像引用和缓存有独立生命周期；删除源沙箱不必然删除已发布快照，应显式规定快照 TTL 与清理策略。[A1][A6]

## 并发、自动恢复与失败语义

| 场景 | 已有行为 | 上层调度含义 |
| --- | --- | --- |
| 重复 pause / resume | CAS 和等待现有转换，已处于目标状态可直接成功 | 利用同一 sandbox ID 对账；仍需单所有者和 generation，不能把命令重试等同生命周期重试 |
| 客户端超时/取消 | 生命周期在后台独立任务中继续运行 | 超时后状态为未知；查询实际状态后再决定下一步 |
| 暂停前置准备失败 | 保留 Running | 健康确认后可以继续常驻，记录 offload 失败 |
| 可恢复捕获失败 | 恢复原实例与路由，返回错误 | 回退常驻必须以状态和健康为依据 |
| 不可恢复捕获失败 | 停止并移除沙箱元数据 | 不得静默冷启动后宣称恢复成功；需任务级失败或明确 checkpoint 恢复 |
| 持久化失败 | 尝试原地 resume；失败则停止并删除记录 | 先确认原实例结果，再做后续动作 |
| 恢复启动/就绪失败 | 清理新实例并回退暂停元数据，保留恢复来源的路径 | 限次重试、容量退避；最终失败应暴露给任务 |
| 清理失败 | 可能仅告警 | 留存残留资源观测与重试清理责任 |

失败与取消语义来自 `service.rs:289-310, 1442-1767, 2605-2660`；上述上层动作是建议，尚未实现。[A2]

平台已有两种便利机制，但均不能替代业务安全边界：

1. `autoPause` 按 TTL 到期执行暂停，并非“当前正在模型推理且所有工具已结束”的检测。进行中的工具必须保持生命周期租约或刷新 deadline，不能让 TTL 抢先暂停。[A16]
2. `autoResume` 开启时，代理收到指向 Paused 沙箱的请求可尝试恢复，然后再解析新路由；无该配置时返回不可用。它没有证明命令的端到端 exactly-once，也没有替上层提供“无在途命令”的保护。[A17]

建议初版显式执行 `ensure_running → 重建连接 → 工具健康探针 → dispatch(command_id)`，并将正在执行、结果尚未确认、上传/下载、流式输出及必须继续运行的后台任务计入 busy lease。该建议属于 Infra 设计，不是 AgentEnv 已有接口声明。

## 后续最小核验与采用条件

以下是尚未执行的验证要求，不是测量结果：

1. 单沙箱写入磁盘哨兵，同时启动保有随机内存哨兵和计数器的进程；确认信息不只存在文件里。
2. 常驻与 pause 两组使用同镜像、资源形状、准备步骤、warm pool 与存储设置；暂停前确认没有业务命令在途。
3. pause 后同时读取 API 状态、Firecracker PID、设备、active/including-paused 指标、宿主内存及存储写入；不能用 VM 进程 RSS 单指标代表总体收益。
4. 延迟相同时间后 resume，重建连接，验证磁盘/内存/进程哨兵、工具端口和第一条真实命令；分别记录 API 恢复与工具可用延迟。
5. 对短/长推理空档、低/高脏页、热/冷缓存及多沙箱同时恢复逐项改变一个控制变量，确定收支平衡区间。
6. 对暂停中到达命令、重复恢复、API 超时、磁盘满、恢复容量不足、网络断线与持久化失败检查结果；不得自动重放结果未知的有副作用命令。

当前决定：**使用 AgentEnv 实现后续独立运行态卸载 Demo，先验证单实例、同节点 pause/resume；不接入现有其他后端适配器**。README 中的低于 50 ms 恢复、低于 100 ms 暂停是项目声明，本轮没有其相同环境下的复现实验，不能当成目标环境结论。[A11]

## 固定版本证据索引

以下 A1–A17 均为 `a27b2db909b035f58696ba8798ea0e285c7bfa17`；A18 单独标明旧版本。

- [A1：工作说明，运行态恢复与 snapshot 区别，76–111 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/concepts/sandboxes/working.md#L76-L111)
- [A2：生命周期、失败回退、暂停及恢复实现](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/orchestrator/service.rs#L1391-L1767)
- [A3：后端 pause 与 snapshot，345–384 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L345-L384)
- [A4：内存捕获、停止及新运行实例恢复](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L966-L1215)
- [A5：主机资源释放与异常析构，62–157 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/resources.rs#L62-L157)
- [A6：持久化产物清单，暂停产物与共享快照的区别](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/internals/persistence-artifact-inventory.md#L154-L163)
- [A7：实例身份、网络释放与 IP 变化，20–27 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/concepts/custom-extension/lifecycle-hooks.md#L20-L27)
- [A8：公开 pause / snapshot / resume API，1792–2050 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/api/impls/sandbox.rs#L1792-L2050)
- [A9：停止 Firecracker 进程，216–247 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/instance.rs#L216-L247)
- [A10：恢复加载与网络重建，1587–1726 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L1587-L1726)
- [A11：官方性能与共享 page cache 声明，28–31 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/README.md#L28-L31)
- [A12：active / paused 资源指标计算，58–109 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/orchestrator/metrics.rs#L58-L109)
- [A13：调度器 including-paused 上限，65–86 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/services/scheduler/internal/filter.go#L65-L86)
- [A14：共享存储按需加载](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/getting-started/on-demand-loading.md)
- [A15：虚拟化模式恢复限制，21–24 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/config/default.toml#L21-L24)
- [A16：TTL、pause/delete 与刷新语义](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/concepts/sandboxes/auto-eviction.md)
- [A17：代理自动恢复的配置分支及等待，720–817 行](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/api/proxy.rs#L720-L817)
- [A18：旧版本 sandbox 说明](https://github.com/kvcache-ai/AgentENV/blob/0a7338443eb67137492326dfa53f511ae5db128d/docs/src/concepts/sandboxes.md)
