#!/usr/bin/env bash
# Run exactly one Codex episode through the official uni-agent/verl rollout path.
#
# Unlike the historical single_swe_rollout.sh helper, this script never starts
# vLLM directly.  vLLM is created by verl's rollout worker from run_train.sh;
# the framework then invokes uni_agent.framework.task_runner.run_task and the
# finalized trajectory is checked under AGENT_LOG_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKSPACE_HOME="${WORKSPACE_HOME:-/home/zxh}"
CONDA_SH="${CONDA_SH:-${WORKSPACE_HOME}/miniconda3/etc/profile.d/conda.sh}"
CONDA_ENV="${CONDA_ENV:-uni-agent-codex-rc1-megatron311}"
MODEL_PATH="${MODEL_PATH:-${WORKSPACE_HOME}/models/Qwen/Qwen3.5-9B}"
SOURCE_DATA="${SOURCE_DATA:-${WORKSPACE_HOME}/sandbox/swe_bench_verified_openyuanrong.parquet}"
SAMPLE_INDEX="${SAMPLE_INDEX:-0}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/artifacts/codex-single-node-framework}"
SMOKE_DATA="${SMOKE_DATA:-${ARTIFACT_DIR}/single_sample.parquet}"
TASK_CONFIG_TEMPLATE="${TASK_CONFIG_TEMPLATE:-${SCRIPT_DIR}/task_config_codex.yaml}"
TASK_CONFIG="${TASK_CONFIG:-${ARTIFACT_DIR}/task_config_codex.yaml}"
SIDECAR_IMAGE="${SIDECAR_IMAGE:-swr.cn-east-3.myhuaweicloud.com/openyuanrong/codex-tool:0.147.0-direct-stdin}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-${ARTIFACT_DIR}/framework_logs}"
OPENYUANRONG_ENV="${OPENYUANRONG_ENV:-${WORKSPACE_HOME}/.config/uni-agent/openyuanrong.env}"

[[ -f "${CONDA_SH}" ]] || { echo "Conda initializer not found: ${CONDA_SH}" >&2; exit 2; }
[[ -f "${OPENYUANRONG_ENV}" ]] || { echo "OpenYuanRong environment file not found: ${OPENYUANRONG_ENV}" >&2; exit 2; }
source "${CONDA_SH}"
source "${OPENYUANRONG_ENV}"
conda activate "${CONDA_ENV}"

for required in "${MODEL_PATH}/config.json" "${SOURCE_DATA}" "${TASK_CONFIG_TEMPLATE}"; do
    [[ -e "${required}" ]] || { echo "Required file not found: ${required}" >&2; exit 2; }
done

mkdir -p "${ARTIFACT_DIR}" "${AGENT_LOG_DIR}"
rm -f "${SMOKE_DATA}" "${TASK_CONFIG}" "${ARTIFACT_DIR}/trajectory-verification.json"

# Keep the official release dataset format, but reduce it to one row so the
# framework's persisted output can be counted unambiguously.
python - "${SOURCE_DATA}" "${SMOKE_DATA}" "${SAMPLE_INDEX}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

source, target, raw_index = sys.argv[1:]
frame = pd.read_parquet(source)
index = int(raw_index)
if index < 0 or index >= len(frame):
    raise SystemExit(f"SAMPLE_INDEX={index} is outside dataset with {len(frame)} rows")
selected = frame.iloc[[index]].copy()
row_index = selected.index[0]
extra_info = selected.at[row_index, "extra_info"]
if isinstance(extra_info, dict):
    tools_kwargs = extra_info.get("tools_kwargs")
    if isinstance(tools_kwargs, dict) and "task" not in tools_kwargs:
        reward_config = tools_kwargs.get("reward")
        if not isinstance(reward_config, dict) or not reward_config.get("name"):
            raise SystemExit("legacy extra_info.tools_kwargs is missing reward.name; cannot build task config")
        normalized_task = {
            "name": str(reward_config["name"]),
            "metadata": dict(reward_config.get("metadata") or {}),
        }
        deployment = (tools_kwargs.get("env") or {}).get("deployment")
        if isinstance(deployment, dict) and deployment.get("image"):
            normalized_task["sandbox"] = {"image": str(deployment["image"])}
        normalized_tools = dict(tools_kwargs)
        normalized_tools["task"] = normalized_task
        normalized_extra = dict(extra_info)
        normalized_extra["tools_kwargs"] = normalized_tools
        selected.at[row_index, "extra_info"] = normalized_extra
        print(f"normalized legacy tools_kwargs into task: name={normalized_task['name']}")
Path(target).parent.mkdir(parents=True, exist_ok=True)
selected.to_parquet(target, index=False)
print(f"wrote one sample: source_rows={len(frame)} sample_index={index} target={target}")
PY

# Let the smoke command select the already-built remote sidecar without
# changing the checked-in public task config.  The task runner still consumes
# this YAML through the normal TaskConfigResolver path.
python - "${TASK_CONFIG_TEMPLATE}" "${TASK_CONFIG}" "${SIDECAR_IMAGE}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

source, target, image = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
pattern = r"(?m)^(\s*image_url:\s+)\S*codex-tool:\S+\s*$"
text, replacements = re.subn(pattern, rf"\g<1>{image}", text)
if replacements == 0:
    raise SystemExit("task config has no codex-tool image_url to override")
