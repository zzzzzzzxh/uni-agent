from __future__ import annotations

import json

from examples.blackbox_recipes.opencode.opencode_runner import (
    build_opencode_command,
    build_opencode_config,
    build_opencode_task,
    extract_task,
)


def test_extract_task_from_messages():
    assert extract_task([{"role": "system", "content": "ignored"}, {"role": "user", "content": "fix bug"}]) == "fix bug"


def test_build_opencode_task_prefers_reward_metadata():
    task = build_opencode_task(
        "fallback",
        {"reward": {"metadata": {"problem_statement": "metadata issue", "FAIL_TO_PASS": ["tests/test_fix.py"]}}},
    )
    assert "metadata issue" in task
    assert "tests/test_fix.py" in task
    assert "Do not commit changes" in task


def test_build_opencode_config_is_gateway_scoped():
    config = build_opencode_config(base_url="http://127.0.0.1:38197/sessions/s1/v1", model="default")
    assert config["model"] == "uni-agent/default"
    provider = config["provider"]["uni-agent"]
    assert provider["npm"] == "@ai-sdk/openai-compatible"
    assert provider["options"]["baseURL"].endswith("/v1")
    json.dumps(config)


def test_build_opencode_command_is_noninteractive_and_shell_safe():
    command = build_opencode_command(
        task="fix 'quoted' bug",
        config_path="/tmp/opencode config.json",
        model="default",
    )
    assert "opencode run" in command
    assert "--auto" in command
    assert "--format json" in command
    assert "--dir /testbed" in command
    assert "OPENCODE_CONFIG='/tmp/opencode config.json'" in command
    assert "fix 'quoted' bug" not in command


def test_build_opencode_command_supports_custom_binary_and_conda():
    command = build_opencode_command(
        task="fix bug",
        config_path="/tmp/config.json",
        binary_path="/opt/custom/opencode",
        conda_env=None,
    )
    assert "/opt/custom/opencode run" in command
    assert "CONDA_DEFAULT_ENV" not in command
