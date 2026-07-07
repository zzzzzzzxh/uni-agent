import importlib.util
import logging
import sys
import types
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[3]


def _install_package_stub(name: str, relative_path: str):
    module = sys.modules.get(name)
    if module is None:
        module = types.ModuleType(name)
        sys.modules[name] = module
    module.__path__ = [str(REPO_ROOT / relative_path)]
    return module


def _load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


_install_package_stub("uni_agent", "uni_agent")
_install_package_stub("uni_agent.interaction", "uni_agent/interaction")
tool_schemas = _load_module("uni_agent.interaction.tool_schemas", "uni_agent/interaction/tool_schemas.py")
tool_parser = _load_module("uni_agent.interaction.tool_parser", "uni_agent/interaction/tool_parser.py")

FunctionCallFormatError = tool_parser.FunctionCallFormatError
XMLToolParser = tool_parser.XMLToolParser
OpenAIFunctionParametersSchema = tool_schemas.OpenAIFunctionParametersSchema
OpenAIFunctionPropertySchema = tool_schemas.OpenAIFunctionPropertySchema
OpenAIFunctionSchema = tool_schemas.OpenAIFunctionSchema
OpenAIFunctionToolSchema = tool_schemas.OpenAIFunctionToolSchema


def _run_shell_tool() -> OpenAIFunctionToolSchema:
    return OpenAIFunctionToolSchema(
        type="function",
        function=OpenAIFunctionSchema(
            name="run_shell",
            description="Run a shell command.",
            parameters=OpenAIFunctionParametersSchema(
                type="object",
                properties={
                    "cmd": OpenAIFunctionPropertySchema(type="string", description="Command to run."),
                },
                required=["cmd"],
            ),
        ),
    )


def test_xml_tool_parser_logs_malformed_model_output(caplog):
    model_output = "thinking...\n<tool_call>\n<function=run_shell>\n<parameter=cmd</tool_call>"

    parser = XMLToolParser()
    with caplog.at_level(logging.ERROR, logger="uni_agent.interaction.tool_parser"):
        with pytest.raises(FunctionCallFormatError):
            parser.extract_tool_calls(model_output, [_run_shell_tool()])

    log_text = caplog.text
    assert "Failed to parse XML tool call from model output" in log_text
    assert "Malformed function call" in log_text
    assert "<function=run_shell>" in log_text
    assert "<parameter=cmd</tool_call>" in log_text
    assert "Full model output preview" in log_text
    assert "thinking..." in log_text
