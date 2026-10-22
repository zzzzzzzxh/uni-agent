# 沙箱运行态卸载：社区能力证据

核查日期：2026-10-21。本文只记录官方文档与公开源码核查阶段的证据；文中引用的社区性能数字不是本项目实测，后续 AgentEnv 实验见 [结果报告](sandbox_offload_results.md)。

本轮 Demo 已选定 AgentEnv 为唯一后端。本文保留社区能力比较作为背景材料，文中其他平台的接口、SDK 和验证要求均不进入当前 Demo；实施范围以 [AgentEnv 调度方案](sandbox_offload_design.md) 为准。

## 结论与术语

社区确实存在“保存运行态、退出运行实例、按需恢复”的实现，但同名 `pause` 的含义不同。E2B 的完整内存暂停和 Daytona 的 VM 暂停可作为服务级参照；Firecracker 提供底层机制；Docker `pause` 只冻结执行，不能据此认定释放 RAM。当前公开 AKernel 的 `reload` 属于回滚能力，尚不足以证明当前元戎部署存在可调用的卸载/恢复合同。

本设计将四种操作分开：

| 操作 | 保留进程内存/执行位置 | 释放运行实例内存 | 本项目用途 |
|---|---|---|---|
| 冻结执行 | 通常保留 | 不保证 | 不是目标 offload |
| 运行态快照 | 保存到快照 | 取决于是否退出原实例 | offload 的前置机制 |
| 完整运行态卸载 | 保存到快照并退出原实例 | 需宿主与调度器确认 | 本项目目标 |
| 文件系统保留后重建 | 不保留 | 可以 | 单独的冷启动实验臂，不冒充恢复 |

“释放 RAM”“归还调度配额”“停止计费”是三个不同结论。客户端退出、guest RSS 降低或 API 返回 `paused`，均不能单独证明这三件事同时完成。

## 一、E2B：完整运行态暂停成立，恢复链路与持久化仍须测量

