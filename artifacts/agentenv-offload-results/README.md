# AgentEnv 实验产物

目录名包含实验参数/阶段及 UTC 时间。所有已开始的失败任务均保留；准备诊断、正式 A/B 和独立清理验证分目录，不合并成一个成功率。

已发布的 `metrics.jsonl`、`sampler.log` 和各轮 `source/` 使用每轮 `raw-data.zip` 保存原始字节，减少仓库体积。分析或绘图前，在该轮目录内解压：

```bash
python -m zipfile -e raw-data.zip .
python source/analyze.py .
python -s /path/to/scripts/agentenv_offload/plot_results.py . \
  --view resources --pair 0 --output resource-cards.png
```

`raw-data-hashes.json` 同时保存 ZIP 及成员的 SHA-256。解压得到 manifest 绑定的当轮源码与原始曲线，不包含凭据，不替换 manifest 或报告。完整实验机目录保留未压缩原数据；本机完整数据旁也保留压缩副本。

主要轮次：

- `benefit-bound1-m8-w30-20261021T154549Z`：此前 8 MiB、按需恢复、3 对正式样本。
- `boundary-bound1-m64-w30-20261021T155607Z`：此前 64 MiB 延迟边界；PSS 缺测保持未知。
- `baseline64-recheck-20261022T015234Z`：本轮未优化的 64 MiB 基线复验，延迟仍不达标；完整保留创建波动。
- `zerocopy64-*`、`readahead64-*`、`fullprefetch64-*`：短诊断，均未证明端到端达标；后两项实验功能没有进入最终实现，实际运行源码保存在各轮 `source/`。
- `lead64-pilot-20261022T020722Z`：提前 1.5 秒恢复的小样本鉴别实验。
- `lead64-formal-*`：固定同一预恢复策略的独立重复，结论见 [64 MiB 报告](../../docs/sandbox_offload_64m_results.md)。

`deployment-evidence/` 是无凭据部署与终态审计白名单。它不包含 SSH 私钥、API key、CLI credentials 或代理环境文件。`validation/` 保留组件测试输出；这些测试不能替代真实 AgentEnv 生命周期实验。

PSS 是归属进程成本，不是整个节点或外层物理 RAM 节省。四卡片中的累计积分和 VM 阶段只使用可验证数据，缺测保持断线；匿名页/缓存曲线用于展示成本，不能当作单沙箱物理归因。
