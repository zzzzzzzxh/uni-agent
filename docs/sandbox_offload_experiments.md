# AgentEnv 卸载与恢复 Demo 实验记录

日期：2026-10-21。范围：开发独立 Demo，在 AgentEnv 上比较常驻与运行态卸载，从 remote186 发起实验。

## 问题与判定

可证伪问题：在相同 AgentEnv 版本、镜像、资源规格及外部推理等待序列下，安全工具边界的 pause/resume 能否降低沙箱运行态内存时间积分，并让释放的资源可以再次使用，同时将恢复、整任务延迟、失败及磁盘 I/O 保持在可接受范围？

先验证 RAM/进程/文件状态连续和旧虚机真正退出，再衡量性能。不能将 API 成功、暂停配额或进程 RSS 单独替代物理内存结论。模拟外部等待明确标注；没有真实模型负载时不宣称已经验证真实模型吞吐。

设计建议的初始配置为单沙箱、256 MiB 已触碰内存、一个暂停/恢复周期；实际先用 16 MiB 常驻与 64 MiB 卸载 canary 验证机制，再按下文诊断调整，每次只改变一个控制项。正式配置与重复数均在对应 run 的 manifest 中登记。长等待与较多驻留状态是候选场景，收益与首触页代价必须共同实测；其余未执行规格不写成已验证边界。

参考门槛：状态完整性、无重复副作用、无残留为硬要求；目标场景内存积分下降 20%、整任务 p95 增加不超过 5%、首工具额外等待 p95 不超过 1 秒是待实测的性能目标。原始曲线与失败全部保留，不为达标删除失败或事后更换比较口径。

## 执行环境预检

| 机器 | 实际内核/架构 | 本轮角色 |
|---|---|---|
| remote186 | 5.4.0-216-generic / x86_64；Conda `uni-agent` Python 3.11.15 | 编排与结果保存；已有其他任务的 Firecracker 进程不属于本实验 |
| remote145 | 5.4.0-216-generic / x86_64；KVM nested=Y | 承载本轮专用外层 QEMU VM |
| remote126、remote114 | 5.10.0 / aarch64 | 未部署；现有内核不满足固定 AgentEnv 版本的要求 |
| 专用执行节点 | Ubuntu 24.04，6.8.0-147-generic / x86_64；嵌套 `/dev/kvm` 存在 | AgentEnv 服务、Firecracker 沙箱及宿主采样 |

没有修改共享宿主内核或重启共享机器。专用节点配置为 8 vCPU、32 GiB RAM、100 GiB 稀疏系统盘；外层 QEMU 4.2.1，镜像下载后已用官方 SHA-256 清单校验。实际镜像摘要、启动参数与 balloon 支持情况保存在部署目录。是否能在该嵌套环境运行完整 AgentEnv 路径，须后续实例实验确认。

内存必须分三层报告：remote186 客户端、专用 AgentEnv 执行节点、remote145 外层 QEMU。内层进程退出或 guest 可用内存增加，不能自动解释为外层宿主已回收同样大小的物理 RAM。

## 位置与归属

- 外层节点目录：`remote145:/home/zxh/agentenv-offload-deployment`。QEMU PID 与磁盘、console、镜像校验记录均保存在该目录；只管理该目录创建的 VM。
- AgentEnv 节点目录：`/opt/agentenv-offload`；源码固定 `a27b2db909b035f58696ba8798ea0e285c7bfa17`，state、serial 日志、构建日志分别保存。
- 实验客户端目录：`remote186:/home/zxh/uni-agent-sandbox-offload`，使用 `/home/zxh/miniconda3/envs/uni-agent/bin/python`。
- 节点 SSH 配置与专用密钥只存在远端权限受限的 `node-access` 目录，不进入仓库或实验输出。API 凭据同样使用受限配置，不输出其内容。

## 已完成的开发与检查

- `scripts/agentenv_offload/guest_probe.py`：驻留随机 RAM nonce、完整内存摘要、打开文件偏移、文件/计数工具操作及进程内命令 ID 去重。
- `scripts/agentenv_offload/host_sampler.py`：动态 PID/starttime 归属、PSS/匿名内存、全节点缓存与压力、每设备磁盘 I/O；缺测标记，不混入其他进程。
- `scripts/agentenv_offload/prepare_vm.sh`：准备隔离现代 Linux 节点，保留现有磁盘及 VM 归属，不删除共享资源。
- 在 remote186 的 Python 3.11 环境完成状态探针、采样器、编排器和分析器测试；已覆盖真实独立进程状态、Linux 子进程采样、首次失败停止、完整失败分母及手工曲线积分。每次新增修正后的实际数量及输出保存在客户端 `validation/*-tests.log`，测试不替代真实后端实验。