官方文档说明 `pause()` 默认保存文件与内存，`connect()` 恢复同一沙箱；外部客户端会断开，恢复后须重新连接。当前文档以 `mode="filesystem"` 表示丢弃内存的暂停，旧 `keep_memory=False` 已弃用。它们不能用于验证进程连续性。官方给出的暂停约 `4 s/GiB RAM`、恢复约 `1 s` 仅作实验量级参考，不能替代含排队、健康检查和首条工具命令的测量。[持久化文档](https://docs.e2b.dev/sandbox/persistence)

固定 SDK 证据：本地只读副本 `E2B@cab27aa6fabd53f759189328c4f74df2df1550ad` 工作树干净；`sandbox_sync/main.py:743–790` 明确区分 `keep_memory=True/False`，`:358–361` 的 fork 会短暂停顿后继续原沙箱。因此 fork / snapshot 本身不是卸载。联网读得 SDK main 为 `7433b8c61641f9a1b2511a3a165141ab61018b9d`，本文不把旧副本的方法签名当成所有新版本合同。[固定 SDK 源码](https://github.com/e2b-dev/E2B/blob/cab27aa6fabd53f759189328c4f74df2df1550ad/packages/python-sdk/e2b/sandbox_sync/main.py#L743)

固定服务端证据：`e2b-dev/runtime@fa548512f9cba0ef4b676a9b528c07660dbada8a`，核查以下链路：

1. `packages/api/internal/orchestrator/pause_instance.go:29–86` 保存 snapshot 元数据并请求节点暂停，拒绝情况与成功分别处理。[源码](https://github.com/e2b-dev/runtime/blob/fa548512f9cba0ef4b676a9b528c07660dbada8a/packages/api/internal/orchestrator/pause_instance.go#L29)
2. `packages/orchestrator/pkg/server/sandboxes.go:1272–1298` 在本地快照后启动异步上传，并在返回路径异步停止原沙箱；`:2421–2468` 等待实例结束并清理连接。因此“暂停返回”“宿主进程退出”“远端上传完成”不是同一个时间点。[源码](https://github.com/e2b-dev/runtime/blob/fa548512f9cba0ef4b676a9b528c07660dbada8a/packages/orchestrator/pkg/server/sandboxes.go#L1272)
3. `packages/orchestrator/pkg/sandbox/sandbox.go:2168–2212` 停止 Firecracker 进程、kill cgroup、等待进程退出、停止内存处理；这是完整 offload 的实现证据，而不只是接口名。宿主页缓存、快照缓存和异步写入仍不能算零内存/零 I/O。[源码](https://github.com/e2b-dev/runtime/blob/fa548512f9cba0ef4b676a9b528c07660dbada8a/packages/orchestrator/pkg/sandbox/sandbox.go#L2168)

资源与失败边界：

- 官方计费按运行时间；暂停后停止计算计费。配额、地区容量、快照存储与后台内存的实际占用仍应单独记录，不能从账单反推宿主 RSS。[计费与限制](https://docs.e2b.dev/billing)
- 当前文档说明快照积压可能使手动 pause 被拒绝；相关灰度区域返回 `503`，仍保持运行。自动暂停反复被拒绝约两分钟后可能降级为只保留文件系统；应检查生命周期事件的 `pause_mode`，不能把所有 `paused` 当成内存恢复成功。这是当前文档所述灰度行为，须按测试地区和实际 SDK 固定版本核查。[暂停拒绝与自动暂停](https://docs.e2b.dev/sandbox/persistence#when-a-pause-is-refused)
- 建议初版用显式暂停并验证快照种类。若接口不提供可确认的完整运行态语义，继续常驻；不得静默进入丢内存的路径。

## 二、Daytona：必须按沙箱类型判断，不能沿用旧快照结论

2026-10-21 在线文档显示版本 `v0.225`。Container 不支持 pause/resume，stop/start 保留文件系统但清除内存；Linux VM 和 Windows 支持内存 pause/resume、hot snapshot 与 fork，暂停状态卸载到存储层。`start()` 恢复 paused VM。仅创建 snapshot 会回到原来的运行状态，并不等于卸载。[生命周期及状态表](https://www.daytona.io/docs/en/sandboxes/)、[持久化类型](https://www.daytona.io/docs/en/persistence/)

官方对配额与计费的区分很明确：

| 状态 | CPU/RAM 预留配额 | 磁盘配额 | 计费 |
|---|---|---|---|
| VM paused | 释放 | 释放 | 仍收预留磁盘费用，不收 RAM/vCPU |
| Container stopped | 释放 | 保留 | 仍收预留磁盘费用 |
| Container archived | 释放 | 释放 | 该沙箱不计费 |

转换中的 `pausing` 仍按运行状态收费，须等到最终状态。独立 snapshots 有自己的存储费用。以上是服务合同描述，不是宿主物理内存实测。[配额](https://www.daytona.io/docs/en/limits/)、[计费状态表](https://www.daytona.io/docs/en/billing/)

已有本地 `daytona@ec4c21b2d597091ac09ecc278f3bcc172575a987` 不含相关运行时实现，只适合说明该副本不能证明能力；不应据此否定当前服务的 VM 功能。官方内存持久化描述也不能保证外部对端、连接超时和客户端句柄继续有效；本项目仍要求重连、端口健康和首条命令验证。未取得可审计的当前完整服务端实现，物理资源释放量须实验确认。

## 三、Firecracker：基础机制可用，生命周期由上层补齐

联网固定版本为 `firecracker-microvm/firecracker@1e5fcc27b59f24d8e9bae239cdc5d1e4b115c656`（main）。官方 `docs/snapshotting/snapshot-support.md` 给出完整内存、设备状态快照；磁盘文件由集成方管理。`Pause` 冻结 vCPU 和设备活动，不包含“销毁原实例”这一动作。完整 offload 还需原进程退出、磁盘版本保持一致、资源账本归还及恢复准入。[固定文档：概述与 Pause](https://github.com/firecracker-microvm/firecracker/blob/1e5fcc27b59f24d8e9bae239cdc5d1e4b115c656/docs/snapshotting/snapshot-support.md#pausing-the-microvm)

恢复可通过私有映射按缺页加载，首条命令会承担部分读 I/O，故 API 恢复耗时可能掩盖后续成本。网络状态不保证连续，vsock 连接会关闭；快照兼容受软硬件版本约束。这些限制支持初版只承诺“相同受支持宿主类型上的恢复”，不承诺任意跨主机迁移。[固定文档：内存映射、网络与兼容](https://github.com/firecracker-microvm/firecracker/blob/1e5fcc27b59f24d8e9bae239cdc5d1e4b115c656/docs/snapshotting/snapshot-support.md#overview)

推论：快照使匿名运行态内存可被回收，但本地快照、页缓存和后台上传仍有成本。必须记录匿名内存、file cache、总 cgroup 内存、落盘字节以及恢复后的缺页/I/O，不能宣称 offload 后“总内存归零”。Firecracker 不提供租户配额与计费，不能从其机制推导云服务配额合同。

## 四、Docker pause 与 CRIU：是两条不同路线

Docker `pause` 使用 freezer cgroup 冻结进程，未将进程导出并移除。因此只能推断停止执行，不能当作确定性 RAM 释放手段；即使系统自行 reclaim 或 swap，也不是该 API 的资源归还合同。[Docker pause](https://docs.docker.com/reference/cli/docker/container/pause/)

Docker checkpoint 借助 CRIU 把运行态写成磁盘文件，默认不保留原运行进程；Docker 官方仍标为 experimental，并列出外部终端和内核/seccomp 限制。CRIU 的默认 dump 结束状态为 dead，`--leave-running`/`--leave-stopped` 改变这一语义。因此只有完成 dump 并停止原进程、保留所需文件和资源映射的组合，才是卸载候选。[Docker checkpoint](https://docs.docker.com/reference/cli/docker/checkpoint/)、[CRIU final states](https://www.criu.org/Final_states)

CRIU 的外部挂载、文件锁、TCP 等状态需要专门配置；继续运行原进程后再恢复旧 checkpoint，可能与外部资源不一致。它不是对任意工具环境都透明的 SDK 开关。不能在当前容器内部自行安装 CRIU 就认为获得宿主运行时的 checkpoint 权限。[CRIU 高级用法](https://www.criu.org/Advanced_usage)、[Docker 集成](https://www.criu.org/Docker)

## 五、AKernel / OpenYuanRong：已发现回滚能力，未确认完整卸载合同

公开 PyPI `akernel-sdk 0.2.0rc3`（发布于 2026-10-20）文档明确：`failover=True` 与 `reload()` 从同节点最近本地 anonymous checkpoint 回滚；checkpoint 由沙箱内 Execd 的实验性 Unix socket 接口触发，SDK 刻意不暴露 checkpoint ID、restore、list 或 delete。恢复点跟随源沙箱生命周期。此能力不足以证明存在可长时间释放实例资源、再由调度器恢复的公开接口。[版本固定的 SDK 说明](https://pypi.org/project/akernel-sdk/0.2.0rc3/)

联网读取 `inclusionAI/AKernel@19cb17153d2c3925ed46fd665353063d33eef70c`：

- `sdk/python/akernel_sdk/sandbox.py:487–498` 是 `reload()`；该类公开方法中没有 `pause()`/`resume()`。[Sandbox 源码](https://github.com/inclusionAI/AKernel/blob/19cb17153d2c3925ed46fd665353063d33eef70c/sdk/python/akernel_sdk/sandbox.py#L487)
- `_backends/base.py:138–180` 的生命周期协议为 `reload`、`terminate`、`close` 等；`_backends/openyuanrong_sandbox.py:342–354` 只转发底层 reload，并在依赖不支持时报错。[后端协议](https://github.com/inclusionAI/AKernel/blob/19cb17153d2c3925ed46fd665353063d33eef70c/sdk/python/akernel_sdk/_backends/base.py#L138)、[适配实现](https://github.com/inclusionAI/AKernel/blob/19cb17153d2c3925ed46fd665353063d33eef70c/sdk/python/akernel_sdk/_backends/openyuanrong_sandbox.py#L342)
- 同名 detached 沙箱的 `kill()` 可能只关闭客户端，远端需显式 `Sandbox.delete(name)`；客户端断开不能作为资源已释放的证据。[历史公开版本的生命周期说明](https://pypi.org/project/akernel-sdk/0.1.6rc1/)

以上是特定公开源码与发布版本证据，**不是 remote186 当前安装 wheel、服务 endpoint 或 AgentEnv 后端的能力证明**。尤其不能把公开 PyPI `0.2.0rc3` 与仓库历史 OpenYuanRong release wheel `akernel_sdk 0.9.22` 当成已证实属于同一 API/版本序列，也不能按版本号大小推断功能包含关系。公开 main 的方法与 detached `kill()` 语义，不可直接套到在用 wheel。本轮未读取远端 SDK，也未调用运行态接口。不能断言全部 OpenYuanRong 服务都不支持；当前结论为“未确认可用于本项目的完整卸载合同”。

在选实现之前需要补齐的部署事实：准确的发布 wheel/哈希和依赖、当前 runtime、运行态暂停与恢复 API、快照保留范围、暂停完成后 CPU/RAM 配额归还方式、实际宿主清理完成标志、断线命令查询/去重能力、失败后原实例是否仍活着。若只有 reload 或文件系统重建，初版保留常驻，并把替代方式明确标为其他实验臂。

## 六、对调度与验证设计的直接影响

1. 能力门禁应分别表达“完整内存恢复”“释放运行资源”“可观察最终状态”“可重建连接”；任何一项未知都不能默认为真。
2. 暂停前阻断新命令准入并排空已接受命令；长命令、后台任务和外部依赖未知时继续常驻。恢复后先检查进程内存标记、服务端口和外部转发，再下发原始待执行命令。
3. 暂停被明确拒绝可退回常驻；请求超时属于结果未知，先查询/对账，不能盲目 retry、另起副本或重复执行具有副作用的工具命令。
4. 资源归还以实际观测或服务端合同为准。应独立记录 API 返回、进程退出、配额变化、存储完成；控制 create、pause I/O 和 resume 的并发，避免所有推理同时结束引发恢复峰值。
5. 社区证据证明路线可行，不证明当前 workload 值得采用。Demo 必须对比内存时间积分、恢复至首条工具完成耗时、端到端耗时、成功率、读写 I/O 和残留资源；不以单次恢复 API 延迟作为最终收益指标。
