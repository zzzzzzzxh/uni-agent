from __future__ import annotations

from pathlib import Path

import yaml


ROOT = Path(__file__).parents[1]
CODEX_DIR = ROOT / "examples" / "codex"


def test_codex_task_config_uses_framework_agent_and_sandbox_mount():
    entries = yaml.safe_load((CODEX_DIR / "task_config_codex.yaml").read_text(encoding="utf-8"))
    assert {entry["name"] for entry in entries} == {"swe_rebench", "swe_bench"}
    for entry in entries:
        assert entry["sandbox"]["provider"] == "openyuanrong"
        assert entry["sandbox"]["sandbox_kwargs"]["proxy_port"] == 38197
        assert entry["agent"]["name"] == "codex"
        mount = entry["sandbox"]["sandbox_kwargs"]["mounts"][0]
        assert mount["target"] == "/opt/codex"
        assert mount["image_url"].endswith("codex-tool:0.147.0-direct-stdin")


def test_codex_training_recipe_uses_formal_framework_runner():
    run_train = (CODEX_DIR / "run_train.sh").read_text(encoding="utf-8")
    assert "uni_agent.framework.entry.AgentFrameworkRolloutAdapter" in run_train
    assert "uni_agent.framework.task_runner.run_task" in run_train
    assert "report_reward=True" in run_train
    assert "actor_rollout_ref.rollout.name=${ENGINE}" in run_train
    assert "language_model_only=True" in run_train
    assert "apply_chat_template_kwargs.enable_thinking=${QWEN_ENABLE_THINKING}" in run_train
    assert "reasoning_parser=${VLLM_REASONING_PARSER}" in run_train
    assert 'TEMPERATURE="${TEMPERATURE:-0.6}"' in run_train
    assert 'TOP_P="${TOP_P:-0.95}"' in run_train
    assert 'TOP_K="${TOP_K:-20}"' in run_train


def test_codex_sidecar_uses_native_responses_without_bridge():
    run_agent = (CODEX_DIR / "run_agent.sh").read_text(encoding="utf-8")
    assert 'wire_api = "responses"' in run_agent
    assert "responses_proxy" not in run_agent
    assert "--model \"${MODEL}\" -" not in run_agent


def test_single_node_smoke_does_not_start_vllm_directly():
    smoke = (CODEX_DIR / "run_single_node_framework_smoke.sh").read_text(encoding="utf-8")
    assert "vllm serve" not in smoke
    assert "VERL_CONFIG_NAME=\"ppo_megatron_trainer\"" in smoke
    assert "N_GPUS_PER_NODE:-8" in smoke
    assert "trajectory.json" in smoke
    assert "TRAJECTORY_LENGTH" in smoke
    assert "0.147.0-direct-stdin" in smoke
    assert "VLLM_LANGUAGE_MODEL_ONLY" in smoke
    assert "QWEN_ENABLE_THINKING" in smoke
    assert "VLLM_REASONING_PARSER" in smoke
