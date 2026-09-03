#!/usr/bin/env bash
set -xeuo pipefail

# Standard-style Codex launcher. The shape intentionally follows
# examples/quickstart/training/train_qwen3p5_dense.sh; run_train.sh owns the
# verl/main_ppo invocation and verl's rollout manager owns vLLM.
project_name=${PROJECT_NAME:-"Uni-Agent-Codex-Qwen3.5-9B"}
exp_name=${EXP_NAME:-"$(date +%Y%m%d%H)_codex"}

MODEL_PATH=${MODEL_PATH:-"${DATA_DIR}/models/Qwen/Qwen3.5-9B"}
TRAIN_FILE=${TRAIN_FILE:-"${DATA_DIR}/data/uni_agent/swe_bench_verified_openyuanrong.parquet"}
TEST_FILE=${TEST_FILE:-"${DATA_DIR}/data/uni_agent/swe_bench_verified_openyuanrong.parquet"}

RUNTIME_ENV=${RUNTIME_ENV:-"${RUNTIME_DIR}/data/uni_agent/runtime_env.yaml"}
CKPTS_DIR=${CKPTS_DIR:-"${RUNTIME_DIR}/ckpts/${project_name}/${exp_name}"}
AGENT_LOG_DIR=${AGENT_LOG_DIR:-"${RUNTIME_DIR}/logs/${project_name}/${exp_name}"}
TASK_CONFIG=${TASK_CONFIG:-"examples/codex/task_config_codex.yaml"}
TOOL_PARSER=${TOOL_PARSER:-"qwen3_coder"}
CONCURRENCY=${CONCURRENCY:-1}
GATEWAY_COUNT=${GATEWAY_COUNT:-1}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-"$(basename "${MODEL_PATH}")"}
MASK_UNFINISHED_EPISODE=${MASK_UNFINISHED_EPISODE:-True}

rollout_mode=${ROLLOUT_MODE:-"async"}
rollout_name=${ROLLOUT_NAME:-"vllm"}
adv_estimator=${ADV_ESTIMATOR:-grpo}

use_dynamic_bsz=${USE_DYNAMIC_BSZ:-True}
offload=${OFFLOAD:-False}
gen_tp=${GEN_TP:-8}
train_tp=${TP:-8}
train_pp=${PP:-1}
train_cp=${CP:-1}
nnodes=${NNODES:-1}
ngpus_per_node=${NGPUS_PER_NODE:-8}

# 128K total trajectory: 8K prompt + 120K response. Override these in the
# same way as the release launcher when a different shape is required.
max_prompt_length=${MAX_PROMPT_LENGTH:-8192}
max_response_length=${MAX_RESPONSE_LENGTH:-122880}
train_prompt_bsz=${TRAIN_PROMPT_BSZ:-1}
n_resp_per_prompt=${N_RESP_PER_PROMPT:-1}
train_prompt_mini_bsz=${PPO_MINI_BATCH_SIZE:-1}

temperature=${TEMPERATURE:-0.6}
top_p=${TOP_P:-0.95}
top_k=${TOP_K:-20}
val_temperature=${VAL_TEMPERATURE:-1.0}
val_top_p=${VAL_TOP_P:-0.95}
val_top_k=${VAL_TOP_K:--1}
optimizer_offload_fraction=${OFFLOAD_FRACTION:-1.0}
lr_decay_steps=${LR_DECAY_STEPS:-10000}
test_freq=${TEST_FREQ:--1}

