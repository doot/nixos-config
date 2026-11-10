"""Verify LCM opt-outs through its real environment parser, without model calls."""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("lcm_config_under_test", source / "config.py")
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load LCM configuration from {source}")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

FIELDS = (
    "embeddings_enabled",
    "rerank_enabled",
    "proactive_recall_enabled",
    "preanswer_evidence_enabled",
    "assertion_extraction_enabled",
    "selective_compiler_enabled",
    "extraction_enabled",
    "temporal_rollups_enabled",
)


class LCMConfigTests(unittest.TestCase):
    """Keep optional model processing disabled across dependency updates."""

    def test_explicit_opt_outs_are_honored(self) -> None:
        """Check configured false values and prove each variable is recognized."""
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home, "HERMES_HOME": home}
        ):
            for field in FIELDS:
                key = f"LCM_{field.upper()}"
                with self.subTest(variable=key):
                    self.assertEqual(os.environ.get(key), "false")
                    self.assertIs(getattr(module.LCMConfig.from_env(), field), False)
                    with patch.dict(os.environ, {key: "true"}):
                        self.assertIs(getattr(module.LCMConfig.from_env(), field), True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
