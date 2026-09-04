# Codex Qwen3.5 recipe

This directory adds Codex as a black-box agent to the current `uni_agent`
architecture. Codex runs in the mounted sidecar and talks directly to the
session's Responses endpoint:

```text
verl/main_ppo -> AgentFrameworkRolloutAdapter -> run_task -> CodexAgent
  -> /opt/codex/bin/run_agent.sh -> /v1/responses -> reward
```

The recipe keeps the release launcher shape: configuration is supplied through
environment variables and the launcher delegates the actual training command
to `verl/main_ppo`. It does not start `vllm serve` directly.

## Standard-style launch

The single-node 128K Codex acceptance shape is:

```bash
DATA_DIR=/home/zxh/data \
RUNTIME_DIR=/home/zxh/runtime \
NNODES=1 \
CONCURRENCY=1 \
GEN_TP=8 \
TP=8 PP=1 CP=1 \
TRAIN_PROMPT_BSZ=1 \
N_RESP_PER_PROMPT=1 \
PPO_MINI_BATCH_SIZE=1 \
TASK_CONFIG=examples/codex/task_config_codex.yaml \
MASK_UNFINISHED_EPISODE=True \
EXP_NAME=codex_qwen3p5_9b_128k \
ADV_ESTIMATOR=grpo \
CLIP_RATIO_LOW=0.0004 \
CLIP_RATIO_HIGH=0.0004 \
CLIP_RATIO_C=10 \
LOSS_AGG_MODE=token-mean \
TEST_FREQ=-1 \
bash examples/codex/train_qwen3p5_codex.sh
```

Override `MODEL_PATH`, `TRAIN_FILE`, and `TEST_FILE` when the local data layout
differs. For a synchronous local acceptance run, set `RAY_SUBMIT_MODE=local`;
the release-style default is `job`.

The default target uses Qwen3.5-9B, one node/eight GPUs, `GEN_TP=8`,
`TP=8 PP=1 CP=1`, one prompt, one response, and a 128K total trajectory
(`MAX_PROMPT_LENGTH=8192`, `MAX_RESPONSE_LENGTH=122880`). The Qwen3.5 wrapper
uses a high 8192-token per-turn budget by default so a Codex tool continuation
returns before consuming the whole episode; set `MAX_TOKENS_PER_TURN=0` only
when an unlimited per-request budget is explicitly required.

Qwen3.5 text-only Codex runs use `VLLM_LANGUAGE_MODEL_ONLY=1`,
`QWEN_ENABLE_THINKING=false`, `VLLM_REASONING_PARSER=qwen3`, and the
`qwen3_coder` tool parser. Set `VLLM_LANGUAGE_MODEL_ONLY=0` for image/video
tasks. Qwen3.5's strict no-user chat-template fallback is handled at the
recipe's `MessageCodec` boundary, so the pinned `verl` checkout stays clean.

## Sidecar

Build the fixed Codex sidecar with:

```bash
bash examples/codex/build_tool.sh \
  --version 0.147.0 \
  --registry swr.cn-east-3.myhuaweicloud.com/openyuanrong
```

The image is mounted at `/opt/codex`; `run_agent.sh` configures Codex's
Responses provider and reads the task prompt from stdin.
