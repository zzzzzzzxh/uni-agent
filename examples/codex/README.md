# Codex sidecar recipe

本目录实现新版 `uni_agent` 架构下的 Codex 黑盒 Agent。

## 构建

```bash
bash examples/codex/build_tool.sh \
  --version 0.147.0 \
  --registry swr.cn-east-3.myhuaweicloud.com/openyuanrong
```

构建产物：

```text
swr.cn-east-3.myhuaweicloud.com/openyuanrong/codex-tool:0.147.0-direct
```

镜像挂载到任务沙箱后，入口为：

```text
/opt/codex/bin/run_agent.sh
```

## 运行参数

宿主机 Agent 会传入：

```text
CODEX_API_BASE
CODEX_MODEL
CODEX_API_KEY
CODEX_PROJECT_DIR
CODEX_HOME
```

Codex CLI 在沙箱中执行：

```bash
codex exec --json --ephemeral \
  --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox \
  --cd /testbed \
  --model <model> -
```

`-` 表示从 stdin 读取任务 prompt。

## 训练

```bash
bash examples/codex/run_train.sh
```

训练入口使用：

```text
examples/codex/task_config_codex.yaml
uni_agent.framework.task_runner.run_task
```

默认总轨迹容量仍为 16K。需要 128K 总容量时，可以设置：

```bash
TRAJECTORY_LENGTH=131072 PROMPT_LENGTH=8192 bash examples/codex/run_single_node_framework_smoke.sh
```

这会得到 prompt=8192、response=122880、max_model_len=131072。
如果需要的是 128K response，再设置 RESPONSE_LENGTH=131072，此时总
max_model_len=135168。

## 多轮消息兼容

Codex Responses API 可能把一个 assistant turn 拆成独立的 `reasoning` 和
`function_call` items。Gateway 会在 session prefix matching 和
`encode_incremental` 之前，把相邻 assistant fragments 归一化为一条内部
assistant message；后续的 `function_call_output` 则作为下一次生成的 tool
message。这样 Codex continuation 可以兼容现有 ReAct/swe-agent 的 transcript
格式。

## 注意事项

Codex 0.147.0 走 Responses API。Gateway 的直接 endpoint 是
`/sessions/<session_id>/v1/responses`，checked-in sidecar 直接使用该 endpoint。
现有 ReAct/SWE-agent 客户端仍使用
`/sessions/<session_id>/v1/chat/completions`；两条入口在 gateway 内部共享
canonical continuation 处理，Codex sidecar 不再启动 Responses-to-Chat bridge。
