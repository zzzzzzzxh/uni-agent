#!/usr/bin/env bash
# Standard one-task Codex acceptance sample, following the release launcher shape.
#
# The only model launch is still owned by verl's rollout manager through
# run_train.sh. This wrapper fixes the project acceptance shape: one node, eight
# colocated GPUs, one SWE-Bench Verified task, and a 128K total trajectory.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKSPACE_HOME="${WORKSPACE_HOME:-/home/zxh}"

export REPO_ROOT
export WORKSPACE_HOME
export MODEL_PATH="${MODEL_PATH:-${WORKSPACE_HOME}/models/Qwen/Qwen3.5-9B}"
export SOURCE_DATA="${SOURCE_DATA:-${WORKSPACE_HOME}/sandbox/swe_bench_verified_openyuanrong.parquet}"
export ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/artifacts/codex-qwen3p5-single-node-128k}"
export SIDECAR_IMAGE="${SIDECAR_IMAGE:-swr.cn-east-3.myhuaweicloud.com/openyuanrong/codex-tool:0.147.0-direct-stdin}"

export TRAJECTORY_LENGTH="${TRAJECTORY_LENGTH:-131072}"
export PROMPT_LENGTH="${PROMPT_LENGTH:-8192}"
export N_GPUS_PER_NODE="${N_GPUS_PER_NODE:-8}"
export GEN_TP="${GEN_TP:-8}"
export TRAIN_TP="${TRAIN_TP:-8}"
export TRAIN_PP="${TRAIN_PP:-1}"
export TRAIN_CP="${TRAIN_CP:-1}"
export OFFLOAD="${OFFLOAD:-False}"
export ROLLOUT_GPU_MEM_UTIL="${ROLLOUT_GPU_MEM_UTIL:-0.68}"
export VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
export VLLM_MAX_NUM_BATCHED_TOKENS="${VLLM_MAX_NUM_BATCHED_TOKENS:-16384}"
export VLLM_ENFORCE_EAGER="${VLLM_ENFORCE_EAGER:-True}"
export VLLM_CUDAGRAPH_MODE="${VLLM_CUDAGRAPH_MODE:-NONE}"
export VLLM_LANGUAGE_MODEL_ONLY="${VLLM_LANGUAGE_MODEL_ONLY:-1}"
export QWEN_ENABLE_THINKING="${QWEN_ENABLE_THINKING:-false}"
export VLLM_REASONING_PARSER="${VLLM_REASONING_PARSER:-qwen3}"
export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
export MAX_TOKENS_PER_TURN="${MAX_TOKENS_PER_TURN:-0}"
export ROLLOUT_TRACE="${ROLLOUT_TRACE:-True}"
export ROLLOUT_TRACE_MAX_CHARS="${ROLLOUT_TRACE_MAX_CHARS:-2000}"
export ROLLOUT_TRACE_INTERVAL_SECONDS="${ROLLOUT_TRACE_INTERVAL_SECONDS:-30}"

# Keep this acceptance sample synchronous so the final trajectory verifier runs
# after the verl/Ray job has materialized the output.
export RAY_SUBMIT_MODE="local"
export TRAIN_MAX_SAMPLES=1
export VAL_MAX_SAMPLES=0
export N=1
export GATEWAY_COUNT=1
export MAX_CONCURRENT_SESSIONS=1
export NUM_AGENT_WORKERS=1
export SESSION_TIMEOUT_SECONDS="${SESSION_TIMEOUT_SECONDS:-7200}"
export TOTAL_TRAINING_STEPS=1
export VAL_BEFORE_TRAIN=false

exec bash "${SCRIPT_DIR}/run_single_node_framework_smoke.sh" "$@"
