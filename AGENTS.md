# Remote Sandbox Validation

## Required test environment

- Validate sandbox-related changes on `remote186`; do not treat local-only execution as final validation.
- Use `/home/zxh` as the remote working directory.
- Create and use a dedicated Conda environment named `uni-agent` with Python 3.11.
- Install `akernel_sdk` from the OpenYuanRong release wheel for validation.
- Install `openyuanrong_sdk` only from a wheel compatible with both the remote CPU architecture and the Conda environment's CPython ABI. Do not install the provided `cp312` wheel into Python 3.11.

## Credential handling

- Never commit or write service tokens into repository files, documentation, shell history, or command output.
- Supply AKernel/OpenYuanRong credentials through a remote, permission-restricted environment file or the remote session environment.

## Required validation

- The final sandbox validation is `test_sandbox.py` on `remote186`.
- Confirm sandbox creation, command execution, `swe-rex` installation, server health on port 8000, external port-forwarding health, and sandbox cleanup.
- For a service endpoint on port 443, inspect the installed `akernel_sdk` tunnel URL construction. If it uses `ws://` for the tunnel WebSocket, change it to `wss://` in the remote test environment before retesting, and record the exact installed file/version in the validation report.

## Sandbox startup experiment workflow

- For sandbox startup or Ray admission work, follow docs/sandbox_startup_experiments.md before changing production code.
- Write one falsifiable problem statement, run the smallest discriminating baseline, vary one control at a time, and record both the decision metric and the cost metric before choosing an implementation.
- Keep long reference material in the linked document; keep this file limited to durable repository rules and pointers.
## Documentation language

- Write task summaries, experiment conclusions, handoff notes, and other repository-authored summary documents in Chinese. Keep source code, commands, identifiers, paths, and third-party quoted material in their original language unless translation is explicitly needed.


## Generated content and naming

- Repository-authored generated files, task summaries, experiment records, handoff notes, commit messages, branch names, image tags, and other derived artifacts must not contain internal tool branding, chat-product branding, or assistant/workflow markers.
- Use neutral, project-specific names that describe the actual implementation or experiment; do not derive names from the execution environment.
- Before committing or publishing generated content, scan the changed files, commit subject, and branch name for prohibited branding or internal markers.