Path(target).write_text(text, encoding="utf-8")
print(f"wrote runtime task config: {target} sidecar={image} replacements={replacements}")
PY

export REPO_ROOT
export MODEL_PATH
export TRAIN_DATA="${SMOKE_DATA}"
export VAL_DATA="${SMOKE_DATA}"
export TASK_CONFIG
export AGENT_LOG_DIR
export RAY_SUBMIT_MODE="local"
export RAY_RESOURCE_KEY="GPU"
export NNODES=1
export N_GPUS_PER_NODE="${N_GPUS_PER_NODE:-8}"
export ROLLOUT_NNODES=0
export ROLLOUT_NGPUS_PER_NODE="${ROLLOUT_NGPUS_PER_NODE:-${N_GPUS_PER_NODE}}"
export TRAINER_MODE="colocate_async"
export VERL_CONFIG_NAME="ppo_megatron_trainer"
export USE_MBRIDGE=True
export GEN_TP="${GEN_TP:-8}"
export TRAIN_TP="${TRAIN_TP:-8}"
export TRAIN_PP="${TRAIN_PP:-1}"
export TRAIN_CP="${TRAIN_CP:-1}"
export OFFLOAD="${OFFLOAD:-False}"
export USE_MBRIDGE=True
export TOOL_PARSER="qwen3_coder"
export GATEWAY_COUNT=1
export MAX_CONCURRENT_SESSIONS=1
export NUM_AGENT_WORKERS=1
export SESSION_TIMEOUT_SECONDS=900
export N=1
export TRAIN_MAX_SAMPLES=1
export VAL_MAX_SAMPLES=0
export TRAIN_BATCH_SIZE=1
export VAL_BATCH_SIZE=1
export PPO_MINI_BATCH_SIZE=1
export PPO_MICRO_BATCH_SIZE_PER_GPU=1
export USE_DYNAMIC_BSZ=True
export TRAJECTORY_LENGTH="${TRAJECTORY_LENGTH:-16384}"
export PROMPT_LENGTH="${PROMPT_LENGTH:-8192}"
if [[ -z "${RESPONSE_LENGTH:-}" ]]; then
    export RESPONSE_LENGTH=$((TRAJECTORY_LENGTH - PROMPT_LENGTH))
else
    export RESPONSE_LENGTH
fi
export MAMBA_CACHE_MODE="${MAMBA_CACHE_MODE:-align}"
export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
export VLLM_LANGUAGE_MODEL_ONLY="${VLLM_LANGUAGE_MODEL_ONLY:-1}"
export QWEN_ENABLE_THINKING="${QWEN_ENABLE_THINKING:-false}"
export VLLM_REASONING_PARSER="${VLLM_REASONING_PARSER:-qwen3}"
export ROLLOUT_GPU_MEM_UTIL="${ROLLOUT_GPU_MEM_UTIL:-0.20}"
export TOTAL_EPOCHS=1
export TOTAL_TRAINING_STEPS=1
export VAL_BEFORE_TRAIN=false
export SAVE_FREQ=1000000
export TEST_FREQ=1000000
export PROJECT_NAME="${PROJECT_NAME:-codex_formal_smoke}"
export EXPERIMENT_NAME="${EXPERIMENT_NAME:-single_node_$(date +%Y%m%d_%H%M%S)}"
export CKPTS_DIR="${CKPTS_DIR:-${ARTIFACT_DIR}/checkpoints}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}"
export PYTHONUNBUFFERED=1

echo "=== Codex formal framework smoke ==="
echo "Model:       ${MODEL_PATH}"
echo "Data:        ${SMOKE_DATA}"
echo "Task config: ${TASK_CONFIG}"
echo "Sidecar:     ${SIDECAR_IMAGE}"
echo "Resources:   one node / 8 GPUs; colocated trainer+rollout"
echo "Path:        verl rollout.name=vllm -> AgentFrameworkRolloutAdapter -> run_task"
echo "Artifacts:   ${ARTIFACT_DIR}"

if [[ "${PREFLIGHT_ONLY:-0}" == "1" ]]; then
    echo "Preflight only: dataset and runtime task config prepared; skipping verl launch."
    exit 0
fi

# run_train.sh owns the only launch of verl/main_ppo.  In particular, this
# script intentionally contains no direct vLLM server launch.
bash "${SCRIPT_DIR}/run_train.sh" "$@" 2>&1 | tee "${ARTIFACT_DIR}/framework.log"

python - "${AGENT_LOG_DIR}" "${ARTIFACT_DIR}/trajectory-verification.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

log_dir, output = map(Path, sys.argv[1:])
files = sorted(log_dir.rglob("trajectory.json"))
records = []
for path in files:
    record = json.loads(path.read_text(encoding="utf-8"))
    records.append({"path": str(path), **record})

trajectory_count = sum(int(record.get("num_trajectories", 0)) for record in records)
summary = {
    "trajectory_files": len(records),
    "trajectory_count": trajectory_count,
    "records": records,
}
output.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False, indent=2))

if len(records) != 1:
    raise SystemExit(f"expected exactly one persisted trajectory.json, found {len(records)}")
if trajectory_count != 1:
    raise SystemExit(f"expected exactly one persisted trajectory, found {trajectory_count}")
if int(records[0].get("num_trajectories", 0)) != 1:
    raise SystemExit("the sole framework trajectory.json does not contain num_trajectories=1")
PY

echo "Formal Codex framework smoke passed: exactly one persisted trajectory."
