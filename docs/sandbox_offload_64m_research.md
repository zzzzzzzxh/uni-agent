# 64 MiB 沙箱恢复开销：分段证据与优化假设

调研日期：2026-10-22。目标是在保持完整内存状态校验和驻留内存收益的前提下，使整任务 p95 增幅不超过 5%，配对首工具额外耗时的任务 p95 不超过 1 秒。

本文只读核查已有结果、正在进行的独立诊断的内核元数据及固定源码；没有创建业务沙箱、触碰沙箱内存数据、修改节点配置或重启服务。文中候选均为待验证假设。其他实验由独立实验流程执行，原始结果不改写。

## 1. 当前判断

主要可优化区间是 **resume 返回后的完整 `/state` 校验**，而不是现有单次 SSH 归属登记。旧 64 MiB 边界实验的这一区间为 1.150–1.342 秒；常驻同一区间仅 0.184–0.190 秒。SSH 为 0.056–0.058 秒，删除这部分本身不足以补上约 0.8 秒的首工具门槛差距。

实际恢复使用 **Firecracker File memory backend → ublk 内存设备 → OverlayBD**。不能用仓库另一条 UFFD 实现的逐页等待，直接解释本实验。普通 pause 生成 Raw 内存层，且 `memory_startup_pack=None`；现有 startup-pack 开关不是普通 pause 的即插即用加速选项。[S1][S2][S3]

只读实测的恢复内存设备为 128 KiB read-ahead、256 KiB 最大块请求。扩大 read-ahead 值可作为诊断变量，但有重要时点限制：Linux 为已经打开的文件保存独立 `f_ra` 状态；在 resume 返回后仅写 sysfs，可能没有改变 Firecracker 已有 mmap 使用的窗口。不能把 sysfs 读回成功当作优化已生效。[K1][K2]

## 2. 节点与通路现状

以下是本次调研开始时 `2026-10-22 01:46 UTC` 的观察，不是后续实验全程状态：

| 项目 | 只读结果 |
|---|---|
| AgentEnv 服务 | `agentenv-offload.service` active/running，server PID `35896` |
| 后端版本 | 服务报告 `a27b2db`；研究源码固定 `a27b2db909b035f58696ba8798ea0e285c7bfa17` |
| 业务库存 | running / starting / paused 均为 0 |
| 既有背景 | 1 个预生 Firecracker、tools 设备 `ublkb0`、2 个已归属网络 namespace |
| 客户端 API 隧道 | remote186 `127.0.0.1:18800/health` 返回 204 |
| 下载代理 | 节点至 `10.0.2.2:17899` TCP 可连接；经其访问 Docker registry 的匿名 HEAD 返回 401，证明 HTTPS 到达 registry，不代表匿名 manifest 已获授权 |
| 池 | 全局 low/high=1/1；Firecracker enabled/prewarm/maintenance=true、fill=1；block disabled、network maintenance=false |
| 内存快照配置 | dirty tracking=true；background download=true，16 MiB × concurrency 4；未配置 startup pack |

业务请求随后由实验流程启动，本次元数据观察没有与之并行创建另一组业务。下载代理不是恢复内存页的既定瓶颈：普通 pause 的本次新层在节点本地；但 cold-create 仍要解析 registry manifest。此前停用代理造成的创建 500 已保留，不能将缓存命中解释成离线运行保证。

## 3. 旧 64 MiB 对照的分段

原始目录：[boundary-bound1-m64-w30-20261021T155607Z](../artifacts/agentenv-offload-results/boundary-bound1-m64-w30-20261021T155607Z/manifest.json)。负载为 64 MiB 匿名内存、低熵、dirty-ratio=0、每轮等待 30 秒、2 周期、1 对任务；同一 bounded warmFC 配置。

原始代码摘要：

