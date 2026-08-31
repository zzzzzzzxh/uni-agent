# Codex 接入方案（新版架构）

## 目标

在 `uni_agent/agents/`、`uni_agent/sandbox/`、`uni_agent/tasks/` 和 `uni_agent/framework/task_runner.py` 的新版架构下，将 Codex CLI 作为一个可注册的黑盒 Agent，运行在 OpenYuanRong Sandbox 内的预构建 sidecar 中。

## 运行链路

```text
AgentFrameworkRolloutAdapter
  -> framework.task_runner.run_task
  -> TaskConfigResolver
  -> swe_bench / swe_rebench Task
  -> OpenYuanRongSandbox
  -> CodexAgent
  -> /opt/codex/bin/run_agent.sh
  -> codex exec --json
  -> Gateway /v1/responses
  -> reward
```

## 组件职责

- `uni_agent/agents/codex/agent.py`：定义 `CodexConfig`、构造沙箱命令、传递 Gateway 配置、解析 Codex JSONL 结果、返回 `AgentResult`。
- `examples/codex/Dockerfile.codex-tool`：安装固定版本 Codex npm 包，提取 Linux x64 原生二进制及其 `rg`、`bwrap`、zsh 资源，生成 `FROM scratch` sidecar。
- `examples/codex/run_agent.sh`：在沙箱内创建隔离 `CODEX_HOME/config.toml`，配置 Responses API endpoint，关闭 Codex 内部审批和沙箱，使用外层 OpenYuanRong Sandbox 作为安全边界。
- `examples/codex/task_config_codex.yaml`：声明 SWE 任务、镜像映射和 `/opt/codex` 挂载。
- `uni_agent/gateway/adapters/responses.py`：把 Codex Responses API 请求降级为内部 canonical chat request，并把模型结果重新封装为 Responses JSON/SSE。
- `uni_agent/sandbox/`：负责沙箱生命周期、命令执行、文件传输和 sidecar mount；Codex Agent 不直接依赖 OpenYuanRong SDK。
- `uni_agent/tasks/`：负责 task 配置、沙箱生命周期和 reward；Agent 不负责 reward。

## Endpoint 设计

Codex 0.147.0 使用 Responses API，不能再使用已移除的 `wire_api = "chat"`。因此 Gateway 需要暴露：

```text
/sessions/<session_id>/v1/responses
```

`responses.py` 将以下内容转换为内部请求：

- `instructions` → system message；
- Responses `input` message → canonical message；
- `function_call` / `function_call_output` → assistant tool call / tool message；
- Responses function / namespace tools → OpenAI chat tool schema；
- `max_output_tokens` → 内部 `max_tokens`。

返回时将内部 `assistant_msg` 转换成：

- 普通回答：Responses message output；
- 工具调用：Responses function_call output item；
- 流式请求：`response.output_text.*`、`response.function_call_arguments.*` 和 `response.completed` 事件。

## 隔离和安全

- 每个 Sandbox 使用独立 `CODEX_HOME`。
- 使用 `--ephemeral`，避免持久化 Codex 会话。
- 使用 `--skip-git-repo-check`，因为任务仓库可能不是当前 uid 所有。
- 使用 `--dangerously-bypass-approvals-and-sandbox`，仅允许在外层 OpenYuanRong Sandbox 已经提供隔离时使用。
- API key 只通过进程环境变量传递，不写入仓库或日志。
- 关闭外部代理，确保请求只通过当前 session 的 Gateway tunnel。

## 验证顺序

1. 新架构 import 和单元测试。
2. Codex 原生 sidecar `--version`。
3. 假 Gateway 验证 `/v1/responses` 请求和 SSE 响应。
4. remote186 的 Sandbox smoke test。
5. remote186 单样本 Codex + Gateway + SWE reward 闭环。
6. 最后再做小并发训练验证。
