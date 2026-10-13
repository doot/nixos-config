"""Check every Jellyfin person portrait; optionally queue broken-image refreshes.

Python 3.14+, standard library only. Use a server API key, not a restricted user
session. Run without --repair to check results after Jellyfin finishes its queue.
Portrait checks validate HTTP status/type/signature, not visual image content.
"""

import argparse
import json
import os
import sys
import time
from collections.abc import Mapping
from concurrent.futures import ThreadPoolExecutor
from getpass import getpass
from pathlib import Path
from typing import TYPE_CHECKING, NotRequired, Protocol, TextIO, TypedDict, override
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID

if TYPE_CHECKING:
    from email.message import Message
    from http.client import HTTPResponse

type QueryParams = Mapping[str, str | int]
"""URL query parameters accepted by the Jellyfin endpoints."""

type Response = tuple[int, str, bytes]
"""HTTP status, content type, and response body or image prefix."""

type JSONValue = None | bool | int | float | str | list[JSONValue] | dict[str, JSONValue]
"""Decoded JSON values before application-specific validation."""


class Person(TypedDict):
    """A person validated during enumeration.

    :ivar id: Normalized hexadecimal Jellyfin person UUID.
    :ivar name: Display name supplied by Jellyfin.
    """

    id: str
    name: str


class PortraitResult(Person):
    """One JSONL report record, including any attempted refresh.

    :ivar http_status: HTTP status from the portrait probe.
    :ivar healthy: Whether status, content type, and image signature passed.
    :ivar queued: Whether Jellyfin accepted a refresh, not whether it finished.
    :ivar refresh_http_status: Refresh response status; absent in audit records.
    """

    http_status: int
    healthy: bool
    queued: bool
    refresh_http_status: NotRequired[int]


class Counts(TypedDict):
    """Progress totals for a completed audit or refresh submission.

    :ivar checked: Number of portraits probed.
    :ivar healthy: Number of portraits passing all checks.
    :ivar broken: Number of portraits eligible for refresh.
    :ivar queued: Number of refresh requests accepted by Jellyfin.
    """

    checked: int
    healthy: int
    broken: int
    queued: int


class _Options(argparse.Namespace):
    """Parsed command-line options.

    :ivar url: Server URL from the command line or environment, if supplied.
    :ivar repair: Whether to queue refreshes for broken portraits.
    :ivar workers: Maximum number of concurrent portrait probes.
    :ivar interval: Delay in seconds after each accepted refresh.
    :ivar report: Path to the exclusively created JSONL report.
    """

    url: str | None
    repair: bool
    workers: int
    interval: float
    report: Path


class NoRedirect(HTTPRedirectHandler):
    """Refuse redirects so the API key cannot reach a different destination."""

    @override
    def redirect_request(
        self,
        req: Request,
        fp: object,
        code: int,
        msg: str,
        headers: Message,
        newurl: str,
    ) -> None:
        """Decline every redirect offered by urllib.

        :param req: Original authenticated request.
        :param fp: Original response stream; unused because redirects are refused.
        :param code: Redirect response status.
        :param msg: Redirect response reason phrase.
        :param headers: Redirect response headers.
        :param newurl: Proposed destination, which is never requested.
        :returns: No replacement request.
        """
        return


class Transport(Protocol):
    """Request interface shared by the HTTP client and offline fixtures."""

    def request(
        self,
        method: str,
        path: str,
        params: QueryParams | None = None,
        image: bool = False,
    ) -> Response:
        """Request an endpoint without retrying writes or following redirects.

        :param method: HTTP verb to send.
        :param path: Endpoint path beginning with a slash.
        :param params: Query parameters, or none for an unparameterized request.
        :param image: Whether only an image signature prefix is needed.
        :returns: HTTP status, content type, and body or image prefix.
        :raises RuntimeError: If a connection fails.
        """
        ...