| 文件 | SHA-256 |
|---|---|
| `demo.py` | `93fed18bb6762d40439901bffecc229d491528291b559bd3995e0ef8953c5562` |
| `guest_probe.py` | `35cbbd846c174337250dbf85a5bcddcb1c1971f049074b1f2e94eae442030c78` |
| `host_sampler.py` | `cef976aef872ffc94cbeb4f442286909e54583a4292587b2a8601f637f67dc52` |

以下单位为秒，保留原始任务内的相关观测，不将两个周期当作两个独立任务：

| 模式/周期 | resume API | SSH 发现并登记 | API+SSH | 其后 GET `/state` 区间 | POST `/tool` 区间 | 首工具总耗时 |
|---|---:|---:|---:|---:|---:|---:|
| offload 0 | 0.755491 | 0.058103 | 0.814091 | 1.150426 | 0.194402 | 2.158920 |
| offload 1 | 0.460950 | 0.055671 | 0.517146 | 1.341602 | 0.181585 | 2.040333 |
| resident 0 | — | — | 0 | 0.189538 | 0.165521 | 0.355059 |
| resident 1 | — | — | 0 | 0.184209 | 0.164669 | 0.348878 |

派生方式：

- GET 区间 = `restore_oracle_seconds - resume_seconds`。
- POST 区间 = `first_tool_seconds - restore_oracle_seconds`。
- GET 区间包含 HTTP、完整 RAM SHA-256、文件状态读取及恢复后的首次访问；旧记录没有将 guest CPU 哈希时间和内核缺页等待单独分开，因此不能将全部差值报告成已测的“缺页时间”。
- `resume_seconds` 与 API/SSH 两项之和有亚毫秒级记账差；不应人为配平原始数据。

这两个周期的 GET 额外耗时分别约 0.961 秒和 1.157 秒，POST 额外耗时仅约 0.029 秒和 0.017 秒。恢复 API 本身也有 0.461–0.755 秒，两个区间都需要解释。当前数据支持“首触页路径是优先调查对象”，尚未证明某种页故障算法是唯一根因。

整任务耗时为 resident 67.763 秒、offload 71.241 秒，增幅 5.132%；配对首工具额外任务 p95 为 1.798 秒。两组 cold-create 为 4.418/4.485 秒，较为接近。该轮 PSS 门槛为 `unverified`，原因是退出竞态造成的缺测；**不能把旧 64 MiB 轮次当作已经证明内存收益的基线**。[R1]

## 4. 当前复查提供的补充证据

只读读取 remote186 上的新结果：

| 诊断 | 观察 | 可得结论 |
|---|---|---|
| `baseline64-recheck-20261022T015234Z` | offload 首工具 2.213/2.180 秒；resident 0.381/0.388 秒；两组正确 | 旧 64 MiB 首工具超预算现象再次出现 |
| 同一复查的初始化 | offload create 14.438 秒，resident create 4.401 秒；整任务 81.487/67.938 秒 | 约 10.037 秒来自创建差异，不能把全部 task 差值归因于恢复 |
| `zerocopy64-20261022T015607Z` | 单 offload 任务，2 秒等待；完整 memoryview SHA-256；首工具 2.133/2.062 秒 | 尚未展示单靠消除切片即可满足目标；等待长度、单臂和样本数不满足正式 A/B 判定 |

这些路径是 remote186 的 `/home/zxh/uni-agent-sandbox-offload/results/<名称>/`。后续正式报告应归档这些原始记录；本文件不将单臂短等待结果混入正式配对统计。

## 5. 实际内存恢复路径

固定 AgentEnv 版本中的调用链为：

```text
POST /v2/sandboxes/{id}/connect
  -> resume_sandbox / launch_sandbox
  -> FirecrackerSandbox::start_resume
  -> get_or_create_shared_mem(OverlayBD image config)
  -> /dev/ublkbN
  -> load_snapshot_file(..., MemoryBackend::File)
  -> 恢复 VM，等待 envd ready
  -> 外部 GET /state 读取全部业务匿名内存
```

关键细节：