## 部署进度与固定输入

- 专用节点已通过 KVM API 12、创建 VM 和 vCPU 的实际调用检查，随后立即关闭这些预检句柄；不只检查设备文件存在。
- `ublk_drv` 与匹配内核 extra 模块已安装，`/dev/ublk-control` 已出现。
- GitHub 直连中断后，使用本地已核验的固定源码转入节点，保留 `.git`；Unix 检出后 HEAD 精确匹配且工作区干净。
- 源码构建使用 Rust/Cargo 1.99.1；2026-10-21 14:35 UTC 已开始固定版 release 构建，构建日志保存在节点部署目录。本条不表示构建或服务已经就绪。
- 官方 Python `3.11-slim-bookworm` 的 Linux amd64 manifest 已按内容 SHA-256 校验：`docker.io/library/python@sha256:8fb0b110b022c70cbe09d3ff1fb313654f31f9c814abb0d48180af56d906a199`。解析记录保存在 `artifacts/agentenv-offload-preparation/image-manifest.json`；压缩层总计 47,618,423 字节，尚不代表已能在 AgentEnv 中启动。
- remote186 的客户端 API 入口通过专用节点 SSH 转发到 loopback 18800；构建下载使用独立、无凭据的代理通路，内网流量从代理排除。
- remote145 上额外采集本轮 QEMU 及共享宿主指标。外层 QEMU 4.2.1 不支持本脚本检测的 free-page-reporting，不能把内层释放 RAM 等同于外层宿主已减少同量 RSS。

## 服务就绪与功能 canary

- 固定版构建耗时 8 分 13 秒。专用节点 `agentenv-offload.service` 已启动，server PID 34475、ublk daemon PID 34501；源码 HEAD 与 `/nodes.commit` 均核对为 a27b2db，工作区干净。
- remote186 通过 loopback 18800 的 SSH 隧道实际访问 `/health`、鉴权 `/nodes`。节点初始为 0 个活动、0 个暂停沙箱，报告 8 CPU、32 GiB 左右内存。
- 第一轮常驻 canary：16 MiB 探针、1 次工具操作，创建 32.71 秒，原生命令、状态服务和工具正确；实例 GET 404、原 Firecracker 消失。首次清理发现新增 `/dev/ublkb0`，原始结果保留 `pending`。
- 已通过 daemon 日志、进程 FD、工具镜像摘要和固定源码核实该确切 dev0 为服务保留的 tools 0.1.1 共享设备；本次 rootfs dev1 已删除。脱敏核实记录为节点 `/opt/agentenv-offload/reconciliation.json`。未通过删除共享缓存或重启服务来抹掉差异；后续以已初始化的共享工具盘为固定背景，继续审计所有新增设备。
- 第一轮卸载 canary：64 MiB、模拟等待 2 秒、1 周期，真实 pause/resume 和 RAM nonce/进程/文件/FD oracle 全部通过；pause 约 0.653 秒，resume API 约 0.469 秒，含全 RAM 校验与首工具约 2.202 秒。删除后无新增设备、netns 或所属暂停产物，清理完整通过。

canary 路径：`remote186:/home/zxh/uni-agent-sandbox-offload/results/smoke-resident-20261021T145535Z`、`smoke-offload-20261021T150050Z`。功能 canary 不作为正式性能样本。

## 首轮配对诊断：30 秒等待、64 MiB

Artifact：`remote186:/home/zxh/uni-agent-sandbox-offload/results/pilot-wait30-m64-20261021T150340Z`。同一节点、固定镜像、2 周期、1 对随机顺序任务、90 秒观察窗。

- 两个任务均正确且完整清理。常驻任务 68.056 秒，卸载任务 78.810 秒，单对增幅约 15.8%；包含冷创建波动，不能当成稳定延迟差。
- 卸载任务的首工具约 3.228/2.138 秒，常驻任务约 0.37 秒量级；本轮尚未达到建议的延迟目标。
- 两组各约 905 个样本、100 ms 稳定采样，覆盖足够；但第一次 pause 中的一个 Firecracker `smaps_rollup` 不可读，原数据缺乏地址空间已释放的独立证据。因此 PSS 配对收益保留 `unverified`，不补零。
- 节点匿名页积分减少约 10.41 GiB·s，但缓存积分增加约 10.66 GiB·s；可用内存积分增加约 11.81 GiB·s。必须同时保留这些量，不能只摘取匿名页下降声称总物理内存下降。
- 下一轮先补充采样器对退出过程中地址空间释放的证据，再以同样工作负载重新采集；旧诊断数据不改写为通过。

