"""Offline API fixtures; no Jellyfin access or database writes."""
import io
from http.client import HTTPMessage
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.request import Request

import refresh_people_images as images


IDS = [f'{index:032x}' for index in range(1, 5)]
PERSON = {'id': IDS[0], 'name': 'Fixture'}


class FixtureAPI:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None, image=False):
        self.calls.append((method, path, params))
        if path == '/System/Info':
            return 200, '', b''
        if path == '/Persons':
            assert params is not None
            start = params['startIndex']
            rows = [{'Id': item, 'Name': item, 'Type': 'Person'}
                    for item in IDS[start:start + 2]]
            return 200, 'application/json', json.dumps({
                'Items': rows, 'TotalRecordCount': len(IDS),
            }).encode()
        if method == 'POST':
            return 204, '', b''
        index = IDS.index(path.split('/')[2])
        return [
            (200, 'image/jpeg', b'\xff\xd8\xffimage'),
            (404, '', b''),
            (500, '', b''),
            (200, 'text/html', b'not an image'),
        ][index]


class Replies:
    def __init__(self, responses):
        self.responses = iter(responses)

    def request(self, *args, **kwargs):
        return next(self.responses)


def page(items, total):
    return 200, 'application/json', json.dumps({
        'Items': items, 'TotalRecordCount': total,
    }).encode()


class PeopleImagesTest(unittest.TestCase):
    def test_all_pages_probe_then_repair_only_broken(self):
        api = FixtureAPI()
        output = io.StringIO()
        counts = images.run(api, output, repair=True, workers=2, interval=0)
        self.assertEqual(counts, {'checked': 4, 'healthy': 1, 'broken': 3, 'queued': 3})
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual({record['id'] for record in records}, set(IDS))
        posts = [call for call in api.calls if call[0] == 'POST']
        self.assertEqual(len(posts), 3)
        self.assertEqual({call[1].split('/')[2] for call in posts}, set(IDS[1:]))
        for _, _, params in posts:
            self.assertEqual(params, {
                'metadataRefreshMode': 'FullRefresh',
                'imageRefreshMode': 'FullRefresh',
                'replaceAllMetadata': 'false',
                'replaceAllImages': 'true',
                'regenerateTrickplay': 'false',
            })

    def test_read_only_pass_never_posts(self):
        api = FixtureAPI()
        counts = images.run(api, io.StringIO(), repair=False, workers=1, interval=0)
        self.assertEqual(counts['checked'], len(IDS))
        self.assertEqual(counts['queued'], 0)
        self.assertFalse(any(call[0] == 'POST' for call in api.calls))

    def test_access_and_proxy_errors_are_not_missing_portraits(self):
        for status in (401, 403, 429, 502, 503):
            with self.subTest(status=status), self.assertRaises(RuntimeError):
                images.probe(Replies([(status, '', b'')]), PERSON)

    def test_supported_image_signatures(self):
        for body in (b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n', b'GIF87a',
                     b'GIF89a', b'RIFFxxxxWEBP'):
            with self.subTest(body=body):
                result = images.probe(Replies([(200, 'image/example', body)]), PERSON)
                self.assertTrue(result['healthy'])

    def test_invalid_population_fails_before_refresh(self):
        row = {'Id': IDS[0], 'Name': 'Fixture', 'Type': 'Person'}
        cases = (
            [page([], 0)],
            [page([], 2)],
            [page([row, row], 2)],
            [page([dict(row, Type='Movie')], 1)],
            [page([dict(row, Id='not-a-guid')], 1)],
            [page([row], 2), page([], 2)],
            [page([row], 2), page([], 3)],
        )
        for responses in cases:
            with self.subTest(responses=responses), self.assertRaises((RuntimeError, ValueError)):
                images.run(Replies(responses), io.StringIO(), repair=True, workers=1, interval=0)

    def test_refresh_failure_is_reported_and_not_retried(self):
        row = {'Id': IDS[0], 'Name': 'Fixture', 'Type': 'Person'}
        output = io.StringIO()
        api = Replies([page([row], 1), (404, '', b''), (503, '', b'')])
        with self.assertRaisesRegex(RuntimeError, 'Refresh returned HTTP 503'):
            images.run(api, output, repair=True, workers=1, interval=0)
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertFalse(records[0]['queued'])
        self.assertEqual(records[0]['refresh_http_status'], 503)

    def test_remote_http_and_credential_urls_are_rejected(self):
        for url in ('http://example.com', 'https://user@example.com',
                    'https://example.com?key=value', 'https://example.com#fragment'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                images.API(url, 'fixture')
        for url in ('https://example.com/jellyfin', 'http://127.0.0.1:8096',
                    'http://localhost:8096', 'http://[::1]:8096'):
            with self.subTest(url=url):
                self.assertEqual(images.API(url, 'fixture').url, url)

    def test_redirects_cannot_forward_credentials(self):
        result = images.NoRedirect().redirect_request(
            Request('https://example.com'), io.BytesIO(), 302, '',
            HTTPMessage(), 'https://other.example.com')
        self.assertIsNone(result)

    def test_cli_report_permissions_exit_codes_and_no_overwrite(self):
        for repair in (False, True):
            with self.subTest(repair=repair), tempfile.TemporaryDirectory() as directory:
                report = Path(directory) / 'report.jsonl'
                argv = ['refresh_people_images.py', '--report', str(report), '--interval', '0']
                if repair:
                    argv.append('--repair')
                api = FixtureAPI()
                with patch.dict(os.environ, {
                    'JELLYFIN_URL': 'https://example.com/jellyfin',
                    'JELLYFIN_API_KEY': 'fixture',
                }, clear=True), patch('sys.argv', argv), patch.object(images, 'API', return_value=api) as factory:
                    self.assertEqual(images.main(), 0 if repair else 2)
                    factory.assert_called_once_with('https://example.com/jellyfin', 'fixture')
                    self.assertEqual(report.stat().st_mode & 0o777, 0o600)
                    records = [json.loads(line) for line in report.read_text().splitlines()]
                    self.assertEqual(len(records), len(IDS))
                    before = report.read_bytes()
                    with self.assertRaises(FileExistsError):
                        images.main()
                    self.assertEqual(report.read_bytes(), before)

    def test_cli_requires_explicit_server_before_connecting(self):
        with tempfile.TemporaryDirectory() as directory:
            report = str(Path(directory) / 'report.jsonl')
            with patch.dict(os.environ, {'JELLYFIN_API_KEY': 'fixture'}, clear=True), \
                    patch('sys.argv', ['refresh_people_images.py', '--report', report]), \
                    patch.object(images, 'API') as api, \
                    patch.object(images, 'run', return_value={'broken': 0, 'queued': 0}), \
                    self.assertRaises(SystemExit) as error:
                api.return_value.request.return_value = (200, '', b'')
                images.main()
            self.assertEqual(error.exception.code, 2)
            api.assert_not_called()
            self.assertFalse(Path(report).exists())


if __name__ == '__main__':
    unittest.main()