1. `snapshot_to_dir` 将本地内存层以 `OverlaybdCompactOutput::Raw` 捕获，普通 pause 构造的 `FirecrackerSnapshotConfig.memory_startup_pack` 为 `None`。[S1]
2. `start_resume` 取得共享内存设备，并调用 `load_snapshot_file`；底层客户端明确把 backend 设置为 `File`，不是 UFFD。[S2][S3]
3. `get_or_create_shared_readonly` 依具体 image-config 路径复用活跃引用；最后引用释放后设备会回收。新暂停代次不等同于永久保留同一内存设备。[S4]
4. 源码已有对内存设备本身进行 buffered pread 的启动预读实现，明确指出只读下层 commit 文件会暖另一层缓存，不能满足 Firecracker 对该 block-device 映射的缺页；这是后续方案必须遵守的边界。[S5]
5. 本地 startup pack 消费需实际存在 `memory_startup_pack`；它的生成发生在 snapshot publish 的记录流程，会另外启动 recording VM。现有配置开关不能自动为普通 pause 补上该元数据。即使选择已发布快照，启动记录也未必覆盖业务工具触发前未读取的整个 64 MiB 工作集。[S1][S5][S6]
6. `memory_snapshot.background_download` 针对远端层下载，并在 envd ready 后释放；不能把这一参数中的 16 MiB read size 当作本地 File mmap 的预读窗口。[S6]

本轮 UFFD 代码不在已验证的实际链路中，暂不选择修改其逐页处理器。

## 6. 只读实测的 mmap 与块队列

在实验流程的 `zerocopy64-20261022T015607Z` 恢复阶段，本次只读观察到：

| 字段 | 实际值 |
|---|---|
| 归属 | sandbox `01a1614d-3567-7553-94ad-c25ffa8c51e9` |
| Firecracker 身份 | PID `40224`，starttime `4187683`；由同轮 `firecracker_identity` 事件交叉核对 |
| 内存映射设备 | `/dev/ublkb2`，offset=0，映射长度 1,073,741,824 字节，权限 `rw-p` |
| VmFlags | `rd wr mr mw me nr sd`；未见 `rr`/`sr` |
| `read_ahead_kb` | 128 |
| `logical_block_size` | 512 字节 |
| `physical_block_size` | 4096 字节 |
| `max_sectors_kb` / `max_hw_sectors_kb` | 256 / 256 |
| `nomerges` / `rotational` | 0 / 0 |

观察只读取 `/proc` 与 `/sys` 元数据，没有读取映射内容，没有写队列设置。它证明本次恢复使用 file-backed 1 GiB VM 内存映射；其中 64 MiB 是业务探针工作集，不能将整个 1 GiB 视为必须预读的业务数据。

### 安全定位内存设备

后续诊断应先从恢复后的唯一 sandbox 归属 PID 与 starttime 出发，在其 `/proc/<pid>/maps` 或 `smaps` 中找到大容量 `/dev/ublkbN` 文件映射；核对 offset、映射长度、设备 major:minor、当前进程身份及 daemon 记录后才操作。不得按“最大设备号”或“新出现的第二个设备”猜测，因为设备 ID 可重用，tools、rootfs、memory 均使用 ublk。

若零个或多个候选无法唯一识别，则将实验标为无法应用该处理，不盲写任一设备。队列元数据、前后值、实际设备身份和应用时间必须进入事件记录；所有设置成本仍位于 `tool_requested → first_tool` 的计时范围。

### read-ahead 的生效时点

Linux 6.8 的 `file_ra_state_init` 在打开文件时，将 backing-device 的 `ra_pages` 复制到该文件的 `f_ra`。`do_sync_mmap_readahead` 使用这个文件级窗口计算 fault-around 读取。[K1][K2]

因此，resume API 返回后，Firecracker 已经打开并 mmap 内存设备，此时只改 `/sys/block/<device>/queue/read_ahead_kb` 可能不足以改变其现有 mmap 的文件级状态。sysfs 的新值描述设备设置，不是该映射已生效的证据。更明确的接入点是**设备创建后、Firecracker 打开前**；但这一点涉及服务侧接线，应在有证据后再开发。

