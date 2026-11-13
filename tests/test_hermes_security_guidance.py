"""Exercise Security Guidance hooks with inert file-tool arguments."""

import importlib.util
import os
import sys
import unittest
from itertools import permutations
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tools.file_operations_common import ReadResult, WriteResult
from tools.patch_parser import OperationType, apply_v4a_operations, parse_v4a_patch


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

SCAN_LIMIT = 256 * 1024


def _content_calls(path: str, content: str) -> list[tuple[str, dict[str, object]]]:
    """Supply complete write and replacement arguments, including default mode."""
    replacement = {"path": path, "old_string": "previous\n", "new_string": content}
    return [
        ("write_file", {"path": path, "content": content}),
        ("patch", replacement),
        ("patch", {"mode": "replace", **replacement}),
    ]


class SecurityGuidanceTests(unittest.TestCase):
    """Check hooks with inert arguments and in-memory native patch application."""

    def setUp(self) -> None:
        """Require the deployed block policy before exercising mode overrides."""
        self.assertEqual(os.environ.get("SECURITY_GUIDANCE_BLOCK"), "1")
        self.assertEqual(os.environ.get("SECURITY_GUIDANCE_DISABLE"), "0")

    def _assert_blocked(self, tool: str, args: dict[str, object], rule: str) -> None:
        result = plugin._on_pre_tool_call(tool_name=tool, args=args)
        self.assertIsNotNone(result)
        self.assertEqual(result["action"], "block")
        self.assertIn(rule, result["message"])

    def _v4a_args(self, body: str) -> dict[str, object]:
        text = f"*** Begin Patch\n{body}*** End Patch\n"
        operations, error = parse_v4a_patch(text)
        self.assertIsNone(error)
        self.assertTrue(operations)
        return {"mode": "patch", "patch": text}

    def test_benign_source_is_allowed(self) -> None:
        """Permit ordinary source writes and replacements, including empty text."""
        for content in ("value = 1\n", ""):
            for tool, args in _content_calls("example.py", content):
                with self.subTest(tool=tool, mode=args.get("mode"), empty=not content):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))

    def test_unsafe_deserialization_is_blocked(self) -> None:
        """Refuse unsafe deserialization in supplied Python content."""
        for tool, args in _content_calls("example.py", "value = pickle.load(handle)\n"):
            with self.subTest(tool=tool, mode=args.get("mode")):
                self._assert_blocked(tool, args, "pickle_deserialization")

    def test_workflow_path_rule_blocks_benign_yaml(self) -> None:
        """Match both workflow suffixes without requiring dangerous YAML."""
        for suffix in ("yml", "yaml"):
            for tool, args in _content_calls(f".github/workflows/check.{suffix}", "name: Check\non: push\njobs: {}\n"):
                with self.subTest(suffix=suffix, tool=tool, mode=args.get("mode")):
                    self._assert_blocked(tool, args, "github_actions_workflow")

    def test_workflow_spelling_aliases_are_blocked(self) -> None:
        """Classify harmless POSIX spellings without resolving or changing tool arguments."""
        for suffix in ("yml", "yaml"):
            for spelling in (".github/./workflows", ".github//workflows"):
                path = f"{spelling}/check.{suffix}"
                bodies = [
                    f"*** Add File: {path}\n+name: Check\n",
                    f"*** Update File: {path}\n@@\n-old\n+name: Check\n",
                    f"*** Delete File: {path}\n",
                    f"*** Move File: ordinary.{suffix} -> {path}\n",
                    f"*** Move File: {path} -> ordinary.{suffix}\n",
                ]
                calls = _content_calls(path, "name: Check\n") + [("patch", self._v4a_args(body)) for body in bodies]
                for index, (tool, args) in enumerate(calls):
                    with self.subTest(path=path, call=index):
                        original = args.copy()
                        with patch("builtins.open", side_effect=AssertionError("No target reads")), \
                             patch("io.open", side_effect=AssertionError("No target reads")), \
                             patch("os.open", side_effect=AssertionError("No target reads")), \
                             patch.object(Path, "resolve", side_effect=AssertionError("No host resolution")), \
                             patch("os.getcwd", side_effect=AssertionError("No global cwd")):
                            self._assert_blocked(tool, args, "github_actions_workflow")
                        self.assertEqual(args, original)

    def test_path_normalization_preserves_nonaliases(self) -> None:
        """Keep parent components, POSIX backslashes, and directory-only suffixes distinct."""
        paths = (
            ".github/other/../workflows/check.yml",
            r".github\workflows\check.yml",
            ".github/workflows/check.yml/",
            ".github/workflows/check.yml/.",
            ".github/./workflows/check.yml//./",
        )
        for path in paths:
            for tool, args in _content_calls(path, "") + [("patch", self._v4a_args(f"*** Delete File: {path}\n"))]:
                with self.subTest(path=path, tool=tool, mode=args.get("mode")):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))

    def test_empty_workflow_edits_are_blocked(self) -> None:
        """Apply path-only rules to empty writes and replacement deletions."""
        for suffix in ("yml", "yaml"):
            for tool, args in _content_calls(f".github/workflows/check.{suffix}", ""):
                with self.subTest(suffix=suffix, tool=tool, mode=args.get("mode")):
                    self._assert_blocked(tool, args, "github_actions_workflow")

    def test_workflow_paths_are_scanned_above_content_limit(self) -> None:
        """Keep path-only rules active at and beyond the content byte limit."""
        for suffix in ("yml", "yaml"):
            for size in (SCAN_LIMIT - 1, SCAN_LIMIT, SCAN_LIMIT + 1):
                for tool, args in _content_calls(f".github/workflows/check.{suffix}", "x" * size):
                    with self.subTest(suffix=suffix, size=size, tool=tool, mode=args.get("mode")):
                        self._assert_blocked(tool, args, "github_actions_workflow")

    def test_content_scan_limit_is_preserved(self) -> None:
        """Skip oversized content while scanning text through the exact byte cap."""
        unsafe = "pickle.load(handle)\n"
        for filler in ("x", "é"):
            for size in (SCAN_LIMIT - 1, SCAN_LIMIT, SCAN_LIMIT + 1):
                count, remainder = divmod(size - len(unsafe), len(filler.encode("utf-8")))
                content = unsafe + filler * count + "x" * remainder
                self.assertEqual(len(content.encode("utf-8")), size)
                for tool, args in _content_calls("example.py", content):
                    with self.subTest(size=size, filler=filler, tool=tool, mode=args.get("mode")):
                        if size <= SCAN_LIMIT:
                            self._assert_blocked(tool, args, "pickle_deserialization")
                        else:
                            self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))

    def test_v4a_workflow_operations_are_blocked(self) -> None:
        """Check every operation's workflow path, including both move endpoints."""
        for suffix in ("yml", "yaml"):
            path = f".github/workflows/check.{suffix}"
            operations = {
                "add": f"*** Add File: {path}\n+name: Check\n",
                "empty add": f"*** Add File: {path}\n",
                "update": f"*** Update File: {path}\n@@\n-name: Old\n+name: Check\n",
                "deletion-only update": f"*** Update File: {path}\n@@\n-name: Old\n",
                "delete": f"*** Delete File: {path}\n",
                "move in": f"*** Move File: ordinary.{suffix} -> {path}\n",
                "move out": f"*** Move File: {path} -> ordinary.{suffix}\n",
            }
            for name, body in operations.items():
                with self.subTest(suffix=suffix, operation=name):
                    self._assert_blocked("patch", self._v4a_args(body), "github_actions_workflow")

    def test_v4a_content_rules_use_operation_paths(self) -> None:
        """Scan added text and retained update context under each target's suffix."""
        cases = [
            ("example.py", "pickle.load(handle)", "pickle_deserialization"),
            ("example.js", "child_process.exec(command)", "child_process_exec"),
            ("notes.txt", "new Function(body)", "new_function_injection"),
            ("notes.txt", "verify=False", "tls_verification_disabled"),
        ]
        for path, content, rule in cases:
            operations = {
                "add": f"*** Add File: {path}\n+{content}\n",
                "update addition": f"*** Update File: {path}\n@@\n-previous\n+{content}\n",
                "update context": f"*** Update File: {path}\n@@\n {content}\n-previous\n+replacement\n",
                "implicit update context": f"*** Update File: {path}\n@@\n{content}\n-previous\n+replacement\n",
            }
            for name, body in operations.items():
                with self.subTest(path=path, rule=rule, operation=name):
                    self._assert_blocked("patch", self._v4a_args(body), rule)

    def test_update_hunks_do_not_invent_missing_integrity(self) -> None:
        """Keep an unchanged integrity attribute between distinct UPDATE hunks."""
        remote = "https" + "://" + "example.invalid/library.js"
        opening = f'<script src="{remote}"'
        before = (
            f'{opening}\n data-version="old"\n integrity="sha384-fixture"\n'
            ' crossorigin="anonymous"\n>\nold\n</script>'
        )
        expected = before.replace('data-version="old"', 'data-version="new"').replace("\nold\n", "\nnew\n")
        args = self._v4a_args(
            f'*** Update File: page.html\n@@\n {opening}\n- data-version="old"\n+ data-version="new"\n'
            '@@\n >\n-old\n+new\n'
        )
        operations, error = parse_v4a_patch(args["patch"])
        self.assertIsNone(error)
        self.assertEqual(len(operations), 1)
        self.assertIs(operations[0].operation, OperationType.UPDATE)
        self.assertEqual(len(operations[0].hunks), 2)
        reads = Mock(return_value=ReadResult(content=before))
        writes = Mock(return_value=WriteResult(bytes_written=len(expected.encode()), verified=True))
        files = SimpleNamespace(env=SimpleNamespace(cwd="/synthetic-worktree", is_local=False), read_file_raw=reads, write_file=writes)
        with patch("tools.patch_parser._backend_is_windows", return_value=False):
            result = apply_v4a_operations(operations, files)
        self.assertTrue(result.success, result.error)
        self.assertEqual(reads.call_count, 2)
        self.assertTrue(all(call.args == ("page.html",) and not call.kwargs for call in reads.call_args_list))
        writes.assert_called_once_with("page.html", expected, pre_content=before)
        self.assertIsNone(plugin._on_pre_tool_call(tool_name="write_file", args={"path": "page.html", "content": expected}))
        self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))

    def test_add_hunks_form_contiguous_content(self) -> None:
        """Scan the complete ADD result even when a tag spans its hunk markers."""
        remote = "https" + "://" + "example.invalid/library.js"
        opening = f'<script src="{remote}"'
        expected = f"{opening}\n></script>"
        args = self._v4a_args(f"*** Add File: page.html\n+{opening}\n@@\n+></script>\n")
        operations, error = parse_v4a_patch(args["patch"])
        self.assertIsNone(error)
        self.assertEqual(len(operations), 1)
        self.assertIs(operations[0].operation, OperationType.ADD)
        self.assertEqual(len(operations[0].hunks), 2)
        reads = Mock(return_value=ReadResult(error="synthetic file absent", not_found=True))
        writes = Mock(return_value=WriteResult(bytes_written=len(expected.encode()), verified=True))
        files = SimpleNamespace(env=SimpleNamespace(cwd="/synthetic-worktree", is_local=False), read_file_raw=reads, write_file=writes)
        with patch("tools.patch_parser._backend_is_windows", return_value=False):
            result = apply_v4a_operations(operations, files)
        self.assertTrue(result.success, result.error)
        self.assertEqual(reads.call_count, 2)
        self.assertTrue(all(call.args == ("page.html",) and not call.kwargs for call in reads.call_args_list))
        writes.assert_called_once_with("page.html", expected)
        self._assert_blocked("patch", args, "script_src_without_sri")

    def test_update_hunks_share_the_operation_content_budget(self) -> None:
        """Count UTF-8 bytes and selected blank lines across all UPDATE hunks."""
        unsafe = "pickle.load(handle)"
        for extra, blank_lines in (("", 0), ("@@\n-previous\n", 0), ("@@\n+\n", 1)):
            for size in (SCAN_LIMIT - 1, SCAN_LIMIT, SCAN_LIMIT + 1):
                count, remainder = divmod(size - len(unsafe) - 1 - blank_lines, len("é".encode()))
                filler = "é" * count + "x" * remainder
                args = self._v4a_args(f"*** Update File: example.py\n{extra}@@\n+{unsafe}\n@@\n+{filler}\n")
                operations, error = parse_v4a_patch(args["patch"])
                self.assertIsNone(error)
                selected = [line.content for hunk in operations[0].hunks for line in hunk.lines if line.prefix in ("+", " ")]
                self.assertEqual(len("\n".join(selected).encode()), size)
                with self.subTest(extra=extra, size=size):
                    if size <= SCAN_LIMIT:
                        self._assert_blocked("patch", args, "pickle_deserialization")
                    else:
                        self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))

    def test_update_hunk_findings_are_deduplicated(self) -> None:
        """Find content in either hunk and report a repeated rule once per operation."""
        unsafe = "pickle.load(handle)"
        for fragments in ((unsafe, "value = 1"), ("value = 1", unsafe), (unsafe, unsafe)):
            args = self._v4a_args("*** Update File: example.py\n" + "".join(f"@@\n+{fragment}\n" for fragment in fragments))
            with self.subTest(fragments=fragments):
                result = plugin._on_pre_tool_call(tool_name="patch", args=args)
                self.assertIsNotNone(result)
                self.assertEqual(result["action"], "block")
                self.assertIn("1 pattern matched (pickle_deserialization)", result["message"])
                with patch.dict(os.environ, {"SECURITY_GUIDANCE_BLOCK": "0"}):
                    warning = plugin._on_transform_tool_result(tool_name="patch", args=args, result='{"success": true}')
                    self.assertIsNotNone(warning)
                    self.assertIn("1 pattern matched (pickle_deserialization)", warning)

    def test_removed_dangerous_lines_are_allowed(self) -> None:
        """Do not treat removed Python, JavaScript, or unfiltered patterns as writes."""
        for path, content in [
            ("example.py", "pickle.load(handle)"),
            ("example.js", "child_process.exec(command)"),
            ("notes.txt", "new Function(body)"),
            ("notes.txt", "verify=False"),
        ]:
            for replacement in ("", "replacement\n"):
                calls = [
                    ("patch", {"mode": "replace", "path": path, "old_string": content, "new_string": replacement}),
                    ("patch", self._v4a_args(f"*** Update File: {path}\n@@\n-{content}\n" + (f"+{replacement}" if replacement else ""))),
                ]
                for tool, args in calls:
                    with self.subTest(path=path, content=content, empty=not replacement, mode=args["mode"]):
                        self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))

    def test_missing_or_invalid_write_fields_are_ignored(self) -> None:
        """Do not invent writes from absent paths, content, or replacement operands."""
        for tool, valid in _content_calls(".github/workflows/check.yml", "new Function(body)"):
            for args in (None, [], "", {}):
                with self.subTest(tool=tool, args=args):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))
            required = ("path", "content") if tool == "write_file" else ("path", "old_string", "new_string")
            for field in required:
                missing = {key: value for key, value in valid.items() if key != field}
                with self.subTest(tool=tool, mode=valid.get("mode"), field=field, missing=True):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=missing))
                values = (None, 42, [], {}) + (("",) if field == "path" else ())
                for value in values:
                    with self.subTest(tool=tool, mode=valid.get("mode"), field=field, value=value):
                        self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args={**valid, field: value}))

    def test_patch_mode_uses_only_active_fields(self) -> None:
        """Ignore inactive payloads and reject unknown modes without fake edits."""
        replacement = {"path": "example.py", "old_string": "previous", "new_string": "replacement", "patch": "new Function(body)"}
        calls = [replacement, {"mode": "replace", **replacement}]
        for mode in (None, "", "unknown", 42, []):
            calls.append({"mode": mode, "path": ".github/workflows/check.yml", "old_string": "old", "new_string": ""})
        calls.append({**self._v4a_args("*** Add File: notes.txt\n+safe\n"), "path": ".github/workflows/check.yml", "new_string": "new Function(body)"})
        for index, args in enumerate(calls):
            with self.subTest(case=index, mode=args.get("mode")):
                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))

    def test_empty_or_invalid_v4a_payloads_are_ignored(self) -> None:
        """Let the tool diagnose empty or invalid patches without phantom findings."""
        payloads = [
            None, 42, [], {}, "", "*** Begin Patch\n*** End Patch\n", "new Function(body)",
            "*** Update File: .github/workflows/check.yml\n",
            "*** Move File: .github/workflows/check.yml ->  \n",
            "*** Delete File: .github/workflows/check.yml\n*** Update File: example.py\n",
            "*** Add File:  \n+new Function(body)\n",
        ]
        for payload in payloads:
            with self.subTest(payload=payload):
                if isinstance(payload, str):
                    self.assertFalse(parse_v4a_patch(payload)[0])
                args = {"mode": "patch", "patch": payload, "path": ".github/workflows/check.yml", "new_string": "new Function(body)"}
                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))
        self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args={"mode": "patch", "path": ".github/workflows/check.yml"}))

    def test_v4a_path_scans_ignore_payload_size_and_order(self) -> None:
        """Find workflow paths before, between, and after other files in large patches."""
        oversized = "x" * (SCAN_LIMIT + 1)
        neighbors = [f"*** Add File: large.txt\n+{oversized}\n", "*** Add File: small.txt\n+safe\n"]
        for suffix in ("yml", "yaml"):
            path = f".github/workflows/check.{suffix}"
            operations = {
                "add": f"*** Add File: {path}\n+{oversized}\n",
                "update": f"*** Update File: {path}\n@@\n-old\n+{oversized}\n",
                "delete": f"*** Delete File: {path}\n",
                "move in": f"*** Move File: ordinary.{suffix} -> {path}\n",
                "move out": f"*** Move File: {path} -> ordinary.{suffix}\n",
            }
            for name, body in operations.items():
                for position in range(len(neighbors) + 1):
                    with self.subTest(suffix=suffix, operation=name, position=position):
                        pieces = neighbors.copy()
                        pieces.insert(position, body)
                        self._assert_blocked("patch", self._v4a_args("".join(pieces)), "github_actions_workflow")

    def test_v4a_content_limit_is_per_operation(self) -> None:
        """Apply the byte cap to retained content, not headers or neighboring files."""
        neighbor = "*** Add File: large.txt\n+" + "x" * (SCAN_LIMIT + 1) + "\n"
        for path, unsafe, rule in [
            ("example.py", "pickle.load(handle)", "pickle_deserialization"),
            ("notes.txt", "new Function(body)", "new_function_injection"),
        ]:
            for size in (SCAN_LIMIT - 1, SCAN_LIMIT, SCAN_LIMIT + 1):
                count, remainder = divmod(size - len(unsafe), len("é".encode("utf-8")))
                content = unsafe + "é" * count + "x" * remainder
                self.assertEqual(len(content.encode("utf-8")), size)
                for header in (f"*** Add File: {path}\n", f"*** Update File: {path}\n@@\n-old\n"):
                    operation = f"{header}+{content}\n"
                    for first in (True, False):
                        with self.subTest(path=path, size=size, header=header, first=first):
                            args = self._v4a_args(operation + neighbor if first else neighbor + operation)
                            if size <= SCAN_LIMIT:
                                self._assert_blocked("patch", args, rule)
                            else:
                                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))

    def test_v4a_extension_filters_do_not_mix_files(self) -> None:
        """Keep documentation examples separate from unrelated Python and JS edits."""
        operations = {
            "docs": "*** Add File: example.md\n+pickle.load(handle)\n+child_process.exec(command)\n+eval(value)\n",
            "python": "*** Add File: example.py\n+exec(command)\n",
            "javascript": "*** Add File: example.js\n+pickle.load(handle)\n",
        }
        for order in permutations(operations):
            with self.subTest(order=order):
                args = self._v4a_args("".join(operations[name] for name in order))
                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))

    def test_v4a_marker_variants_are_scanned(self) -> None:
        """Honor the parser's CRLF, marker whitespace, and wrapperless forms."""
        for suffix in ("yml", "yaml"):
            path = f".github/workflows/check.{suffix}"
            variants = [
                f"*** Begin Patch\r\n*** Delete File: {path}\r\n*** End Patch\r\n",
                f"***Begin\tPatch  \r\n***  Move\tFile:\tordinary.yml -> {path}  \r\n***End  Patch\t\r\n",
                f"*** Update File: {path}\n@@\n-name: Old\n+name: Check\n",
            ]
            for text in variants:
                with self.subTest(suffix=suffix, text=text):
                    operations, error = parse_v4a_patch(text)
                    self.assertIsNone(error)
                    self.assertEqual(len(operations), 1)
                    self._assert_blocked("patch", {"mode": "patch", "patch": text}, "github_actions_workflow")

    def test_v4a_header_like_added_text_is_not_a_marker(self) -> None:
        """Treat added marker examples as content without hiding subsequent files."""
        body = (
            "*** Add File: format.md\n+*** Begin Patch\n+*** Delete File: .github/workflows/check.yml\n"
            "+*** Move File: ordinary.yaml -> .github/workflows/check.yaml\n+*** End Patch\n"
        )
        self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=self._v4a_args(body)))
        for following, rule in [
            ("*** Delete File: .github/workflows/check.yaml\n", "github_actions_workflow"),
            ("*** Add File: example.py\n+pickle.load(handle)\n", "pickle_deserialization"),
        ]:
            with self.subTest(rule=rule):
                self._assert_blocked("patch", self._v4a_args(body + following), rule)

    def test_v4a_metadata_is_not_written_content(self) -> None:
        """Ignore pattern text in paths, hunk hints, and non-added Add lines."""
        bodies = [
            "*** Add File: new Function(body).txt\n+safe\n",
            "*** Delete File: new Function(body).txt\n",
            "*** Move File: new Function(body).txt -> ordinary.txt\n",
            "*** Move File: ordinary.txt -> new Function(body).txt\n",
            "*** Update File: example.txt\n@@ new Function(body) @@\n-old\n+safe\n",
            "*** Add File: example.txt\n new Function(body)\n-new Function(body)\n+safe\n",
        ]
        for body in bodies:
            with self.subTest(body=body):
                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=self._v4a_args(body)))

    def test_nonworkflow_paths_remain_allowed(self) -> None:
        """Do not broaden the literal workflow path predicate."""
        for path in ("config.yml", "config.yaml", "workflows/check.yml", ".github/workflows.yml", ".github/workflows/check.txt"):
            for tool, args in _content_calls(path, "") + [("patch", self._v4a_args(f"*** Delete File: {path}\n"))]:
                with self.subTest(path=path, tool=tool, mode=args.get("mode")):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))

    def test_terminal_is_outside_plugin_scope(self) -> None:
        """Leave terminal commands uninspected, even when they mention workflows."""
        args = {"command": "printf '%s' 'new Function(body)' > .github/workflows/check.yml"}
        self.assertIsNone(plugin._on_pre_tool_call(tool_name="terminal", args=args))

    def test_existing_skill_content_fields_remain_scanned(self) -> None:
        """Preserve scanning of the plugin's existing skill content fields."""
        for field in ("file_content", "new_string"):
            with self.subTest(field=field):
                self._assert_blocked("skill_manage", {"file_path": "example.py", field: "pickle.load(handle)"}, "pickle_deserialization")

    def test_warning_mode_does_not_block_or_replace_results(self) -> None:
        """Append guidance on successful results without turning warning mode into blocking."""
        calls = _content_calls(".github/workflows/check.yml", "")
        calls.append(("patch", self._v4a_args("*** Delete File: .github/workflows/check.yaml\n")))
        result = '{"success": true}'
        with patch.dict(os.environ, {"SECURITY_GUIDANCE_BLOCK": "0"}):
            for tool, args in calls:
                with self.subTest(tool=tool, mode=args.get("mode")):
                    self.assertIsNone(plugin._on_pre_tool_call(tool_name=tool, args=args))
                    warning = plugin._on_transform_tool_result(tool_name=tool, args=args, result=result)
                    self.assertIsNotNone(warning)
                    self.assertTrue(warning.startswith(result + "\n\n"))
                    self.assertIn("github_actions_workflow", warning)
                    for ignored in ('{"error": "failed"}', {"success": True}):
                        self.assertIsNone(plugin._on_transform_tool_result(tool_name=tool, args=args, result=ignored))

    def test_mode_controls_suppress_duplicate_or_disabled_guidance(self) -> None:
        """Keep block-mode transforms and disabled-plugin hooks inert."""
        args = self._v4a_args("*** Add File: example.py\n+pickle.load(handle)\n")
        self.assertIsNone(plugin._on_transform_tool_result(tool_name="patch", args=args, result="success"))
        for block in ("0", "1"):
            with self.subTest(block=block), patch.dict(os.environ, {"SECURITY_GUIDANCE_BLOCK": block, "SECURITY_GUIDANCE_DISABLE": "1"}):
                self.assertIsNone(plugin._on_pre_tool_call(tool_name="patch", args=args))
                self.assertIsNone(plugin._on_transform_tool_result(tool_name="patch", args=args, result="success"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
