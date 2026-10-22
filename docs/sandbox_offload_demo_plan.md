# AgentEnv 沙箱常驻与卸载恢复：Demo 实验规格

日期：2026-10-21。状态：实验规格；独立 Demo 已完成真实对照，见 [实测报告](sandbox_offload_results.md) 和 [实验记录](sandbox_offload_experiments.md)。本文仍保留未执行阶段的规格，不能将这些计划当作已完成结果。

本设计遵循“可证伪问题、最小基线、一次一个控制变量、同时记录收益与成本”的实验方法。根据本次明确选择，Demo 唯一后端是 **AgentEnv**，固定源码版本 `a27b2db909b035f58696ba8798ea0e285c7bfa17`；同一个部署内比较常驻与控制面 `pause/resume`，初版只验证单节点、同节点恢复。能力依据见 [AgentEnv 核查](sandbox_offload_agentenv_research.md)，[社区调研](sandbox_offload_community_research.md) 仅供背景比较。

此次实验不使用 OpenYuanRong 链路；仓库既有该链路的安装和测试要求不作为本 Demo 的依赖，也不修改 `AGENTS.md`。保留 `remote186`、`/home/zxh`、Conda `uni-agent` 和 Python 3.11 作为实验客户端约定。公开接口或源码存在不等于目标部署可用，接口、资源释放和恢复完整性仍须实测。

## 1. 要回答的问题

在相同任务、镜像、资源规格与模型等待序列下，只把安全空闲区间的沙箱常驻改为运行态卸载，能否降低提供方节点的内存时间积分，并在预先登记的延迟预算内保持任务结果、命令副作用和清理正确性？

主要反证包括：只停止执行但内存或资源预留不释放；恢复丢失进程状态；长命令误判空闲；恢复与重新连通的成本高于空闲收益；同步恢复导致容量排队或磁盘拥塞；失败后重放造成重复副作用。任一出现都不能宣称方案已获得生产收益。

先证实机制，再评估调度策略。运行态快照、文件系统快照、冻结、资源预留释放、实际 RAM 回收、计费停止是不同的观测项。每项单独填写 `confirmed`、`failed` 或 `unobservable`，不得互相替代。

## 2. Demo 调用链与现有 runner 的边界