上述首轮诊断不作为最终收益证据。后续真实运行、对照与保留的失败如下，最终结论见 [实测报告](sandbox_offload_results.md)。

## 采样与控制路径修正

- 对退出过程中 `smaps_rollup` 不可读的情况保留原始错误与 errno。只有独立读取同 PID/starttime 的 maps 为空，且最终 VSZ/RSS 为零，才以完整证据记录 `address_space_released`；其他缺测保持未知。旧数据不回填。
- 恢复路径 v2 要求 connect 严格返回 201；200 视为意外恢复/观测污染。只执行一次合并的 SSH 进程发现与登记，去除 idle 结束时多余 SSH；仍保留全 RAM 摘要校验，不通过缩小 oracle 改善延迟。
- 资源审计 v2 同时检查 `/run/netns` 和 `/run/agentenv-offload/netns`、本次暂停产物与 managed snapshot、ublk 设备；不能只查全局 netns。
- 在 remote186 的 Python 3.11 完成 39 项组件测试：probe 5、sampler 9、demo 16、analysis 9；输出在 `validation/`。脚本静态检查与 shell 语法检查通过。

## 有界预热池与独立 warmup

在独立准备阶段将全局 low/high 改为 1/1，开启 Firecracker maintenance/startup prewarm，fill concurrency=1；block 和 network maintenance 关闭。配置文件 SHA-256 为 `5fde917e5ef742136092c9acd78f9fead00079b96cd7c0980a695c3698ebdf71`。正式 A/B 前后摘要均一致。服务 PID 35896、存储 PID 35918，后续正式和边界运行未重启服务。

`warmup-bound1` 在创建前因复用 SSH ControlPersist 到期导致 API 隧道不可达，未创建业务实例；失败另目录保留。改为独立、禁用复用的专用 API 转发后，`warmup-bound1-v2-20261021T153454Z` 完成 3 次状态连续的恢复。该准备轮首次初始化 tools 设备与额外网络缓存，原始清理差异保留，经源码、FD、设备角色和库存独立核实后记录 `warmup-reconciliation.json`，作为后续固定背景，不改写旧轮。

稳定空闲背景为 1 个约 2.05 MiB PSS 的 `Not started` Firecracker、共享 tools `/dev/ublkb0`、2 个已归属网络槽；无业务 Running/Starting/Paused。关闭 network maintenance 阻止补池，不禁止网络缓存，不能把缓存槽误判为业务泄漏或为了清零而删除。

## 小状态配对诊断与正式收益

`pilot-bound1-m8-w30-20261021T153834Z`：8 MiB、低熵、dirty-ratio=0、30 秒等待、2 周期、1 对。正确性与完整清理均通过，PSS 积分下降 56.89%，任务耗时 66.462→69.094 秒（+3.96%），配对首工具额外任务 p95 0.887 秒。此诊断用于确定正式独立重复配置，不与正式轮合并。

正式轮 `benefit-bound1-m8-w30-20261021T154549Z`：保持同一负载，3 对独立任务，每任务至少 90 秒观察覆盖，实际配对共同积分窗约 70.08–70.17 秒。每任务约 905 个样本；最大间隔 0.102 秒，时钟校准最大误差界 0.024 秒。没有未知 PSS 样本或重复进程身份；两个地址空间释放样本均有独立证明。

- 6/6 任务正确、无重复副作用且完整清理；同一逻辑 sandbox 恢复，旧 Firecracker 消失，RAM/进程/文件/FD oracle 通过。
- 归属服务/存储/后代合计 PSS 积分，任务均值 12.398→5.388 GiB·s，三对加权下降 **56.54%**。
- 任务 p95 66.479→68.138 秒，**+2.49%**；首工具任务 p95 0.078→0.942 秒，配对额外任务 p95 **0.871 秒**。
- 暂停完成 0.378–0.506 秒，恢复 API 0.455–0.537 秒；API+SSH 归属检查 0.515–0.598 秒。全 RAM oracle 与首工具继续计入端到端恢复成本。
- 根设备 vda 写入任务均值 13.207→132.725 MiB，额外 **119.518 MiB**；暖缓存下 vda 读取观察值为 0，不等于零逻辑读取。
- 匿名页减少与缓存增长并存，物理节点归因仍未知。主轮的五项进程/任务门槛通过，保守分析器整体仍为 `unverified`，不宣称整机或外层宿主净 RAM 节省。

