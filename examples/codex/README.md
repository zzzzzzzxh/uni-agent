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
swr.cn-east-3.myhuaweicloud.com/openyuanrong/codex-tool:0.147.0
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

## 注意事项

Codex 0.147.0 走 Responses API，因此必须同时启用 Gateway 的 `/v1/responses` 适配器；仅有 `/v1/chat/completions` 不能完成真实 Codex 请求。
