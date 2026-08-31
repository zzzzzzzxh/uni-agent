"""SWE-bench dataset helpers for the OpenCode recipe."""

try:
    from verl.utils.dataset.rl_dataset import RLHFDataset
except ModuleNotFoundError:  # Allows lightweight runner/unit-test imports without verl installed.
    RLHFDataset = None


def extract_image(env_config: dict) -> str:
    """Extract Docker image from flat or nested environment config."""
    image = env_config.get("image")
    if image:
        return image
    deployment = env_config.get("deployment")
    if isinstance(deployment, dict):
        return str(deployment.get("image") or "")
    return ""


if RLHFDataset is not None:

    class SWEBenchDataset(RLHFDataset):
        def __getitem__(self, item):
            row_dict = super().__getitem__(item)
            extra_info = row_dict.get("extra_info", {})
            tools_kwargs = extra_info.get("tools_kwargs", {})
            reward_config = tools_kwargs.get("reward", {})
            row_dict.setdefault("data_source", reward_config.get("name", "unknown"))
            row_dict.setdefault("reward_model", {"ground_truth": {}})
            return row_dict

else:

    class SWEBenchDataset:  # pragma: no cover - only an import-time fallback.
        """Placeholder that gives a useful error if dataset loading is attempted."""

        def __init__(self, *args, **kwargs):
            raise ModuleNotFoundError("verl is required to instantiate SWEBenchDataset")
