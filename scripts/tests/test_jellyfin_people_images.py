"""Offline API fixtures; no Jellyfin access or database writes."""

import io
import json
import os
import tempfile
import unittest
from http.client import HTTPMessage
from importlib.metadata import distribution
from pathlib import Path
from typing import TYPE_CHECKING, override
from unittest.mock import patch
from urllib.request import HTTPRedirectHandler, Request

from homelab_tools import jellyfin_people_images as images

if TYPE_CHECKING:
    from collections.abc import Iterable, Mapping, Sequence

IDS = [f"{index:032x}" for index in range(1, 5)]
PERSON: images.Person = {"id": IDS[0], "name": "Fixture"}


class FixtureAPI(images.Transport):
    """Serve two person pages and one healthy portrait without network access.

    :ivar calls: Recorded HTTP verbs, paths, and query parameters.
    """

    def __init__(self) -> None:
        """Start with an empty request log."""
        self.calls: list[tuple[str, str, images.QueryParams | None]] = []

    @override
    def request(
        self,
        method: str,
        path: str,
        params: images.QueryParams | None = None,
        image: bool = False,
    ) -> images.Response:
        """Record a request and serve the corresponding offline fixture.

        :param method: HTTP verb; POST simulates a successful refresh.
        :param path: Endpoint selecting preflight, people, or portrait fixtures.
        :param params: Query parameters containing the person-page offset.
        :param image: Image-prefix flag; fixtures already contain only prefixes.
        :returns: Simulated status, content type, and body.
        """
        self.calls.append((method, path, params))
        if path == "/System/Info":
            return 200, "", b""
        if path == "/Persons":
            assert params is not None
            start = params["startIndex"]
            assert isinstance(start, int)
            rows = [
                {"Id": item, "Name": item, "Type": "Person"}
                for item in IDS[start : start + 2]
            ]
            return (
                200,
                "application/json",
                json.dumps(
                    {
                        "Items": rows,
                        "TotalRecordCount": len(IDS),
                    }
                ).encode(),
            )
        if method == "POST":
            return 204, "", b""
        index = IDS.index(path.split("/")[2])
        return [
            (200, "image/jpeg", b"\xff\xd8\xffimage"),
            (404, "", b""),
            (500, "", b""),
            (200, "text/html", b"not an image"),
        ][index]


class Replies(images.Transport):
    """Serve a predetermined response sequence without network access.

    :ivar responses: Iterator over the remaining fixture responses.
    """

    def __init__(self, responses: Iterable[images.Response]) -> None:
        """Retain an ordered sequence of responses.

        :param responses: Responses to return on successive requests.
        """
        self.responses = iter(responses)

    @override
    def request(
        self,
        method: str,
        path: str,
        params: images.QueryParams | None = None,
        image: bool = False,
    ) -> images.Response:
        """Return the next response regardless of the request contents.

        :param method: HTTP verb, unused by the sequential fixture.
        :param path: Endpoint path, unused by the sequential fixture.
        :param params: Query parameters, unused by the sequential fixture.
        :param image: Image-prefix flag, unused by the sequential fixture.
        :returns: The next preconfigured response.
        :raises StopIteration: If the test makes more requests than expected.
        """
        return next(self.responses)


def page(items: Sequence[Mapping[str, str]], total: int) -> images.Response:
    """Encode a person page for an offline response.

    :param items: Raw Jellyfin person records, including invalid test cases.
    :param total: Advertised population count across every page.
    :returns: A successful JSON response containing the supplied page.
    """
    return (
        200,
        "application/json",
        json.dumps(
            {
                "Items": items,
                "TotalRecordCount": total,
            }
        ).encode(),
    )