初版使用运行于沙箱外的 Python 编排器，直接调用固定版本 AgentEnv 的 HTTP 控制面 API，并通过同 SHA 的 `aenv exec` 启动状态探针；周期工具为经私有 HTTP 8000 代理的文件/计数操作。无需 Ray，也不复用现有 `SandboxClient`。`aenv exec` 使用 envd ConnectRPC `/process.Process/Start`，经 `x-agentenv-sandbox-id` 和 `x-agentenv-target-port: 49983` 代理，不是 `/execute` REST 接口。原生命令通道会流式返回输出及远端退出码，必须保留这些终态证据；客户端超时仍不能证明远端命令已停止。A/B 两组使用相同启动与工具路径；恢复包括 API、SSH 归属检查、全 RAM 校验和首工具，不等同于原生 shell 命令延迟。[原生命令说明](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/concepts/sandboxes/working.md#L14-L25)

控制路径为 `工具命令终态确认 → 启动外部推理等待并确认安全点 → AgentEnv pause → 等待下一工具请求 → 同节点恢复 → 重新解析运行实例/连接 → oracle → 下一工具`。B 组使用 `POST /sandboxes/{sandboxID}/pause`，恢复使用 `POST /v2/sandboxes/{sandboxID}/connect`（从 Paused 恢复返回 201，已 Running 返回 200）；旧 `/resume` 接口已弃用，不作为本 Demo 接线。文中 `resume` 表示恢复语义，具体 HTTP 请求以此为准。不能以 `snapshot create` 或底层 vCPU freeze 代替完整卸载，编排器也不直接杀 Firecracker。

创建、查询、删除、鉴权和字段规格统一引用 [调度方案的 AgentEnv 接口表](sandbox_offload_design.md)，保持 HTTP 生命周期、原生 CLI 初始化和私有 HTTP 周期工具的明确链路。生命周期请求使用 `X-API-Key`；CLI 凭据文件 `~/.config/aenv/credentials` 应为仅当前用户可读写，不将 token 放入 argv 或输出。

每个会话保存稳定的 `sandboxID`、宿主节点身份、命令 ID、编排 generation 和 Firecracker PID；`sandboxInstanceId` 的获取路径需在部署预检核实，可由 hook/内部观测取得，不能假定公开 GET 响应直接暴露。不可见时记为 `unknown`，使用本地 generation、PID 和状态证据对账。恢复后更新可见的运行实例 ID 和连接目标，过滤旧实例的迟到结果；不得把原 socket、shell 句柄或 IP 默认视为仍然有效。普通 pause 产物保存在本节点 persister 的记录与 artifact 中，第一版不发布共享 snapshot、不切换节点，也不验证跨节点迁移或节点丢失后的恢复。[实例身份](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/concepts/custom-extension/lifecycle-hooks.md#L20-L27)、[持久化范围](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/internals/persistence-artifact-inventory.md#L154-L163)

**当前 runner 的接入是后续任务。** 既有 `examples/blackbox_recipes/mini_swe_agent/mini_swe_agent_runner.py:198` 用一次长命令覆盖完整 agent 循环，模型推理时该命令仍在途。“没有输出”或“模型请求正在等待”均不能作为安全暂停点。后续若保留沙箱内编排，需要显式安全点及外部持久请求代理；本 Demo 的外置编排成功不代表现有 runner 已可直接卸载。

## 3. 前置能力门槛

| 门槛 | 最小证据 | 不满足时的结论 |
|---|---|---|
| 运行态保存 | 非文件持久化的随机内存值、进程状态、文件描述符偏移可恢复 | 文件重建不得命名为运行态恢复 |
| 真正卸载 | AgentEnv API 为 Paused，原 Firecracker 进程已退出，设备/网络引用与宿主 RAM 观测符合释放预期 | 单独的 API 204、Paused 状态或 active 计数下降不充分 |
| 资源记账 | active / paused CPU、内存指标、including-paused 限制、宿主资源和 persister 快照空间 | 未观测项不得宣称容量或费用收益 |
| 恢复可用 | 恢复后进程/文件 oracle 通过，连接与首个工具命令成功 | API 返回成功不算 ready |
| 状态查询 | 超时后结合 AgentEnv API、sandboxID/实例代际、宿主进程与 persister 记录对账；不假定存在通用 operation 查询接口 | 保守隔离并保留资源预算，不盲目重试 |
| 清理可确认 | 使用 AgentEnv 原生删除后，对账 API、运行进程、设备/网络引用、本轮 persister 记录与 artifact | 本轮清理失败，不能进入下一轮扩容 |

若固定版本 AgentEnv 的目标部署不满足上述门槛，则记录具体失败并停止该档，不替换其他后端来宣称本方案通过。没有 AgentEnv 宿主节点或权威指标访问时，可以验证功能和端到端延迟，但“物理内存节省”与“可多承载实例”仍为未验证。暂停后的 including-paused 调度限制可能继续占用容量，需与物理回收分开判定。

`GET /sandboxes/{id}` 的公开 state 是粗粒度映射：Pausing、Snapshotting、Forking 也可能显示为 paused，Resuming 也可能显示为 running。因此不能仅轮询这个字段就宣告暂停或恢复完成；生命周期响应、实例代际、宿主进程和命令/oracle 共同构成完成证据。

## 4. 运行环境与准备顺序

以下是实施阶段的操作规格。实际执行状态和环境证据保存在 [实验记录](sandbox_offload_experiments.md) 及各 run 的 manifest；不要把本清单本身当作执行完成证明。

1. 在 `remote186` 使用 `/home/zxh` 工作目录，核实 Conda `uni-agent`、Python 3.11；这是外部 Python 编排器的客户端环境，不代表 AgentEnv 服务端可直接部署在该机。记录客户端依赖版本与摘要，避免改动共享系统 Python。
2. AgentEnv 执行节点选在 remote145 承载的专用 Ubuntu VM，remote186 始终只作为 Demo 访问客户端。核实专用节点的 Linux 内核 6.8+、嵌套 `/dev/kvm`、CPU 架构、`ublk_drv` 与 daemon、存储目录、空间及 NET_ADMIN/SYS_ADMIN 等权限。remote145 共享宿主不升级内核，专用节点内运行 AgentEnv 及其 Firecracker 沙箱；本轮不在 remote186 部署这些服务。初版固定 KVM 模式，不临时改用 PVM 混入对照。[固定版本前置条件](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/docs/src/getting-started/quickstart.md#L3-L17)
3. 后续部署或构建只使用 AgentEnv `a27b2db909b035f58696ba8798ea0e285c7bfa17` 对应组件，按固定 `deps_manifest` 核对 Firecracker、guest kernel、ublk/OverlayBD（`v1.0.18-aenv.1`）等依赖并记录源码 SHA、二进制/容器 digest、CLI 和配置摘要；不使用浮动 main/latest 作为复现依据。A/B 使用相同模板/镜像 digest、warm pool、存储布局与缓存配置。普通 pause 的 persister 保留在同一节点，禁止把共享 snapshot 发布路径误认为其故障转移机制。[固定依赖清单](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/config/deps_manifest.toml)
4. AgentEnv API 凭据通过权限受限的远端环境文件或会话注入，不写入仓库、artifact、命令行历史或输出。manifest 只记录变量名称与来源类型；客户端到控制面使用可信网络或已配置的 TLS 入口，不修改既有其他服务客户端。
5. 记录 AgentEnv 的全部实例状态及 active / paused 分项指标、including-paused 限制、宿主 Firecracker 进程、ublk 设备、网络 slot、CPU/RAM 和存储余量。确保至少一个实验实例与恢复预留有容量。warm pool、存储 daemon 和 page cache 开销也需纳入 A/B 背景，不能仅以 active 下降证明物理回收。
6. 实现阶段先完成 AgentEnv 原生最小预检：同版本 API 创建实例、通过原生命令通道执行探针、启动沙箱内最小 8000 状态服务、确认命令侧及外部代理访问，再原生删除并对账。第一版不安装 `swe-rex`；它仅是以后在同一 AgentEnv 后端验证真实工具负载的候选。沙箱内 8000 与宿主控制面监听端口是不同边界，记录各自实际路由。
7. 准备固定实验根目录，例如 `/home/zxh/uni-agent-sandbox-offload/`，只管理 manifest 登记的实例和 persister artifact；不同轮次用中性名称与 UTC 时间戳。Python 编排、等待、命令日志与采样都在沙箱外；不引入 Ray 或现有沙箱客户端作为额外变量。
8. 每轮结束经 AgentEnv 原生 `delete` 清理，再对账 API 记录、Firecracker 进程、ublk/网络引用、persister 记录/artifact 和存储。共享基础镜像、warm pool 或共享缓存不能因属于背景而误删；有残留就单独报告并阻止扩容。全部测试结束执行第 4.1 节的 AgentEnv 生命周期验收规格，不以其他后端的历史健康检查替代。

`aenv exec` 是固定版本已有原生命令；生命周期统一使用第 2 节及主方案接口表中的 HTTP API。Python 编排器、资源采样器及状态探针位于 `scripts/agentenv_offload/`，实现和验证范围以测试及真实 run 为准；尚未验证的故障场景不能因脚本存在而标为通过。

AgentEnv 的 `autoPause`、`autoResume` 和 TTL 必须关闭或统一纳入实验控制面，并将实际配置写入 manifest；TTL 不得在命令仍在途时触发暂停、终止或回收。卸载期间禁止 `aenv connect`、健康探针或指标采集通过代理访问沙箱而自动唤醒实例；采样只使用经验证不唤醒的外部控制面只读查询与宿主指标。若发现意外唤醒，记录触发来源并将该轮判为观测污染，不能继续计算卸载收益。

### 4.1 最终 AgentEnv 生命周期验收规格

生命周期验收路径在同一固定版本部署依次完成：创建 → 原生命令和状态 oracle 初始化 → 8000 内外可达 → 确认无在途业务命令 → 控制面 pause → API 状态、旧 Firecracker 退出、active/paused 指标与宿主资源对账 → 无意外唤醒的暂停观察窗 → 同节点恢复 → 核对相同 sandboxID、更新可见的 sandboxInstanceId 或标 unknown 并记录新 PID/本地 generation → 重建原生命令连接与应用访问 → RAM/进程/文件/打开文件偏移 oracle 通过 → 第一条真实工具命令成功 → 原生删除 → 本轮实例、persister artifact、设备和网络残留对账。

必须再覆盖一个“直接删除 Paused 实例”的清理分支，避免只验证 Running 删除而漏掉暂停产物。五项主指标为内存占用、恢复耗时、任务总耗时、成功率及磁盘 I/O；所有指标和清理结果进入本轮报告。独立 Demo 已实现这些路径，实际已通过项目和未覆盖的故障注入范围以实测报告及原始记录为准。

## 5. 最小实验与状态 oracle

### 5.1 同一 AgentEnv 部署的 A/B 对照

先固定单实例、一个内存规模、一个等待时长、一个后端版本和本地暖缓存。建议初始已触碰内存 256 MiB、等待 30 秒；这些是起始实验参数，必须服从单实例可用内存与提供方限制，不是生产默认值。

- A：AgentEnv 常驻。工具完成后，外部编排器等待，再调用下一工具；实例保持 Running。
- B：AgentEnv 控制面 pause/resume。确认安全点后执行 pause，等待结束在原节点 resume，再执行同一工具。必须证实旧 VM 退出，不能只观察 pause API 成功。

A/B 每轮从相同镜像与确定的初始状态新建实例，不把“已经恢复过一次”的 B 与首次启动的 A 比较。两组均包含同样的安全点和观测开销；第一版不增加底层冻结或其他后端对照。首次最小区分只跑一个保存/恢复周期；通过功能门槛后再重复，避免在已失败机制上开展完整性能矩阵。

### 5.2 完整性 oracle

实例初始化后，驻留探针进程分配并触碰固定大小匿名内存，保存随机 nonce 与内容摘要；nonce/摘要的预期值只由外部编排器持有，探针不把内容序列化到文件。记录进程身份、启动时间和单调递增计数，以区分真正恢复与重新执行初始化。PID 相同单独不能证明状态连续。

同时建立文件系统状态：固定目录中的文件摘要、权限、工作目录、环境变量、未读完文件描述符及其偏移、Git 修改状态。oracle 恢复后验证内存 nonce、计数推进、文件内容、文件描述符位置、工具输出和最终任务摘要。涉及 flush/fsync 的工作负载需明确记录一致性边界；不能用只检查磁盘文件掩盖 RAM 状态丢失。

第一版每条工具命令独立执行，cwd/env 显式指定；运行态连续性由驻留进程的 RAM nonce、计数与打开文件偏移证明，不以新命令带入相同 cwd/env 作为证据。长期 shell 只作后续扩展单项检查，不阻塞最小 Demo：若检查则必须重连或接管原 shell，并校验原会话的 cwd、环境变量和相关状态；新建 shell 后重设相同值只能证明状态重建。无法接管时将该扩展项标为失败或不支持。

探针等待期间必须在明确定义的安全状态阻塞，不产生外部副作用。它是唯一允许在最小机制实验中保留的受控后台进程，其目的就是验证运行态，不代表调度器默认允许任意后台作业卸载。HTTP 8000 服务用于恢复后健康检查，连接重建单独测试；不要求已有 TCP 连接默认存活。

### 5.3 多轮任务轨迹

功能通过后使用固定种子的 20 次工具交互轨迹：写入版本号、读取并校验、修改文件、计算摘要、执行确定性测试。外部编排器产生同一推理等待序列；模拟等待必须明确标注，不能称作真实模型性能。随后再使用固定模型、采样参数和输入集验证真实推理等待分布及完整 agent/reward 结果。

每个命令由外部稳定的 `session_id + command_id` 唯一标识，记录提交意图、提供方接收状态与终态。单独设有非幂等计数命令检查重复执行：在终态丢失的故障场景中，预期行为是查询或报结果未知，禁止自动重放。Demo 不宣称具备 exactly-once，除非后端和应用均提供并验证了相应保证。

## 6. 指标、测量边界与时间线

### 6.1 内存与容量

| 边界 | 记录项 | 禁止的推断 |
|---|---|---|
| AgentEnv 沙箱/VM 及其关联服务 | 实例 cgroup `memory.current`、`memory.stat` 的 anon/file/kernel、峰值，Firecracker PSS/RSS、ublk/OverlayBD 进程、persister artifact 与缓存 | VM RSS 降低不等于整节点内存节省；共享 RSS 不能简单相加 |
| AgentEnv 宿主节点 | 可用内存、缓存、匿名页、swap、压力指标，隔离背景负载 | 节点缓存增长不能忽略；不可把可回收缓存一律计为 0 成本 |
| AgentEnv 控制面记账 | active allocated 与 `paused_allocated_cpu` / `paused_allocated_memory_bytes`、including-paused 限制、运行/暂停数量、编排器恢复预留 | active 下降不证明物理资源释放，也不证明含暂停实例的限额已经解除 |
| remote186 客户端 | 外部 Python 编排器、aenv CLI 与采样进程的 cgroup 或进程树内存、CPU、FD | 客户端 RSS 不能代表远端沙箱 RAM；同机部署也必须单独分组 |
| 沙箱内 | 探针与任务可见的 RSS、状态摘要 | 来宾内存数据或最大进程 RSS 只是辅助证据，不是完整宿主占用 |

Linux cgroup 的 `memory.current` 包含该组及后代的当前内存，`memory.stat` 可分解用途，`io.stat` 提供设备维度计数；采样器须依据实际 cgroup 版本与挂载范围记录可见性。[内核 cgroup v2 文档](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)

`smaps_rollup` 用于进程映射聚合；进程 I/O 的 `rchar/wchar` 与存储 `read_bytes/write_bytes` 含义不同。不得把应用读写字节视为物理磁盘 I/O。[内核 proc 文档](https://docs.kernel.org/filesystems/proc.html)

建议常规采样 100 ms、卸载/恢复窗口 20 ms，并记录采样开销。过快转换可能仍被漏采，应结合事件和峰值计数；无法达到该频率则报告实际采样间隔。共享服务不能归属单实例时，报告整池差值及背景噪声，不虚构逐实例精度。

上述频率指外部宿主采样，不是 AgentEnv 默认 guest metrics（默认间隔 15 秒且为节点本地保留，不能捕捉短恢复）。`GET /metrics` 用于 active/paused 账本；`GET /nodes` 或 `/nodes/{id}` 依赖 observability 配置，关闭时的空结果/404 不能解释为资源为零。`nodes.disks` 是磁盘占用量，不是 I/O 计数，物理读写字节与 IOPS 必须取宿主计数。所有控制面采集入口先验证不会恢复暂停实例。

### 6.2 延迟与正确性

外部编排器使用同一单调时钟，记录 `idle_eligible`、`offload_requested`、`snapshot_durable`、`resources_released`、`tool_requested`、`resume_admitted`、`restore_started`、`restore_api_done`、`connectivity_ready`、`oracle_passed`、`command_started`、`command_finished` 和 `cleanup_confirmed`。API 状态、sandboxID、sandboxInstanceId、Firecracker PID 与这些事件关联；暂停必须组合逻辑和物理证据。内部持久化时刻等事件只有在服务日志或指标明确暴露时填写，否则为不可观测，不能用客户端 API 返回时间冒充。不同主机的墙钟只用于关联；若拆分跨机耗时，需报告时钟校准误差。

| 指标 | 定义 |
|---|---|
| 卸载成本 | `resources_released - offload_requested`；额外分出快照写入/持久化和实例释放等待 |
| 恢复排队 | `resume_admitted - tool_requested` |
| 恢复到可用 | 从 `tool_requested` 到连接、oracle 全部就绪，包含准入、排队、存储加载、连接重建与页错误 |
| 首个工具响应 | `command_finished - tool_requested`；单列与常驻同命令差值，避免 lazy restore 隐藏开销 |
| 任务总耗时 | 从统一任务提交到终态结果，包含 create、模型等待、工具、重试与 reward；另列包含确认清理的全生命周期耗时 |
| 成功率 | 所有已开始任务中，结果和 oracle 正确、无重复副作用且达到终态的比例；清理成功率另列 |
| 成本 | 提供方与客户端 CPU 秒、内存 GiB·s、峰值内存、磁盘读写字节/IOPS、快照峰值与持有 GiB·s、网络传输字节 |

磁盘计数应覆盖本节点 persister 暂停产物的写入、持久化、恢复读入、异步回写及删除；在资源回收后继续采样至 I/O 稳定的预定观察窗口。记录逻辑快照长度、实际占盘、压缩率及物理读写放大。第一版使用同节点存储路径，基础镜像若仍访问远端存储则单列网络和请求开销，不能把它等同于暂停快照的共享发布。缺少宿主设备指标时将物理 I/O 标为不可观测，不能填写 0。

## 7. 按门槛逐步扩展的矩阵

| 阶段 | 固定项 | 唯一变化 | 目的 |
|---|---|---|---|
| P0 | 同一 AgentEnv 部署、单实例、固定初态 | 常驻 / 控制面 pause-resume | 证明保存、卸载、同节点恢复和测量链路成立 |
| P1 | 单实例、256 MiB 已触碰内存 | 空闲时长 1/5/15/30/60/120 秒 | 找到收益开始覆盖开销的区间；不一次启动所有档位 |
| P2 | P1 中一个明确受益等待时长 | 已触碰内存 64/256/1024 MiB | 测内存规模对快照成本的影响，最大档服从安全预算 |
| P3 | 固定内存、等待 | 每轮改写 0/10/50/100% 内存 | 判断增量机制、脏页与压缩影响；不宣称后端必然支持增量 |
| P4 | 固定一档工作负载 | 暖缓存/受控冷缓存 | 区分本地缓存命中与实际存储读入 |
| P5 | 固定前述条件 | 总会话数 1/2/4/8，逐档增加 | 测同步工具到达造成的恢复风暴与队列长尾 |
| P6 | 固定 P5 已安全通过的会话数 | 恢复并发许可 1/2/4 | 找到存储与内存准入边界；不得同时改会话数 |
| P7 | 固定并发与轨迹 | 工具到达由同步改为固定种子错峰 | 评估真实到达分布对收益影响 |
| P8 | 固定已选配置 | 模拟等待改为真实模型调用 | 检查外推到 agent 任务的有效性 |

P4 冷缓存优先使用专用提供方节点或已记录的隔离缓存机制，不在共享主机执行全局 drop-caches；无法控制则标记“缓存状态未知”，不能发布冷恢复数字。恢复后触碰全部目标内存页的 oracle 与真实首工具都必须测量，避免仅观察后台懒加载启动成功。

控制策略评估安排在机制曲线之后：先用已知固定等待比较常驻与“每次安全点立即卸载”，再单独加入空闲宽限或预测阈值。预测器只能使用决策时可见数据，不能偷看未来实际等待时长；精确预知时长的结果只能作为理论上界。

## 8. 必测的保护与失败场景

| 场景 | 预期行为和判定 |
|---|---|
| 命令仍运行、无 stdout、被客户端超时 | pin；未确认远端终态不能进入空闲。超时/断链不作为完成证据 |
| 命令 fork 后立即退出，后台仍写文件或访问外部服务 | 未登记后台任务使会话保持不可卸载；受控探针白名单不能推广到业务后台作业 |
| 工具请求与 offload 同时到达 | 同一会话按状态/代次裁决；若已提交不可取消快照则等待转换完成再恢复，禁止同时发两条互相冲突的生命周期操作 |
| 多个工具请求同到 | 共用一个恢复操作；按会话规则串行下发命令，不能各自恢复一份实例 |
| 快照失败或配额不足 | 原实例仍可确认运行时回退常驻；原实例状态未知则隔离、查询，不用 kill 或重建掩盖错误 |
| API 已执行但响应丢失 | 用本地 operation ID 关联意图，再对 AgentEnv API 状态、sandboxID/实例代际、宿主进程和 persister 对账；不假定后端存在 operation 查询接口。无法确认时报告未知，禁止重放非幂等命令 |
| 恢复后健康失败、快照损坏/过期 | 限定有界恢复尝试；禁止静默从空镜像重建并继续称为同一任务。明确可重放任务另设冷重建实验组 |
| AgentEnv 代理/envd 连接失效 | 重新解析当前实例与路由，再连接原生命令通道并验证 8000；不认为旧 shell 或 TCP 会自动存活 |
| 编排器中断、租约过期、陈旧回报 | 新 owner 先对账并递增 generation；旧回报不能释放新 owner 的额度或下发命令 |
| 恢复容量不足、同步风暴 | 有界排队、单会话 deadline、全局恢复并发与内存字节预算；预留恢复容量，不能让新 create 永久占满 |
| 清理期间再收到工具请求 | 会话终结优先，拒绝或明确失败；不复活已结束任务 |

故障注入使用本轮专属资源和可回收代理，不中断共享服务。每种注入在状态图中的明确阶段触发，记录触发事件和预期 oracle。发生首次状态损坏、重复副作用、失控实例或预算越界时停止扩容，完成对账与清理后再诊断。

## 9. 重复、统计和停止规则

功能阶段每个机制至少 3 个独立新实例；通过后，单实例性能档建议 10 对随机顺序 A/B 任务，每任务 20 个周期。连续周期具有相关性，置信区间按任务或独立运行分组计算，不能把 200 个周期当作 200 个独立任务。记录分位数算法和置信区间方法；样本不足以稳定估计 p99 时明确标注，只列原始最大值和探索性分位数。

并发阶段至少 3 个独立批次，A/B 顺序交替或按固定种子随机；记录批次背景负载。所有已开始任务进入分母，超时、未完成、清理失败和不可观测字段保留。成功样本的延迟可单列，但同时报告失败率、超时阈值和限定时间内的完成比例，不能删去失败后宣称更快。

正式成功率目标需先登记。若只做 200 次独立任务且没有失败，仍不足以证明 99.9% 可靠性；对重复周期或同一主机强相关样本更不能套用独立概率保证。Demo 结论应限制到测过的版本、负载、时长和并发。

预算建议从单实例开始：每批实验不超过当前已核实可调度容量减系统与恢复余量；快照空间至少留出本批最坏未压缩快照和原实例并存的余量；具体 CPU/RAM、快照字节、总时间、I/O 限速和最大重试均在开始前写入 manifest。容量不足、快照空间不足、OOM、状态不一致、超时激增或出现非本轮负载污染即停止该档，不用扩大重试掩盖边界。

## 10. 收益计算与建议决策门槛

主结论用观测积分，不以配置内存替代实际占用：

```text
memory_saved_GiB_s = integral(M_resident_provider(t) - M_offload_provider(t)) dt
relative_memory_saved = memory_saved_GiB_s / integral(M_resident_provider(t)) dt
task_latency_change = (T_offload - T_resident) / T_resident
```

按相同任务起点、相同绝对观察窗口配对；窗口至少覆盖较慢模式的完成和 I/O 收尾，完成后本轮资源占用按实测记录。分母同时报告任务数，给出每成功任务的成本，失败消耗不能忽略。reservation GiB·s 另算，不能与物理 GiB·s 相加。

用于解释阈值的简化近似，只有实测支持稳态假设时使用：设空闲为 `I`，宽限为 `G`，卸载耗时为 `S`，净释放 RAM 为 `ΔM`，转换额外内存积分为 `A_transition`，则单次内存收益近似为 `ΔM × max(0, I-G-S) - A_transition`。恢复实际开销还包含排队、重连和首工具执行，不能仅用快照 API 耗时。收益临界空闲时长需由不同 `I` 的配对曲线求出，不能预先写死为某个秒数。

若已有真实价格或内部成本权重，可计算：

```text
net_value = RAM 时间收益 + CPU/资源预留实际收益
            - 存储空间时间成本 - 读写/网络请求成本
            - 额外任务延迟成本 - 失败/重跑成本
```

没有价格与延迟价值函数时，输出内存收益—首工具延迟—I/O 的 Pareto 曲线，不声称有金额收益。CPU 空闲本来可能很低；仅回收调度预留也需单列为容量收益。只有后端实际释放、可重新分配资源且并发实验通过，才能宣称提高承载量。

以下是待实施前确认的建议门槛，不是已达成结果或生产 SLA：状态 oracle、无重复副作用、无残留必须全部通过；目标负载的提供方内存积分至少降低 20%；任务总耗时 p95 相对常驻增加不超过 5%；首工具额外等待 p95 不超过 1 秒；I/O 不越过预登记的设备余量且不造成邻居任务显著退化。达不到某个门槛时保留原始曲线，按业务预算调整适用范围，不能事后只选择通过样本。

预计更适合长推理等待、状态可冻结、恢复存储较快且内存紧张的任务；短而频繁的工具调用、重内存脏页、长期外部连接、后台计算和恢复风暴可能不合算。这些是适用性假设；已测的小状态/长等待收益及 64 MiB 延迟边界见实测报告，其余范围不作收益承诺。

## 11. 可复现产物契约

交付数据遵循以下规格；实际生成的字段及可见性以各 run 的 manifest 和实测报告为准：

| 产物 | 必要字段 |
|---|---|
| `manifest.json` | schema 版本、run ID、UTC 时间、实验代码 SHA 与 dirty 状态、必要文件摘要、固定 AgentEnv SHA、服务/CLI/Firecracker/guest kernel/ublk/OverlayBD 版本与二进制或容器摘要、镜像/template digest、客户端与单节点宿主身份、CPU 架构、资源规格、warm pool/缓存/persister 配置摘要、autoPause/autoResume/TTL、随机种子、A/B 顺序、轨迹摘要、超时/重试/并发/恢复余量、采样频率、预算、metric 可见性、凭据来源类型 |
| `events.jsonl` | session/command/本地 operation ID、sandboxID、sandboxInstanceId、generation、宿主身份与 Firecracker PID、状态转换、单调时间、结果分类、AgentEnv 错误码、可安全关联的 request ID；不含 token、请求头或完整环境 |
| `metrics.csv` | 时间、边界/节点/实例、内存各项、CPU 秒、磁盘读写字节、快照大小、网络字节、资源预留、队列与状态计数；缺测值为空并有原因 |
| `task_results.jsonl` | 所有任务的开始/终态、完整性 oracle、最终任务摘要、latency 分解、失败/未知状态、重试次数、清理确认 |
| `cleanup.json` | 本轮拥有的 sandboxID/实例代际、persister 记录和 artifact、设备/网络引用清单、AgentEnv 原生删除尝试、API 与宿主对账、共享背景资源归属说明、残留及需人工处理项 |
| `report.md` | 中文结论、通过/失败/不可观测矩阵、A/B 统计与原始数据链接、版本和场景边界、是否进入下一阶段 |

manifest 不记录可直接访问私有服务的凭据或完整敏感 endpoint；必要服务身份可用非敏感别名关联受限环境配置。冻结后的实例凭据、内存快照及用户文件属于敏感数据，产物与快照必须使用实验所属的权限隔离和明确保留/删除策略。

## 12. 本阶段交付边界

本文件定义实验规格。实施先完成 P0 的最小鉴别实验，再依据真实结果扩展到调度策略与收益边界；当前 runner 接入仍是独立后续工作。已实现组件、已执行检查、实际收益及未覆盖项在 [实验记录](sandbox_offload_experiments.md) 中逐项标明，不由本文的预期代替。
