# AgentEnv 常驻与卸载恢复实验分析

目标固定源码：`a27b2db909b035f58696ba8798ea0e285c7bfa17`。
运行版本记录：`需结合部署证据核对，目标版本不代表实际版本`。
负载为外部模拟推理等待与 HTTP 状态探针文件/计数操作；不代表真实模型推理或完整 agent 工作负载性能。
已开始 6 个任务；计划 6 个。失败和中断保留在分母中。

## 任务结果与延迟

分位数以独立任务为统计单位。首工具指标先取各任务内周期的 p95，再对任务取分位数；周期不当作独立样本。
清理率依据 result.cleanup.confirmed；若其只确认 API/PID 消失，仍不代表持久化产物和设备已完成审计。
延迟表仅列成功任务，同时明确所有失败数量；小样本分位数仅供探索，不能证明生产成功率或尾延迟 SLA。

| 模式 | 成功/已开始 | 清理确认/已开始 | 任务 p50 秒 | 任务 p95 秒 | 首工具任务 p95 秒 |
|---|---:|---:|---:|---:|---:|
| resident | 3/3 | 3/3 | 67.591 | 67.635 | 0.355 |
| offload | 3/3 | 3/3 | 68.026 | 68.250 | 0.624 |

## 配对内存窗口

每对从各自 measurement_started 对齐，使用较慢任务完成清理后的 I/O 收尾作为共同结束点。
只在两侧完整覆盖该窗口、时钟校准和指标齐全时计算收益；不把缺测补零，不外推较短一侧。
积分使用梯形法及边界线性插值；缺测或超出最大采样间隔使该曲线不可验证。

| 配对 | 共同窗口秒 | 归属进程 PSS 节省 GiB·s | 比例 | 状态/原因 |
|---|---:|---:|---:|---|
| 0 | 69.788 | 10.303 | 61.694% | observed: 完整 |
| 1 | 70.315 | 10.546 | 60.943% | observed: 完整 |
| 2 | 70.079 | 10.297 | 59.554% | observed: 完整 |

## 节点与进程边界

归属进程 PSS 包含已登记的服务、存储服务及其已观察后代；主验收使用该合计，不代表节点物理内存节省。
sandbox_process_pss 仅是明确 sandbox 标签窗口的观测下界。显式登记前的 VM 已由 provider 后代跟踪
计入归属进程合计，但不在 sandbox 标签内；该辅助曲线不是完整 VM 内存积分或计费量。
node 指 AgentEnv 采样所在执行节点。若服务运行在 remote145 的嵌套节点内，这些是内层 Linux 的口径；
outer145 上承载该节点的进程、宿主页缓存和内存回收没有由这些数据证明。外层数据缺失时物理收益仍为未验证。
全节点 AnonPages、Cached、MemAvailable 含背景负载；共享缓存不能分摊为某一沙箱收益。
暂停写快照期间可能同时出现匿名内存下降和缓存增长；必须共同呈现，不能只选匿名内存下降作为物理收益。

| 任务 | 归属 PSS GiB·s | sandbox 标签 PSS 下界 GiB·s | 节点 anon GiB·s | 节点 cache GiB·s | 节点 available GiB·s |
|---|---:|---:|---:|---:|---:|
| pair-000-resident-16a24805 | 16.700 | 10.665 | 18.309 | 460.877 | 2121.435 |
| pair-000-offload-348d84a5 | 6.397 | 0.619 | 7.782 | 470.710 | 2132.688 |
| pair-001-resident-865c8480 | 17.305 | 10.786 | 18.925 | 465.645 | 2136.022 |
| pair-001-offload-b25188a9 | 6.759 | 0.640 | 8.149 | 475.658 | 2148.109 |
| pair-002-resident-56c0d951 | 17.290 | 10.795 | 18.925 | 464.748 | 2129.444 |
| pair-002-offload-ee3035f9 | 6.993 | 0.650 | 8.382 | 476.005 | 2138.587 |

配对 0 的节点匿名内存积分减少 10.527 GiB·s，缓存积分同时增加 9.833 GiB·s。
这是两类变化并存的观测，尚不能证明它们一一转移，也不能据此宣称节点物理收益。