重开 `/proc/<pid>/fd/...` 通常产生新的 open-file description，也不能未经验证就当作更新 Firecracker 原文件状态。不要为取得优化结果而使用未经审计的远程进程内存修改。

## 7. 可证伪假设与最小实验

| 假设 | 最小单变量试验 | 决策指标 | 成本/反证 |
|---|---|---|---|
| H1：64 KiB mmap 切片复制和 Python 循环显著放大恢复校验 | 将完整 SHA-256 输入改为 memoryview；两组保持全部字节和同一算法 | `/state` wall time、进程 CPU；正式配对首工具差 | 若 first-touch 区间仍约 1.3 秒，说明消除复制不是充分方案；不能删校验补差 |
| H2：当前内存设备的实际读聚合窗口过小 | 先识别设备；对明确生效时点的窗口依次比较 128、256、1024 KiB；每轮只改一个值 | `/state` 区间、major/minor fault、block read request 数/平均大小 | 增加缓存/读放大；256 KiB 最大请求限制可能使更大窗口拆分；若仅在 mmap 后写 sysfs，须标明生效未证实 |
| H3：对相同 buffered 内存设备做有界预读，可降低用户线程缺页串行等待 | 在请求到来后，对已验证的内存设备按可证明的页范围顺序 buffered pread，给字节数/并发/截止时间硬上限 | 请求至首工具总耗时，而非仅 prefetch 后 oracle 时间 | 必须计入预读时间、CPU、I/O、缓存和额外服务内存；读完整 1 GiB 的代价可能超过收益；当前没有普通 pause 工作集清单 |
| H4：HTTP/控制面固定往返主导剩余差距 | 为 HTTP transport 分段计时，单独比较连接复用；保持两次完整 oracle 与命令语义 | 同一 workload 的客户端区间差 | SSH 只有约 56 ms，HTTP 未单独计时；不能靠推测将所有 GET 时间归网络 |

H1 可安全采用 Python buffer protocol：memoryview 提供不复制底层数据的视图，hashlib 接受 bytes-like 输入。必须在原有互斥锁内完成完整摘要，并释放 view 后再关闭 mmap；保留 RAM-only nonce、进程身份、FD offset、文件与命令计数校验。[P1][P2]

H3 的目标是本次 File-backed 内存设备，而不是下层 `.commit` 文件。预读发生在请求后才可以直接与当前策略比较；若放在推理等待阶段，则属于新的提前恢复/预取策略，必须另组报告，并把暂停期缓存与运行成本计入积分。[S5]

本轮不建议把 THP 作为第一个控制变量。业务匿名页、VM file-backed 内存和外层 QEMU 是三层；改变 guest THP 并不自动改变当前 block-device 文件映射的 fault-around，也可能增加固定内存或缺页尖峰。[K3]

## 8. 不降低 oracle 的优化边界

以下优化不改变本轮正确性标准：减少相同摘要算法的中间复制；保持锁的同时使用 buffer protocol；准确识别当前设备后有界预读；改进连接复用；缩短无必要的控制面等待但保留 PID 归属及严格 201 恢复检查。

以下不能计作本目标成功：只读取每页一个字节、抽样页、降低为 CRC、返回缓存的旧 digest、减少 64 MiB 工作集、预先在计时区间外触碰全部 RAM、跳过 `/state` 或工具后的完整内存摘要、仅报 API 恢复延迟、把预测性恢复隐藏在固定等待中。

即使 dirty-ratio=0，旧协议仍在 GET `/state` 和 POST `/tool` 返回状态时各执行一次完整摘要。若要合并成单端点，应明确证明同一锁内的校验顺序和副作用保护等价，仍保留两次完整检查，不借“内存按理未变化”省略实际验证。

## 9. 采样缺口与验收方法