class PeopleImagesTest(unittest.TestCase):
    """Exercise audit, refresh, transport, and CLI safety using offline fixtures."""

    def test_console_entrypoint_stops_cleanly_on_failure_or_interrupt(self) -> None:
        """Translate expected failures and interrupts into documented exit codes."""
        (command,) = [
            entry
            for entry in distribution("homelab-tools").entry_points
            if entry.group == "console_scripts"
            and entry.name == "jellyfin-people-images"
        ]
        failures: list[tuple[BaseException, int]] = [
            (kind("offline failure"), 1)
            for kind in (RuntimeError, ValueError, TypeError, KeyError, OSError)
        ]
        failures.append((KeyboardInterrupt(), 130))
        for error, expected_status in failures:
            with self.subTest(error=type(error).__name__):
                stderr = io.StringIO()
                with (
                    patch.dict(
                        os.environ,
                        {
                            "JELLYFIN_URL": "https://example.com/jellyfin",
                            "JELLYFIN_API_KEY": "fixture",
                        },
                        clear=True,
                    ),
                    patch("sys.argv", ["jellyfin-people-images"]),
                    patch.object(images, "API", side_effect=error),
                    patch.object(images, "run") as run,
                    patch("sys.stderr", stderr),
                ):
                    try:
                        status = command.load()()
                    except (
                        RuntimeError,
                        ValueError,
                        TypeError,
                        KeyError,
                        OSError,
                        KeyboardInterrupt,
                    ) as leaked:
                        self.fail(f"Console entrypoint leaked {type(leaked).__name__}")
                self.assertEqual(status, expected_status)
                message = (
                    "Stopped. Previously queued refreshes may still run."
                    if expected_status == 130
                    else f"Stopped: {error}"
                )
                self.assertEqual(stderr.getvalue(), message + "\n")
                run.assert_not_called()

    def test_all_pages_probe_then_repair_only_broken(self) -> None:
        """Enumerate every page and refresh only broken portraits."""
        api = FixtureAPI()
        output = io.StringIO()
        counts = images.run(api, output, repair=True, workers=2, interval=0)
        self.assertEqual(counts, {"checked": 4, "healthy": 1, "broken": 3, "queued": 3})
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual({record["id"] for record in records}, set(IDS))
        posts = [call for call in api.calls if call[0] == "POST"]
        self.assertEqual(len(posts), 3)
        self.assertEqual({call[1].split("/")[2] for call in posts}, set(IDS[1:]))
        for _, _, params in posts:
            self.assertEqual(
                params,
                {
                    "metadataRefreshMode": "FullRefresh",
                    "imageRefreshMode": "FullRefresh",
                    "replaceAllMetadata": "false",
                    "replaceAllImages": "true",
                    "regenerateTrickplay": "false",
                },
            )

    def test_read_only_pass_never_posts(self) -> None:
        """Audit the complete population without issuing any POST requests."""
        api = FixtureAPI()
        counts = images.run(api, io.StringIO(), repair=False, workers=1, interval=0)
        self.assertEqual(counts["checked"], len(IDS))
        self.assertEqual(counts["queued"], 0)
        self.assertFalse(any(call[0] == "POST" for call in api.calls))

    def test_access_and_proxy_errors_are_not_missing_portraits(self) -> None:
        """Stop on access, rate-limit, and proxy errors instead of queuing repairs."""
        for status in (401, 403, 429, 502, 503):
            with self.subTest(status=status), self.assertRaises(RuntimeError):
                images.probe(Replies([(status, "", b"")]), PERSON)

    def test_supported_image_signatures(self) -> None:
        """Accept JPEG, PNG, GIF, and WebP prefixes with image content types."""
        for body in (
            b"\xff\xd8\xff",
            b"\x89PNG\r\n\x1a\n",
            b"GIF87a",
            b"GIF89a",
            b"RIFFxxxxWEBP",
        ):
            with self.subTest(body=body):
                result = images.probe(Replies([(200, "image/example", body)]), PERSON)
                self.assertTrue(result["healthy"])

    def test_invalid_population_fails_before_refresh(self) -> None:
        """Reject empty, inconsistent, duplicate, or invalid populations."""
        row = {"Id": IDS[0], "Name": "Fixture", "Type": "Person"}
        cases = (
            [page([], 0)],
            [page([], 2)],
            [page([row, row], 2)],
            [page([dict(row, Type="Movie")], 1)],
            [page([dict(row, Id="not-a-guid")], 1)],
            [page([row], 2), page([], 2)],
            [page([row], 2), page([], 3)],
        )
        for responses in cases:
            with (
                self.subTest(responses=responses),
                self.assertRaises((RuntimeError, ValueError)),
            ):
                images.run(
                    Replies(responses),
                    io.StringIO(),
                    repair=True,
                    workers=1,
                    interval=0,
                )

    def test_malformed_population_is_rejected_before_refresh(self) -> None:
        """Reject incorrectly shaped JSON before submitting any refreshes."""
        row = {"Id": IDS[0], "Name": "Fixture", "Type": "Person"}
        payloads: tuple[object, ...] = (
            None,
            [],
            {"TotalRecordCount": True, "Items": [row]},
            {"TotalRecordCount": 1, "Items": "invalid"},
            {"TotalRecordCount": 1, "Items": [None]},
            {"TotalRecordCount": 1, "Items": [dict(row, Id=123)]},
            {"TotalRecordCount": 1, "Items": [dict(row, Name=123)]},
        )
        for payload in payloads:
            api = Replies([(200, "application/json", json.dumps(payload).encode())])
            output = io.StringIO()
            with (
                self.subTest(payload=payload),
                patch.object(api, "request", wraps=api.request) as request,
                self.assertRaises((RuntimeError, TypeError)),
            ):
                images.run(api, output, repair=True, workers=1, interval=0)
            self.assertEqual(request.call_count, 1)
            self.assertFalse(
                any(call.args[0] == "POST" for call in request.call_args_list)
            )
            self.assertEqual(output.getvalue(), "")

    def test_refresh_failure_is_reported_and_not_retried(self) -> None:
        """Record a failed refresh response and stop without retrying the write."""
        row = {"Id": IDS[0], "Name": "Fixture", "Type": "Person"}
        output = io.StringIO()
        api = Replies([page([row], 1), (404, "", b""), (503, "", b"")])
        with self.assertRaisesRegex(RuntimeError, "Refresh returned HTTP 503"):
            images.run(api, output, repair=True, workers=1, interval=0)
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertFalse(records[0]["queued"])
        self.assertEqual(records[0]["refresh_http_status"], 503)

    def test_remote_http_and_credential_urls_are_rejected(self) -> None:
        """Reject unsafe transports, credentials, queries, and fragments."""
        for url in (
            "http://example.com",
            "file:///etc/passwd",
            "ftp://example.com",
            "custom://example.com",
            "https://user@example.com",
            "https://example.com?key=value",
            "https://example.com#fragment",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                images.API(url, "fixture")
        for url in (
            "https://example.com/jellyfin",
            "http://127.0.0.1:8096",
            "http://localhost:8096",
            "http://[::1]:8096",
        ):
            with self.subTest(url=url):
                self.assertEqual(images.API(url, "fixture").url, url)

    def test_redirects_cannot_forward_credentials(self) -> None:
        """Refuse replacement requests to prevent forwarding the API key."""
        handler: HTTPRedirectHandler = images.NoRedirect()
        result = handler.redirect_request(
            Request("https://example.com"),
            io.BytesIO(),
            302,
            "",
            HTTPMessage(),
            "https://other.example.com",
        )
        self.assertIsNone(result)

    def test_cli_help_shows_url_default_without_api_key(self) -> None:
        """Show the URL default without leaking keys, prompting, or connecting."""
        for url in (None, "https://example.com/jellyfin"):
            with self.subTest(url=url):
                env = {"JELLYFIN_API_KEY": "fixture-secret-key"}
                if url is not None:
                    env["JELLYFIN_URL"] = url
                stdout, stderr = io.StringIO(), io.StringIO()
                with (
                    patch.dict(os.environ, env, clear=True),
                    patch("sys.argv", ["jellyfin-people-images", "--help"]),
                    patch("sys.stdout", stdout),
                    patch("sys.stderr", stderr),
                    patch.object(images, "API") as api,
                    patch.object(images, "getpass") as prompt,
                    self.assertRaises(SystemExit) as result,
                ):
                    images.cli()
                self.assertEqual(result.exception.code, 0)
                self.assertIn(f"default: {url}", " ".join(stdout.getvalue().split()))
                self.assertNotIn(
                    env["JELLYFIN_API_KEY"], stdout.getvalue() + stderr.getvalue()
                )
                api.assert_not_called()
                prompt.assert_not_called()

    def test_cli_url_overrides_environment(self) -> None:
        """Prefer the explicit URL argument over the environment default."""
        with tempfile.TemporaryDirectory() as directory:
            url = "https://override.example.com/jellyfin"
            argv = [
                "jellyfin-people-images",
                "--url",
                url,
                "--report",
                str(Path(directory) / "report.jsonl"),
            ]
            with (
                patch.dict(
                    os.environ,
                    {
                        "JELLYFIN_URL": "https://example.com/jellyfin",
                        "JELLYFIN_API_KEY": "fixture",
                    },
                    clear=True,
                ),
                patch("sys.argv", argv),
                patch.object(images, "API", return_value=FixtureAPI()) as factory,
                patch("sys.stdout", io.StringIO()),
                patch("sys.stderr", io.StringIO()),
            ):
                self.assertEqual(images.cli(), 2)
            factory.assert_called_once_with(url, "fixture")

    def test_cli_report_permissions_exit_codes_and_no_overwrite(self) -> None:
        """Create private reports without overwrites and return audit/repair codes."""
        for repair in (False, True):
            with (
                self.subTest(repair=repair),
                tempfile.TemporaryDirectory() as directory,
            ):
                report = Path(directory) / "report.jsonl"
                argv = [
                    "jellyfin-people-images",
                    "--report",
                    str(report),
                    "--interval",
                    "0",
                ]
                if repair:
                    argv.append("--repair")
                api = FixtureAPI()
                with (
                    patch.dict(
                        os.environ,
                        {
                            "JELLYFIN_URL": "https://example.com/jellyfin",
                            "JELLYFIN_API_KEY": "fixture",
                        },
                        clear=True,
                    ),
                    patch("sys.argv", argv),
                    patch.object(images, "API", return_value=api) as factory,
                ):
                    self.assertEqual(images.main(), 0 if repair else 2)
                    factory.assert_called_once_with(
                        "https://example.com/jellyfin", "fixture"
                    )
                    self.assertEqual(report.stat().st_mode & 0o777, 0o600)
                    records = [
                        json.loads(line) for line in report.read_text().splitlines()
                    ]
                    self.assertEqual(len(records), len(IDS))
                    before = report.read_bytes()
                    with self.assertRaises(FileExistsError):
                        images.main()
                    self.assertEqual(report.read_bytes(), before)

    def test_cli_requires_explicit_server_before_connecting(self) -> None:
        """Reject a missing server before connecting or creating a report."""
        with tempfile.TemporaryDirectory() as directory:
            report = str(Path(directory) / "report.jsonl")
            with (
                patch.dict(os.environ, {"JELLYFIN_API_KEY": "fixture"}, clear=True),
                patch("sys.argv", ["jellyfin-people-images", "--report", report]),
                patch.object(images, "API") as api,
                patch.object(images, "run", return_value={"broken": 0, "queued": 0}),
                self.assertRaises(SystemExit) as error,
            ):
                api.return_value.request.return_value = (200, "", b"")
                images.main()
            self.assertEqual(error.exception.code, 2)
            api.assert_not_called()
            self.assertFalse(Path(report).exists())


if __name__ == "__main__":
    unittest.main()
