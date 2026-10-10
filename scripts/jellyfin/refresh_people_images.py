#!/usr/bin/env python3
"""Check every Jellyfin person portrait; optionally queue broken-image refreshes.

Python 3.10+, standard library only. Use a server API key, not a restricted user
session. Run without --repair to check results after Jellyfin finishes its queue.
Portrait checks validate HTTP status/type/signature, not visual image content.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from getpass import getpass
import json
import os
from pathlib import Path
import sys
import time
from typing import Protocol, TextIO
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the API key to a redirect destination.


class Transport(Protocol):
    def request(self, method: str, path: str, params=None, image: bool = False) -> tuple[int, str, bytes]:
        ...


class API:
    def __init__(self, url: str, token: str):
        parsed = urlsplit(url)
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('URL must not contain credentials, query, or fragment')
        if not parsed.hostname or (parsed.scheme != 'https' and not
                (parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1'))):
            raise ValueError('Use HTTPS, or loopback HTTP on the Jellyfin host')
        self.url = url.rstrip('/')
        self.token = token

    def request(self, method: str, path: str, params=None, image=False):
        url = self.url + path + ('?' + urlencode(params) if params else '')
        request = Request(url, method=method, headers={
            'X-Emby-Token': self.token,
            'Cache-Control': 'no-cache',
            'User-Agent': 'Jellyfin-People-Image-Repair/1',
        })
        try:
            with build_opener(NoRedirect()).open(request, timeout=45) as response:
                # Do not download entire original portraits merely to test availability.
                body = response.read(32 if image else 8 * 1024 * 1024)
                return response.status, response.headers.get('Content-Type', ''), body
        except HTTPError as error:
            status = error.code
            error.close()
            return status, '', b''
        except (URLError, TimeoutError, OSError):
            raise RuntimeError('Connection failed; stopped without retrying writes') from None


def people(api: Transport) -> list[dict]:
    found = {}
    total = None
    offset = 0
    while total is None or offset < total:
        status, _, body = api.request('GET', '/Persons', {
            'startIndex': offset, 'limit': 500, 'enableUserData': 'false',
            'enableImages': 'false',
        })
        if status != 200:
            raise RuntimeError(f'Person enumeration failed: HTTP {status}')
        page = json.loads(body)
        count = page['TotalRecordCount']
        if not isinstance(count, int) or count <= 0:
            raise RuntimeError('No people returned; check API access and library state')
        if total is not None and count != total:
            raise RuntimeError('People count changed; finish scans and rerun')
        total = count
        rows = page['Items']
        if not rows:
            raise RuntimeError('Incomplete pagination; no refreshes submitted')
        for row in rows:
            person_id = UUID(row['Id']).hex
            if row.get('Type') != 'Person' or person_id in found:
                raise RuntimeError('Unexpected type or duplicate person; rerun with scans idle')
            found[person_id] = {'id': person_id, 'name': row['Name']}
        offset += len(rows)
    if len(found) != total:
        raise RuntimeError('Person count mismatch; no refreshes submitted')
    return list(found.values())


def probe(api: Transport, person: dict) -> dict:
    status, content_type, body = api.request(
        'GET', f"/Items/{person['id']}/Images/Primary", image=True)
    if status not in (200, 404, 500):
        raise RuntimeError(f'Image check returned HTTP {status}; stopped (not classified as missing)')
    signature = (body.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n', b'GIF87a', b'GIF89a'))
                 or (body.startswith(b'RIFF') and body[8:12] == b'WEBP'))
    healthy = status == 200 and content_type.lower().startswith('image/') and signature
    return dict(person, http_status=status, healthy=healthy, queued=False)


def run(api: Transport, output: TextIO, *, repair: bool, workers: int, interval: float) -> dict:
    subjects = people(api)  # Capture and validate the entire population before writes.
    print(f'Enumerated {len(subjects)} people', file=sys.stderr, flush=True)
    counts = Counter(checked=0, healthy=0, broken=0, queued=0)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for start in range(0, len(subjects), 100):
            results = list(pool.map(lambda p: probe(api, p), subjects[start:start + 100]))
            for result in results:
                counts['checked'] += 1
                counts['healthy' if result['healthy'] else 'broken'] += 1
                if repair and not result['healthy']:
                    status, _, _ = api.request('POST', f"/Items/{result['id']}/Refresh", {
                        'metadataRefreshMode': 'FullRefresh',
                        'imageRefreshMode': 'FullRefresh',
                        'replaceAllMetadata': 'false',
                        'replaceAllImages': 'true',
                        'regenerateTrickplay': 'false',
                    })
                    result['refresh_http_status'] = status
                    result['queued'] = status == 204
                    output.write(json.dumps(result) + '\n')
                    output.flush()
                    if status != 204:
                        raise RuntimeError(f'Refresh returned HTTP {status}; stopped without retrying')
                    counts['queued'] += 1
                    time.sleep(interval)
                else:
                    output.write(json.dumps(result) + '\n')
                    output.flush()
            print(json.dumps(dict(counts)), file=sys.stderr, flush=True)
    return dict(counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default=os.environ.get('JELLYFIN_URL'), help='Server URL (or JELLYFIN_URL)')
    parser.add_argument('--repair', action='store_true', help='Queue refreshes; default is read-only checking')
    parser.add_argument('--workers', type=int, default=4, help='Concurrent image checks (default: 4)')
    parser.add_argument('--interval', type=float, default=0.5, help='Seconds between refresh requests (default: 0.5)')
    parser.add_argument('--report', type=Path, default=Path('people-images-' + time.strftime('%Y%m%d-%H%M%S') + '.jsonl'))
    args = parser.parse_args()
    if not args.url:
        parser.error('Set --url or JELLYFIN_URL')
    if not 1 <= args.workers <= 16 or not 0 <= args.interval <= 60:
        parser.error('workers must be 1..16 and interval 0..60 seconds')
    token = os.environ.get('JELLYFIN_API_KEY') or getpass('Jellyfin server API key: ')
    if not token.strip():
        parser.error('An API key is required')
    api = API(args.url, token)
    status, _, _ = api.request('GET', '/System/Info')
    if status != 200:
        raise RuntimeError(f'Authenticated server check failed: HTTP {status}')
    # Exclusive creation protects earlier reports; names and IDs are private library data.
    fd = os.open(args.report, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        counts = run(api, output, repair=args.repair, workers=args.workers, interval=args.interval)
    print(json.dumps(counts))
    print(f'Report: {args.report.resolve()}')
    if counts['queued']:
        print('QUEUED, not verified repaired. After Jellyfin finishes, rerun WITHOUT --repair.')
    return 2 if counts['broken'] and not args.repair else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f'Stopped: {error}', file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print('Stopped. Previously queued refreshes may still run.', file=sys.stderr)
        raise SystemExit(130)
