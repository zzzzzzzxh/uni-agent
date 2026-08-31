# OpenCode 黑盒接入第一版

本 recipe 复用当前 `AgentFramework` 的 runner contract，不新增 Sandbox provider，也不在每个 sandbox 内安装 npm 包。
OpenCode 作为 sidecar 二进制挂载到 `/opt/opencode`，通过当前 session 的 Gateway tunnel 调用模型；reward 在同一个 SWE-bench sandbox 中执行，随后回传 `reward_info` 并清理 sandbox。

## 文件结构

- `opencode_runner.py`：创建 sandbox、写入隔离的 `opencode.json`、运行 `opencode run`、评测 reward、清理资源。
- `Dockerfile.opencode-tool` / `build_tool.sh`：构建固定版本的 Linux x64 OpenCode sidecar。
- `config/opencode_megatron_v1.yaml`：复用现有 V1 blackbox 训练配置，只替换 runner 和 sidecar image。
- `run_train.sh`：训练入口，支持通过环境变量覆盖 runner 参数。

## 构建 sidecar

当前默认版本固定为 `1.18.25`；正式训练建议显式指定经过验证的版本和镜像 tag：

```bash
bash examples/blackbox_recipes/opencode/build_tool.sh \
  --version 1.18.25 \
  --target linux-x64 \
  --registry swr.cn-east-3.myhuaweicloud.com/openyuanrong
```

如使用内部制品地址，可传 `--url`；不要在 500 个 sandbox 中运行时安装 OpenCode。

## 运行训练

```bash
AKERNEL_SERVER_ADDRESS="<address>" \
AKERNEL_TOKEN="<token>" \
OPENCODE_TOOL_IMAGE="swr.cn-east-3.myhuaweicloud.com/openyuanrong/opencode-tool:latest" \
MODEL_PATH="<model-path>" \
bash examples/blackbox_recipes/opencode/run_train.sh
```

runner 默认使用：

- `OPENCODE_CONFIG`：每个 session 独立的 `/tmp/opencode-config-<session>.json`。
- `OPENAI_BASE_URL`：当前 Gateway tunnel 的 OpenAI-compatible 地址。
- `OPENCODE_DISABLE_AUTOUPDATE=1`、`OPENCODE_DISABLE_MODELS_FETCH=1`、`OPENCODE_DISABLE_DEFAULT_PLUGINS=1` 等隔离开关。
- `XDG_DATA_HOME` / `XDG_CACHE_HOME`：每个 sandbox 内独立的 OpenCode 状态目录。
- `opencode run --auto --format json --model uni-agent/default --dir /testbed`：非交互执行。

第一版只支持 OpenYuanRong sandbox 和 Linux x64 sidecar。完成训练前，应在 `remote186` 上运行仓库要求的 `test_sandbox.py`，再进行单样本 Gateway/OpenCode smoke test；当前本地工作区未包含服务 token，不会把 token 写入仓库。