本地完整主轮、源码、原始曲线及图表见 [正式 artifact](../artifacts/agentenv-offload-results/benefit-bound1-m8-w30-20261021T154549Z/report.md)。这只是合成等待和小状态场景的探索结果，不是 SLA。

## 64 MiB 边界与网络依赖

`boundary-bound1-m64-w30-20261021T155607Z` 只将状态改为 64 MiB，保持池、等待与控制路径，1 对、2 周期。2/2 正确清理，但任务 67.763→71.241 秒（+5.13%），首工具任务 p95 0.355→2.153 秒，配对额外 1.798 秒，超过本轮延迟门槛。一个进程消失竞态样本无法验证 PSS，原始值保留未知，不为获取收益数字补零。

`final-cached-validation-20261021T160504Z` 为独立离线依赖检查，主动停用本任务下载代理后，`POST /sandboxes-cold` 返回 500：`regctl manifest get` 仍需访问 registry，五次请求因代理端口拒绝连接失败，尚未进入业务实例创建。编排器保守记录 create outcome unknown、cleanup=false 并停止；后续只读审计确认 API 列表为空、全部业务账本为零、无暂停产物，失败原记录不改写。结论：镜像层已缓存不保证创建可离线完成。

恢复下载网络后，独立 `final-paused-delete-20261021T161240Z` 在同一池完成 8 MiB、2 秒等待、1 周期，再明确 pause 后直接 DELETE：`success=true`、`cleanup.confirmed=true`、`final_cleanup_state=paused`，资源审计 v2 为 `no_observed_residue`；本轮暂停产物和 managed snapshot 均不存在，无新增设备或 namespace。此轮是清理路径验证，不混入性能组。

## 交付终态

AgentEnv 服务、专用 VM、API 隧道和所需下载通路保留以便复现；业务沙箱均已删除。最终只读审计和无凭据部署元数据保存在 `deployment-evidence/`；共享预热/工具/网络背景单独列明。外层只读采样已停止，仅停止本次登记的 sampler；QEMU 保留运行。外层原始采样压缩归档并校验 12007 行 JSON 完整，没有将内层 PSS 直接当作外层 RAM 收益。

服务凭据仅在远端受限文件中。部署白名单复制前后均按实际 key 字节扫描，零命中；结果及测试日志不复制凭据目录。具体复现命令与解释见 [指南](../scripts/agentenv_offload/README.md) 和 [实测报告](sandbox_offload_results.md)。

## 2026-10-22：64 MiB 优化与独立复验

本轮保留 64 MiB、30 秒模型等待、2 周期、同一镜像/服务/池。未优化复验再次失败，首工具额外 1.830 秒；创建波动占任务增幅的大部，仍不从验收中扣除创建成本。源码和实际映射确认普通 pause/resume 走 File backend，不误改 UFFD 路径。

依次测试完整 SHA-256 零复制、恢复后扩大设备预读窗口、整内存设备并行预读；后两项没有端到端收益，代码不保留其试验选项，原数据与对应源码另目录保留。零复制保留同等全字节校验，不是本轮达标原因。

选定显式提前 1.5 秒恢复策略后，先运行 `lead64-pilot-20261022T020722Z` 单对鉴别，再固定配置执行 `lead64-formal-20261022T021123Z` 三对正式重复。六任务均正确且完整清理，三对 PSS 加权下降 **60.72%**、任务 p95 **+0.91%**、配对首工具额外任务 p95 **0.289 秒**。主指标包括提前占回的驻留成本。真实恢复至完整 RAM oracle 仍为 1.845–1.944 秒；该策略利用精确已知的合成等待期限，不是底层恢复提速，也没有证明真实模型预测能力。

独立 `lead64-paused-delete-20261022T022146Z` 进一步验证 64 MiB 暂停态 DELETE，v2 审计无残留。最终审计确认 7 个本轮 SID 不存在、业务/Starting/Paused 均零；保留 1 warmFC、共享 tools b0 和 2 个网络槽，服务 PID/starttime 未变。

47 项后端组件测试在 remote186 Python 3.11 通过，另有本地绘图测试；旧样本不回填。正式每任务 905 行，零内存缺测/重复身份；顺序采样误差、地址空间释放证据、缓存和写盘代价均报告。详见 [64 MiB 结果](sandbox_offload_64m_results.md)、[源码调研](sandbox_offload_64m_research.md) 与 [独立核算](sandbox_offload_64m_validation.md)。

图表使用实测曲线，参考四卡片布局呈现 PSS、累计成本、业务 VM 阶段及匿名页/缓存；无平滑、未知留白。原始 metrics/log 以逐轮 `raw-data.zip` 发布并保留字节摘要，完整未压缩数据仍在实验机。