旧采样器记录进程内存、CPU、I/O，但没有保存每阶段 minor/major fault 差值或 guest 摘要自身用时。新诊断最小补充项是：恢复 API 开始/结束、PID 登记开始/结束、guest 全内存 hash 开始/结束、HTTP 返回、POST 工具完成；同时记录当前 FC 的 fault counter 差与对应内存设备块 I/O 差。不可将缺失数据填成零。

建议先用单任务短诊断排除无效假设，再固定选定配置与源码，回到 **64 MiB、30 秒等待、2 周期、至少 3 对独立任务** 的随机 A/B。正式决策保持：

1. 所有已开始任务、全部内存 oracle 与清理必须完成；包含暂停态 DELETE 的独立验证。
2. 整任务 p95 增幅 ≤5%；初始化波动仍保留在整任务指标，同时单列 create/bootstrap 解释差异。
3. 先计算每对相同周期的首工具差，再做任务级 p95 与跨任务汇总；目标 ≤1 秒，不直接相减两组 p95。
4. 归属进程 PSS 积分必须保留正收益并满足既定门槛；包括服务、存储、预热 FC 和所有已归属后代，不仅看业务 VM。
5. 对新增预读报告磁盘 I/O、内层 file cache、匿名页和 MemAvailable；外层物理内存节省继续独立判定。PSS 缺测则该对内存结论未知，不用于宣称收益。

本阶段尚未证明哪一个候选能同时达到两个延迟门槛；现有证据足以优先选择 File-backed 内存设备的首触页路径，避免误改 UFFD 或仅放大背景池。

## 10. 后续诊断更新与显式提前恢复

实验流程继续完成了两项短诊断，本次只读核对其原始事件与结果。两者均为单 offload 任务、2 秒等待，不能代替正式配对验证：

| 诊断目录 | 实际处理 | 首工具耗时 | 结论 |
|---|---|---|---|
| `readahead64-20261022T015902Z` | 在当前映射已建立后，将目标内存设备 sysfs read-ahead 从 128 调至 1024 KiB | 2.125 / 2.051 秒 | 没有展示实质收益；与每文件 `f_ra` 的时点限制一致，但不能据此证明所有预读策略无效 |
| `fullprefetch64-20261022T020447Z` | 当前内存设备完整 1 GiB buffered pread，4 workers、256 KiB chunk；全部成本计入请求路径 | 2.219 / 2.150 秒 | 读本身仅 0.354 / 0.249 秒，之后 GET oracle 区间仍为 1.202 / 1.233 秒，不能把剩余问题归结成“把存储读暖即可解决” |

两轮 source、事件和失败的性能判断应保留，不能删除历史来只呈现有效尝试。完整预读没有把首工具压入预算，继续实现 Raw layer parser 不是当前优先事项。

源码确实提供了一条未来可用的元数据路径：Raw sealed OverlayBD layer 末尾 4096 字节 trailer 指向逻辑区间 index；`mem_image.json` 的本地 `lowers[].file` 描述继承层。该 index 反映已物化的快照区间，不是当前用户工作集或“现存 PRESENT 页”的精确 bitmap。只看最新 dirty 层会漏掉从旧层继承的 RAM；所有 lower 的逻辑区间并集又可能包含已被新层覆盖的旧区域。不能在未验证边界、格式和设备归属的情况下直接把它当作安全预读清单。[S7]

### 转向独立的调度策略变量

当前新的候选是**显式提前恢复**：对固定等待实验保持真实工具到达时刻不变，在其前 `lead=1.5s` 开始 resume 与完整 RAM oracle；到达工具 deadline 后才允许发送有副作用的 `/tool`。默认 `lead=0`，策略参数进入 manifest。

这改变的是调度时机，不能写成“恢复操作本身已加速”。若 `R` 表示实际从开始恢复到完整 oracle 就绪的时间，`L` 为提前量，`T` 为工具时间，则在没有暂停重叠和调度误差的理想条件下，工具到达后的等待约为：

```text
arrival_latency = max(0, R - L) + T
```