# Qwen3.5 text-only Codex defaults. Set VLLM_LANGUAGE_MODEL_ONLY=0 for
# image/video tasks. MAX_TOKENS_PER_TURN=0 preserves the full per-turn budget;
# the gateway still enforces the total prompt+response trajectory capacity.
VLLM_LANGUAGE_MODEL_ONLY=${VLLM_LANGUAGE_MODEL_ONLY:-1}
QWEN_ENABLE_THINKING=${QWEN_ENABLE_THINKING:-false}
VLLM_REASONING_PARSER=${VLLM_REASONING_PARSER:-qwen3}
VLLM_MAX_NUM_SEQS=${VLLM_MAX_NUM_SEQS:-1}
VLLM_MAX_NUM_BATCHED_TOKENS=${VLLM_MAX_NUM_BATCHED_TOKENS:-16384}
VLLM_ENFORCE_EAGER=${VLLM_ENFORCE_EAGER:-True}
VLLM_CUDAGRAPH_MODE=${VLLM_CUDAGRAPH_MODE:-NONE}
VLLM_USE_FLASHINFER_SAMPLER=${VLLM_USE_FLASHINFER_SAMPLER:-0}
ROLLOUT_GPU_MEM_UTIL=${ROLLOUT_GPU_MEM_UTIL:-0.68}
MAX_TOKENS_PER_TURN=${MAX_TOKENS_PER_TURN:-0}
ROLLOUT_TRACE=${ROLLOUT_TRACE:-False}
RAY_SUBMIT_MODE=${RAY_SUBMIT_MODE:-job}

export PROJECT_NAME="${project_name}"
export EXPERIMENT_NAME="${exp_name}"
export MODEL_PATH TRAIN_FILE TEST_FILE RUNTIME_ENV CKPTS_DIR AGENT_LOG_DIR TASK_CONFIG
# The recipe-facing names follow the release launcher; run_train.sh consumes
# the corresponding internal aliases.
export TRAIN_DATA="${TRAIN_FILE}" VAL_DATA="${TEST_FILE}"
export TOOL_PARSER CONCURRENCY GATEWAY_COUNT SERVED_MODEL_NAME MASK_UNFINISHED_EPISODE
export ROLLOUT_MODE="${rollout_mode}" ROLLOUT_NAME="${rollout_name}"
export NNODES="${nnodes}" N_GPUS_PER_NODE="${ngpus_per_node}"
export GEN_TP="${gen_tp}" TRAIN_TP="${train_tp}" TRAIN_PP="${train_pp}" TRAIN_CP="${train_cp}"
export TRAINER_MODE=colocate_async OFFLOAD="${offload}"
export PROMPT_LENGTH="${max_prompt_length}" RESPONSE_LENGTH="${max_response_length}"
export TRAIN_MAX_SAMPLES="${TRAIN_MAX_SAMPLES:-1}" VAL_MAX_SAMPLES="${VAL_MAX_SAMPLES:-0}"
export TRAIN_BATCH_SIZE="${TRAIN_BATCH_SIZE:-${train_prompt_bsz}}"
export VAL_BATCH_SIZE="${VAL_BATCH_SIZE:-1}"
export N="${n_resp_per_prompt}" PPO_MINI_BATCH_SIZE="${train_prompt_mini_bsz}"
export TEMPERATURE="${temperature}" TOP_P="${top_p}" TOP_K="${top_k}"
export VAL_TEMPERATURE="${val_temperature}" VAL_TOP_P="${val_top_p}" VAL_TOP_K="${val_top_k}"
export OFFLOAD_FRACTION="${optimizer_offload_fraction}" LR_DECAY_STEPS="${lr_decay_steps}"
export TEST_FREQ="${test_freq}" TOTAL_EPOCHS="${TOTAL_EPOCHS:-1}"
export TOTAL_TRAINING_STEPS="${TOTAL_TRAINING_STEPS:-1}" VAL_BEFORE_TRAIN="${VAL_BEFORE_TRAIN:-false}"
export VLLM_LANGUAGE_MODEL_ONLY QWEN_ENABLE_THINKING VLLM_REASONING_PARSER
export VLLM_MAX_NUM_SEQS VLLM_MAX_NUM_BATCHED_TOKENS VLLM_ENFORCE_EAGER VLLM_CUDAGRAPH_MODE
export VLLM_USE_FLASHINFER_SAMPLER ROLLOUT_GPU_MEM_UTIL MAX_TOKENS_PER_TURN ROLLOUT_TRACE RAY_SUBMIT_MODE

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "${REPO_ROOT}/examples/codex/run_train.sh" "$@"