配对 1 的节点匿名内存积分减少 10.777 GiB·s，缓存积分同时增加 10.013 GiB·s。
这是两类变化并存的观测，尚不能证明它们一一转移，也不能据此宣称节点物理收益。

配对 2 的节点匿名内存积分减少 10.543 GiB·s，缓存积分同时增加 11.257 GiB·s。
这是两类变化并存的观测，尚不能证明它们一一转移，也不能据此宣称节点物理收益。

各曲线峰值、最小值、时钟误差和缺测原因在 summary.json 中保留。

已测任务 PSS 成本合计 71.444 GiB·s；
其中失败任务 0.000 GiB·s。
另有 0 个任务缺少可积分观测；这些成本不补零。
此合计保留失败消耗，但各诊断窗口可能不同，不能作为公平的模式间节省率。

## 磁盘 I/O

进程 I/O 按 (pid,starttime_ticks) 各自差分后相加；新进程首样本前和退出前未采到的 I/O 不冒充精确值。
结果为观察下界，同时保留每个身份首个累计计数及缺测。设备数据为整个节点，只按单个设备列出；
逻辑设备和底层物理设备可能重复描述同一次 I/O，不能把各设备相加。边界采样之外的字节不外推。

| 任务 | 设备 | 观察读字节 | 观察写字节 | 状态 |
|---|---|---:|---:|---|
| pair-000-resident-16a24805 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | vda (253:0) | 0 | 14118912 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | ublkb0 (259:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-resident-16a24805 | ublkb1 (259:2) | 35224576 | 3280896 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | vda (253:0) | 0 | 201981952 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | ublkb0 (259:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-000-offload-348d84a5 | ublkb1 (259:2) | 不可验证 | 不可验证 | counter_reset/counter_reset |
| pair-000-offload-348d84a5 | ublkb2 (259:3) | 不可验证 | 0 | counter_reset/observed_lower_bound |
| pair-001-resident-865c8480 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | vda (253:0) | 0 | 14446592 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | ublkb0 (259:1) | 12288 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-resident-865c8480 | ublkb1 (259:2) | 34257920 | 3280896 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | vda (253:0) | 0 | 207421440 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | ublkb0 (259:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-001-offload-b25188a9 | ublkb1 (259:2) | 不可验证 | 不可验证 | counter_reset/counter_reset |
| pair-001-offload-b25188a9 | ublkb2 (259:3) | 不可验证 | 0 | counter_reset/observed_lower_bound |
| pair-002-resident-56c0d951 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | vda (253:0) | 0 | 13676544 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | ublkb0 (259:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-resident-56c0d951 | ublkb1 (259:2) | 34941952 | 3280896 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop0 (7:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop1 (7:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop2 (7:2) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop3 (7:3) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop4 (7:4) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop5 (7:5) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop6 (7:6) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | loop7 (7:7) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | vda (253:0) | 0 | 195207168 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | vdb (253:16) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | sr0 (11:0) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | ublkb0 (259:1) | 0 | 0 | observed_lower_bound/observed_lower_bound |
| pair-002-offload-ee3035f9 | ublkb1 (259:2) | 不可验证 | 不可验证 | counter_reset/counter_reset |
| pair-002-offload-ee3035f9 | ublkb2 (259:3) | 不可验证 | 0 | counter_reset/observed_lower_bound |

## 建议门槛

门槛由分析参数预先指定；通过进程 PSS 门槛也不能宣称节点物理收益或生产可用。

| 项目 | 结论 |
|---|---|
| 计划任务完整执行 | 通过 |
| 已开始任务正确性与清理 | 通过 |
| 归属进程 PSS 节省 | 通过 |
| 任务 p95 增幅 | 通过 |
| 首工具额外 p95 | 通过 |
| 节点物理节省归因 | 不可验证 |

整体验收状态：不可验证。
计划未完成时保留已完成配对的诊断数字，未开始任务不加入失败分母，也不能据此宣称整轮验收通过。
门槛参数：`{"memory_saving_min": 0.2, "task_p95_increase_max": 0.05, "first_tool_extra_max_seconds": 1.0, "max_sample_gap_seconds": 1.0}`。
原始结果在 results.jsonl、各任务 events.jsonl/metrics.jsonl；summary.json 保留完整失败分母与分析口径。
