"""Verify the configured block policy without executing file-writing tools."""

import importlib.util
import sys
import unittest
from pathlib import Path


plugin_path = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location(
    "security_guidance_under_test",
    plugin_path / "__init__.py",
    submodule_search_locations=[str(plugin_path)],
)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load Security Guidance from {plugin_path}")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)


class SecurityGuidanceTests(unittest.TestCase):
    """Check the enabled policy using inert tool arguments."""

    def test_benign_source_is_allowed(self) -> None:
        """Permit ordinary source writes and replacements."""
        for tool, field in [("write_file", "content"), ("patch", "new_string")]:
            with self.subTest(tool=tool):
                result = plugin._on_pre_tool_call(
                    tool_name=tool, args={"path": "example.py", field: "value = 1\n"}
                )
                self.assertIsNone(result)

    def test_unsafe_deserialization_is_blocked(self) -> None:
        """Refuse the unsafe-deserialization fixture before a write."""
        for tool, field in [("write_file", "content"), ("patch", "new_string")]:
            with self.subTest(tool=tool):
                result = plugin._on_pre_tool_call(
                    tool_name=tool,
                    args={"path": "example.py", field: "value = pickle.load(handle)\n"},
                )
                self.assertIsNotNone(result)
                self.assertEqual(result["action"], "block")

    def test_benign_workflow_requires_human_edit(self) -> None:
        """Refuse workflow YAML by path even when its content is benign."""
        for suffix in ["yml", "yaml"]:
            for tool, field in [("write_file", "content"), ("patch", "new_string")]:
                with self.subTest(suffix=suffix, tool=tool):
                    result = plugin._on_pre_tool_call(
                        tool_name=tool,
                        args={
                            "path": f".github/workflows/check.{suffix}",
                            field: "name: Check\non: push\njobs: {}\n",
                        },
                    )
                    self.assertIsNotNone(result)
                    self.assertEqual(result["action"], "block")
                    self.assertIn("github_actions_workflow", result["message"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