同时必须保留并报告 `R` 本身、恢复开始时间、真实工具到达时间、oracle 完成时间、提前恢复的驻留区间及 PSS/I/O 成本。不能把 `R` 的前半段从整任务和资源成本中删除。

只读观察到 `lead64-pilot-20261022T020722Z` 的 offload 单任务已经返回：两轮从恢复开始到 oracle 完成为 2.038 / 1.892 秒，工具到达后的首工具等待为 0.722 / 0.609 秒。该读取时刻尚未据完整配对统计作结论；这组数据说明时机移动可以降低等待，但不说明 File mmap 的首触页路径变快。

采用条件与成本必须写清楚：

- 仅在无未决工具、没有需要连续执行的后台任务、完整状态校验通过时使用；提前阶段只能恢复和执行无副作用的校验，不能提前执行尚未到达的工具请求。
- 更早恢复会缩短资源释放窗口，增加运行态 PSS·s；正式对照仍须证明保留内存收益，不能只看首工具门槛。
- 固定等待时钟允许知道未来到达时间；真实 LLM 推理没有这个保证。未来需单独研究预测误差：工具提前到达会增加等待，晚到会增加无效驻留。
- 不增加等待长度、降低内存大小或改 1 秒门槛来获得通过；64 MiB 正式 cohort 的两组工作负载与计时起点保持一致。
- 清晰区分 `lead=0` 的按需恢复基线与 `lead>0` 的预测调度实验。只有至少 3 对独立任务、正确性/清理、PSS 与两个延迟门槛都完成后，才可将候选提升为结论。

## 来源索引

- [R1：旧 64 MiB 分析](../artifacts/agentenv-offload-results/boundary-bound1-m64-w30-20261021T155607Z/summary.json)、[原始任务](../artifacts/agentenv-offload-results/boundary-bound1-m64-w30-20261021T155607Z/results.jsonl)、[归档探针](../artifacts/agentenv-offload-results/boundary-bound1-m64-w30-20261021T155607Z/raw-data.zip)、[归档编排器](../artifacts/agentenv-offload-results/boundary-bound1-m64-w30-20261021T155607Z/raw-data.zip)。
- [S1：Raw capture 与普通 pause config](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L994-L1134)。
- [S2：start_resume 到 file memory load](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L1587-L1726)。
- [S3：MemoryBackend::File](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/instance.rs#L526-L558)。
- [S4：共享内存设备引用与创建](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/ublk/device.rs#L606-L735)。
- [S5：同一 buffered block-device 上的 span prefetch](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/startup_pack.rs#L586-L710)、[消费条件](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/sandbox.rs#L1930-L1990)。
- [S6：startup pack 与 background download 配置](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/config/default.toml#L251-L269)、[内存后台下载](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/config/default.toml#L345-L372)。
- [S7：Raw layer 的 header/trailer 与映射格式](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/storage/overlaybd/src/lsmt/format.rs#L12-L167)、[映射来源及继承层](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/overlaybd_snapshot.rs#L571-L593)、[dirty ranges 转逻辑区间](https://github.com/kvcache-ai/AgentENV/blob/a27b2db909b035f58696ba8798ea0e285c7bfa17/src/sandbox/firecracker/overlaybd_snapshot.rs#L692-L795)。
- [K1：Linux 6.8 文件 read-ahead 状态初始化](https://github.com/torvalds/linux/blob/v6.8/mm/readahead.c#L135-L144)。
- [K2：Linux 6.8 mmap fault 的 read-ahead 窗口](https://github.com/torvalds/linux/blob/v6.8/mm/filemap.c#L3093-L3155)、[block queue ABI](https://github.com/torvalds/linux/blob/v6.8/Documentation/ABI/stable/sysfs-block#L422-L532)。
- [K3：Linux THP 文档](https://docs.kernel.org/admin-guide/mm/transhuge.html)。
- [P1：Python memoryview](https://docs.python.org/3.11/library/stdtypes.html#memory-views)、[P2：Python hashlib](https://docs.python.org/3.11/library/hashlib.html)。