class API:
    """Authenticated Jellyfin client with bounded reads and no write retries.

    :ivar url: Validated base URL without a trailing slash.
    :ivar token: Runtime API key sent in the authentication header.
    """

    def __init__(self, url: str, token: str) -> None:
        """Validate the server URL and retain runtime credentials.

        :param url: HTTPS base URL, or HTTP URL for a loopback host.
        :param token: Server API key; never included in reports.
        :raises ValueError: If the URL is missing a host, uses an unsafe transport,
            or includes credentials, a query, or a fragment.
        """
        parsed = urlsplit(url)
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("URL must not contain credentials, query, or fragment")
        if not parsed.hostname or (parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1"))):
            raise ValueError("Use HTTPS, or loopback HTTP on the Jellyfin host")
        self.url = url.rstrip("/")
        self.token = token

    def request(
        self,
        method: str,
        path: str,
        params: QueryParams | None = None,
        image: bool = False,
    ) -> Response:
        """Send one authenticated request with a 45-second socket timeout.

        :param method: HTTP verb to send.
        :param path: Endpoint path beginning with a slash, relative to the base URL.
        :param params: Query parameters, or none to omit the query string.
        :param image: Limit the body to 32 bytes instead of 8 MiB.
        :returns: Status, content type, and body; HTTP errors have empty content type
            and body, including refused redirects.
        :raises RuntimeError: If the connection fails; writes are never retried.
        """
        url = self.url + path + ("?" + urlencode(params) if params else "")
        request = Request(  # noqa: S310 - URL schemes are validated in __init__.
            url,
            method=method,
            headers={
                "X-Emby-Token": self.token,
                "Cache-Control": "no-cache",
                "User-Agent": "Jellyfin-People-Image-Repair/1",
            },
        )
        response: HTTPResponse
        try:
            with build_opener(NoRedirect()).open(request, timeout=45) as response:
                # Do not download entire original portraits merely to test availability.
                body = response.read(32 if image else 8 * 1024 * 1024)
                return response.status, response.headers.get("Content-Type", ""), body
        except HTTPError as error:
            status = error.code
            error.close()
            return status, "", b""
        except URLError, TimeoutError, OSError:
            raise RuntimeError("Connection failed; stopped without retrying writes") from None


def people(api: Transport) -> list[Person]:
    """Read and validate every person page before any refresh can be submitted.

    :param api: Transport used to enumerate Jellyfin people.
    :returns: Unique people with normalized UUIDs and display names.
    :raises RuntimeError: If access fails, the population count is invalid, or
        pagination is empty, inconsistent, or contains duplicate/non-person rows.
    :raises TypeError: If the page, Items list, person rows, IDs, or names have
        unexpected types.
    :raises ValueError: If JSON or a person UUID is invalid.
    :raises KeyError: If a required response field is missing.
    """
    found: dict[str, Person] = {}
    total = None
    offset = 0
    while total is None or offset < total:
        status, _, body = api.request(
            "GET",
            "/Persons",
            {
                "startIndex": offset,
                "limit": 500,
                "enableUserData": "false",
                "enableImages": "false",
            },
        )
        if status != 200:
            raise RuntimeError(f"Person enumeration failed: HTTP {status}")
        page: JSONValue = json.loads(body)
        if not isinstance(page, dict):
            raise TypeError("Malformed person page; expected an object")
        count = page["TotalRecordCount"]
        if type(count) is not int or count <= 0:
            raise RuntimeError("No people returned; check API access and library state")
        if total is not None and count != total:
            raise RuntimeError("People count changed; finish scans and rerun")
        total = count
        rows = page["Items"]
        if not isinstance(rows, list):
            raise TypeError("Malformed person page; expected an Items list")
        if not rows:
            raise RuntimeError("Incomplete pagination; no refreshes submitted")
        for row in rows:
            if not isinstance(row, dict):
                raise TypeError("Malformed person row; expected an object")
            raw_id, name = row["Id"], row["Name"]
            if not isinstance(raw_id, str) or not isinstance(name, str):
                raise TypeError("Malformed person row; Id and Name must be strings")
            person_id = UUID(raw_id).hex
            if row.get("Type") != "Person" or person_id in found:
                raise RuntimeError("Unexpected type or duplicate person; rerun with scans idle")
            found[person_id] = {"id": person_id, "name": name}
        offset += len(rows)
    if len(found) != total:
        raise RuntimeError("Person count mismatch; no refreshes submitted")
    return list(found.values())


def probe(api: Transport, person: Person) -> PortraitResult:
    """Classify a portrait by HTTP status, content type, and image signature.

    :param api: Transport used for the read-only image request.
    :param person: Validated person whose primary portrait is checked.
    :returns: A report record with no refresh queued. HTTP 404/500 and invalid
        image payloads are broken portraits, not confirmed permanent failures.
    :raises RuntimeError: If the request fails or returns an unexpected status,
        such as an authentication, rate-limit, or proxy error.
    """
    status, content_type, body = api.request("GET", f"/Items/{person['id']}/Images/Primary", image=True)
    if status not in (200, 404, 500):
        raise RuntimeError(f"Image check returned HTTP {status}; stopped (not classified as missing)")
    signature = body.startswith((b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n", b"GIF87a", b"GIF89a")) or (body.startswith(b"RIFF") and body[8:12] == b"WEBP")
    healthy = status == 200 and content_type.lower().startswith("image/") and signature
    return {
        "id": person["id"],
        "name": person["name"],
        "http_status": status,
        "healthy": healthy,
        "queued": False,
    }


def run(api: Transport, output: TextIO, *, repair: bool, workers: int, interval: float) -> Counts:
    """Audit all portraits, optionally queuing refreshes for broken ones.

    :param api: Transport used for enumeration, probes, and optional refreshes.
    :param output: Writable JSONL report stream, flushed after each record.
    :param repair: Submit refreshes for broken portraits when true.
    :param workers: Positive maximum number of concurrent image probes.
    :param interval: Nonnegative delay in seconds after each accepted refresh.
    :returns: Totals for checked, healthy, broken, and queued portraits.
    :raises RuntimeError: If enumeration, probing, or refresh submission fails;
        accepted refreshes may still run and the report may be partial.
    :raises ValueError: If JSON, a UUID, or an executor/sleep argument is invalid.
    :raises KeyError: If enumeration omits a required field.
    :raises TypeError: If a person page, row, ID, or name has an unexpected type.
    :raises OSError: If the report cannot be written.
    """
    subjects = people(api)  # Capture and validate the entire population before writes.
    print(f"Enumerated {len(subjects)} people", file=sys.stderr, flush=True)
    counts: Counts = {"checked": 0, "healthy": 0, "broken": 0, "queued": 0}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for start in range(0, len(subjects), 100):
            results = list(pool.map(lambda p: probe(api, p), subjects[start : start + 100]))
            for result in results:
                counts["checked"] += 1
                counts["healthy" if result["healthy"] else "broken"] += 1
                if repair and not result["healthy"]:
                    status, _, _ = api.request(
                        "POST",
                        f"/Items/{result['id']}/Refresh",
                        {
                            "metadataRefreshMode": "FullRefresh",
                            "imageRefreshMode": "FullRefresh",
                            "replaceAllMetadata": "false",
                            "replaceAllImages": "true",
                            "regenerateTrickplay": "false",
                        },
                    )
                    result["refresh_http_status"] = status
                    result["queued"] = status == 204
                    output.write(json.dumps(result) + "\n")
                    output.flush()
                    if status != 204:
                        raise RuntimeError(f"Refresh returned HTTP {status}; stopped without retrying")
                    counts["queued"] += 1
                    time.sleep(interval)
                else:
                    output.write(json.dumps(result) + "\n")
                    output.flush()
            print(json.dumps(dict(counts)), file=sys.stderr, flush=True)
    return counts


def main() -> int:
    """Parse arguments, authenticate, and create a private audit report.

    The API key comes from the environment or a non-echoing prompt. Existing
    reports are never overwritten; partial reports remain after a failure.

    :returns: Zero on completion, or two for broken portraits in audit mode.
    :raises SystemExit: With zero for help or two for invalid CLI arguments.
    :raises RuntimeError: If server preflight or the audit/refresh fails.
    :raises ValueError: If the URL or server response is invalid.
    :raises KeyError: If the server omits a required enumeration field.
    :raises TypeError: If a person page, row, ID, or name has an unexpected type.
    :raises OSError: If report creation or writing fails.
    :raises KeyboardInterrupt: If the operator interrupts execution.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--url",
        default=os.environ.get("JELLYFIN_URL"),
        help="Server URL (or JELLYFIN_URL; default: %(default)s)",
    )
    parser.add_argument(
        "--repair",
        action="store_true",
        help="Queue refreshes; default is read-only checking",
    )
    parser.add_argument("--workers", type=int, default=4, help="Concurrent image checks (default: 4)")
    parser.add_argument(
        "--interval",
        type=float,
        default=0.5,
        help="Seconds between refresh requests (default: 0.5)",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("people-images-" + time.strftime("%Y%m%d-%H%M%S") + ".jsonl"),
    )
    args = parser.parse_args(namespace=_Options())
    if not args.url:
        parser.error("Set --url or JELLYFIN_URL")
    if not 1 <= args.workers <= 16 or not 0 <= args.interval <= 60:
        parser.error("workers must be 1..16 and interval 0..60 seconds")
    token = os.environ.get("JELLYFIN_API_KEY") or getpass("Jellyfin server API key: ")
    if not token.strip():
        parser.error("An API key is required")
    api = API(args.url, token)
    status, _, _ = api.request("GET", "/System/Info")
    if status != 200:
        raise RuntimeError(f"Authenticated server check failed: HTTP {status}")
    # Reports contain private names/IDs; never overwrite existing files.
    fd = os.open(args.report, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        counts = run(
            api,
            output,
            repair=args.repair,
            workers=args.workers,
            interval=args.interval,
        )
    print(json.dumps(counts))
    print(f"Report: {args.report.resolve()}")
    if counts["queued"]:
        print("QUEUED, not verified repaired. After Jellyfin finishes, rerun WITHOUT --repair.")
    return 2 if counts["broken"] and not args.repair else 0


def cli() -> int:
    """Run the console command with concise failure and interruption messages.

    :returns: The audit exit code, one for a handled failure, or 130 on interrupt.
        Already queued refreshes may continue after a failure or interruption.
    :raises SystemExit: With zero for help or two for invalid CLI arguments.
    """
    try:
        return main()
    except (RuntimeError, ValueError, TypeError, KeyError, OSError) as error:
        print(f"Stopped: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Stopped. Previously queued refreshes may still run.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(cli())
