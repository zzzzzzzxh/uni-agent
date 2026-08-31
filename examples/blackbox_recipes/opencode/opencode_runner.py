"""OpenCode blackbox SWE-agent runner.

OpenCode runs inside an OpenYuanRong sandbox through a mounted sidecar binary.
The runner keeps the framework contract identical to the existing blackbox
recipes: create sandbox, invoke the CLI against the per-session Gateway,
evaluate reward in the same sandbox, post reward_info, and clean up.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import shlex
import time
from pathlib import Path
from typing import TYPE_CHECKING, Any

import httpx

from examples.blackbox_recipes.opencode.dataset import extract_image
from examples.blackbox_recipes.opencode.reward import build_reward_context, evaluate_in_env
from examples.blackbox_recipes.sandbox_client import SandboxClient, extract_upstream, rewrite_gateway_url

if TYPE_CHECKING:
    from uni_agent.gateway.session import SessionHandle

logger = logging.getLogger(__name__)
logger.setLevel(os.getenv("VERL_LOGGING_LEVEL", "INFO"))

DEFAULT_TOOL_IMAGE = "swr.cn-east-3.myhuaweicloud.com/openyuanrong/opencode-tool:latest"
TOOL_TARGET = "/opt/opencode"
DEFAULT_MODEL = "default"


class SandboxEnvForReward:
    """Adapt :class:`SandboxClient` to the reward environment protocol."""

    def __init__(self, sandbox):
        self._sandbox = sandbox

    async def communicate(self, input: str, timeout=600, check="ignore", error_msg="Command failed") -> str:
        result = await self._sandbox.run(input, timeout=int(timeout))
        if check == "raise" and result.exit_code != 0:
            raise RuntimeError(f"{error_msg}: {(result.stdout or '')[:200]}")
        return result.stdout

    async def write_file(self, path: str | Path, content: str) -> None:
        encoded = base64.b64encode(content.encode()).decode()
        await self.communicate(
            f"echo {encoded} | base64 -d > {shlex.quote(str(path))}", check="raise", error_msg=f"write {path}"
        )

    async def read_file(self, path: str | Path, **_) -> str:
        return await self.communicate(f"cat {shlex.quote(str(path))}")


def extract_task(raw_prompt: object) -> str:
    """Extract user task text from a string or OpenAI-style message list."""
    if isinstance(raw_prompt, str):
        return raw_prompt
    return next(
        (
            str(message["content"])
            for message in raw_prompt
            if isinstance(message, dict) and message.get("role") == "user"
        ),
        str(raw_prompt),
    )


def _extract_issue_text(task: str) -> str:
    start = task.find("<issue_description>")
    end = task.find("</issue_description>")
    if start >= 0 and end > start:
        return task[start + len("<issue_description>") : end].strip()
    marker = "\nFollow these steps to resolve the issue:"
    if marker in task:
        return task.split(marker, 1)[0].strip()
    return task.strip()


def _decode_metadata_list(value: object) -> list[str]:
    if not value:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return [value]
        if isinstance(parsed, list):
            return [str(item) for item in parsed]
    return [str(value)]


def build_opencode_task(raw_prompt: object, tools_kwargs: dict | None = None) -> str:
    """Build a bounded SWE task prompt for OpenCode."""
    tools_kwargs = tools_kwargs or {}
    task = extract_task(raw_prompt)
    metadata = (tools_kwargs.get("reward") or {}).get("metadata") or {}
    issue = metadata.get("problem_statement") or _extract_issue_text(task)
    tests = _decode_metadata_list(metadata.get("FAIL_TO_PASS"))
    if not tests:
        tests = _decode_metadata_list(metadata.get("PASS_TO_PASS"))[:3]
    tests_block = (
        "\n".join(f"- {test}" for test in tests) if tests else "- Run the closest relevant tests you identify."
    )
    return (
        "You are fixing a SWE-bench task in /testbed.\n\n"
        "Issue:\n"
        f"{issue}\n\n"
        "Rules:\n"
        "- Edit source files only. Do not modify tests.\n"
        "- The development environment is already installed; do not install packages unless a test command "
        "proves it is necessary.\n"
        "- Do not commit changes.\n"
        "- After the minimal fix and a relevant test pass, print a one-line summary and exit.\n\n"
        "Relevant tests to run after the fix:\n"
        f"{tests_block}\n"
    )


def build_opencode_config(
    *,
    base_url: str,
    model: str = DEFAULT_MODEL,
    max_steps: int | None = None,
) -> dict[str, Any]:
    """Return an isolated OpenCode OpenAI-compatible provider config."""
    return {
        "$schema": "https://opencode.ai/config.json",
        "model": f"uni-agent/{model}",
        "small_model": f"uni-agent/{model}",
        "provider": {
            "uni-agent": {
                "npm": "@ai-sdk/openai-compatible",
                "name": "Uni-Agent Gateway",
                "options": {"baseURL": base_url, "apiKey": "not-needed"},
                "models": {model: {"name": model}},
            }
        },
        "permission": {"*": "allow"},
        **({"agent": {"build": {"steps": max_steps}}} if max_steps is not None else {}),
    }


def build_opencode_command(
    *,
    task: str,
    config_path: str,
    model: str = DEFAULT_MODEL,
    conda_env: str | None = "testbed",
    binary_path: str = "/opt/opencode/bin/opencode",
) -> str:
    """Build a shell-safe non-interactive OpenCode invocation."""
    env = {
        "OPENCODE_CONFIG": config_path,
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "OPENCODE_DISABLE_MODELS_FETCH": "1",
        "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
        "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
        "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        "OPENCODE_DISABLE_PRUNE": "1",
        "OPENAI_API_KEY": "not-needed",
        "XDG_DATA_HOME": "/tmp/opencode-data",
        "XDG_CACHE_HOME": "/tmp/opencode-cache",
    }
    env_assignments = [f"{key}={shlex.quote(value)}" for key, value in env.items()]
    if conda_env:
        prefix = f"/opt/miniconda3/envs/{conda_env}"
        env_assignments.extend(
            [
                f"CONDA_DEFAULT_ENV={shlex.quote(conda_env)}",
                f"CONDA_PREFIX={shlex.quote(prefix)}",
                f"PATH={shlex.quote(prefix + '/bin')}:/opt/miniconda3/bin:$PATH",
            ]
        )
    argv = [
        binary_path,
        "run",
        "--auto",
        "--format",
        "json",
        "--model",
        f"uni-agent/{model}",
        "--dir",
        "/testbed",
        task,
    ]
    return (
        "unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; "
        "mkdir -p /tmp/opencode-data /tmp/opencode-cache; " + " ".join(env_assignments) + " " + shlex.join(argv)
    )


async def _create_opencode_sandbox(*, image: str, sidecar_image: str, gateway_url: str, max_retries: int = 10):
    upstream = extract_upstream(gateway_url) if gateway_url else ""
    return await SandboxClient.create(
        image=image,
        sidecar_image=sidecar_image,
        sidecar_target=TOOL_TARGET,
        upstream=upstream,
        max_retries=int(max_retries),
    )


async def opencode_runner(
    *,
    raw_prompt,
    session: SessionHandle,
    sample_index: int,
    tools_kwargs: dict | None = None,
    tool_image: str = DEFAULT_TOOL_IMAGE,
    run_timeout: int = 7200,
    conda_env: str = "testbed",
    model: str = DEFAULT_MODEL,
    binary_path: str = "/opt/opencode/bin/opencode",
    sandbox_max_retries: int = 10,
    **kwargs,
) -> None:
    """Run OpenCode, evaluate the patch, and publish the reward."""
    del kwargs
    tools_kwargs = tools_kwargs or {}
    task = build_opencode_task(raw_prompt, tools_kwargs)
    env_config = tools_kwargs.get("env", {})
    image = extract_image(env_config)
    if not image:
        raise ValueError(f"No Docker image found in tools_kwargs.env for sample {sample_index}")
    gateway_url = session.base_url
    if not gateway_url:
        raise ValueError(f"gateway_url is empty for sample {sample_index}")

    sandbox = await _create_opencode_sandbox(
        image=image, sidecar_image=tool_image, gateway_url=gateway_url, max_retries=sandbox_max_retries
    )
    try:
        post_setup_cmd = env_config.get("post_setup_cmd", "")
        if post_setup_cmd:
            setup_result = await sandbox.run(post_setup_cmd, timeout=120)
            if setup_result.exit_code != 0:
                logger.warning(
                    "post_setup_cmd failed rc=%s: %.300s",
                    setup_result.exit_code,
                    setup_result.stdout + setup_result.stderr,
                )

        config_path = f"/tmp/opencode-config-{session.session_id}.json"
        config = json.dumps(
            build_opencode_config(base_url=rewrite_gateway_url(gateway_url), model=model),
            separators=(",", ":"),
        )
        encoded_config = base64.b64encode(config.encode()).decode()
        await sandbox.run(f"echo {encoded_config} | base64 -d > {shlex.quote(config_path)}", timeout=30)
        command = build_opencode_command(
            task=task, config_path=config_path, model=model, conda_env=conda_env, binary_path=binary_path
        )
        started_at = time.perf_counter()
        result = await sandbox.run(command, timeout=int(run_timeout))
        logger.info(
            "[sample %d] opencode finished rc=%s elapsed=%.1fs",
            sample_index,
            result.exit_code,
            time.perf_counter() - started_at,
        )
        if result.exit_code != 0:
            logger.warning(
                "[sample %d] opencode failed stdout_tail=%r stderr_tail=%r",
                sample_index,
                (result.stdout or "")[-4000:],
                (result.stderr or "")[-4000:],
            )

        metadata, eval_timeout = build_reward_context(tools_kwargs)
        score, eval_result = await evaluate_in_env(SandboxEnvForReward(sandbox), metadata, eval_timeout)
        reward_info = {"reward_score": score, "opencode_exit_code": result.exit_code, **eval_result}
        if not session.reward_info_url:
            raise ValueError(f"reward_info_url is empty for session {session.session_id}")
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(session.reward_info_url, json={"reward_info": reward_info})
            response.raise_for_status()
    finally:
        await sandbox.cleanup()
