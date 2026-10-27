#!/usr/bin/env python3
"""Read costume-reference metadata/previews from the theater's Immich archive.

The API key is read directly from macOS Keychain. It is never written to disk,
printed, passed as a command-line argument, or sent anywhere except the configured
archive. Only GET and the read-only metadata-search operation are implemented.
Private downloads stay in the ignored .secrets directory.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.secrets' / 'wardrobe-photo-references'
BASE = 'https://photo.rittmann.cloud/api'
SERVICE = 'photo.rittmann.cloud TheaterApp API'
ACCOUNT = 'Theater@rittmann.cloud'


def asset_id(value):
    return str(uuid.UUID(value))


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('wb') as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def save_json(path, data):
    save(path, json.dumps(data, ensure_ascii=False, indent=2).encode('utf-8'))


def summary(asset):
    """Keep costume evidence, without unrelated EXIF location or account data."""
    exif = asset.get('exifInfo') or {}
    return {
        'id': asset['id'],
        'originalFileName': asset.get('originalFileName'),
        'type': asset.get('type'),
        'fileCreatedAt': asset.get('fileCreatedAt'),
        'description': exif.get('description') or '',
        'width': exif.get('exifImageWidth') or asset.get('width'),
        'height': exif.get('exifImageHeight') or asset.get('height'),
        'people': [{'id': p['id'], 'name': p.get('name', '')}
                   for p in asset.get('people', []) if p.get('name')],
        'tags': [{'id': t['id'], 'value': t.get('value', '')}
                 for t in asset.get('tags', [])],
    }


class Archive:
    def __init__(self):
        result = subprocess.run(
            ['security', 'find-generic-password', '-a', ACCOUNT, '-s', SERVICE, '-w'],
            capture_output=True, text=True, check=False,
        )
        if result.returncode or not result.stdout.strip():
            raise RuntimeError(f'Keychain entry unavailable: {SERVICE} ({ACCOUNT})')
        self.key = result.stdout.strip()
        self.opener = urllib.request.build_opener(ArchiveRedirects())

    def request(self, path, data=None, binary=False):
        if data is not None and path != '/search/metadata':
            raise ValueError('Only read-only metadata search accepts a body')
        request = urllib.request.Request(
            BASE + path,
            data=json.dumps(data).encode() if data is not None else None,
            headers={'x-api-key': self.key, 'Content-Type': 'application/json'},
        )
        with self.opener.open(request, timeout=40) as response:
            return response.read() if binary else json.load(response)

    def albums(self):
        fields = ('id', 'albumName', 'description', 'assetCount', 'startDate', 'endDate')
        return [{k: a.get(k) for k in fields} for a in self.request('/albums')]

    def search(self, album, year=None):
        result, page = [], 1
        while True:
            body = {'albumIds': [album], 'size': 1000, 'page': page,
                    'withExif': True, 'withPeople': True}
            if year:
                body.update(takenAfter=f'{year}-01-01T00:00:00Z',
                            takenBefore=f'{year + 1}-01-01T00:00:00Z')
            response = self.request('/search/metadata', body)['assets']
            result.extend(summary(x) for x in response['items'])
            if not response.get('nextPage'):
                break
            page = int(response['nextPage'])
        return result


class ArchiveRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        target = urllib.parse.urlparse(url)
        if target.scheme != 'https' or target.netloc != 'photo.rittmann.cloud':
            raise RuntimeError('Refusing to forward the archive credential to another origin')
        return super().redirect_request(request, response, code, message, headers, url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('albums', help='List available albums and cache their metadata')
    search = sub.add_parser('album', help='Cache one album\'s reference metadata')
    search.add_argument('id', type=asset_id)
    search.add_argument('--year', type=int)
    download = sub.add_parser('download', help='Download selected preview images')
    download.add_argument('ids', type=asset_id, nargs='+')
    download.add_argument('--faces', action='store_true',
                          help='Include existing labeled face boxes (requires face.read)')
    args = parser.parse_args()
    archive = Archive()
    if args.command == 'albums':
        albums = archive.albums()
        save_json(CACHE / 'album-inventory.json', albums)
        for album in albums:
            print(f"{album['id']}  {album['assetCount']:5}  {album['albumName']}")
    elif args.command == 'album':
        items = archive.search(args.id, args.year)
        filename = args.id + (f'-{args.year}' if args.year else '') + '-references.json'
        save_json(CACHE / filename, items)
        print(f'{len(items)} reference records: {CACHE / filename}')
    else:
        for identifier in args.ids:
            asset = summary(archive.request('/assets/' + identifier))
            if asset['type'] != 'IMAGE':
                print(f'Skipping non-image {identifier}')
                continue
            save_json(CACHE / 'previews' / f'{identifier}.json', asset)
            save(CACHE / 'previews' / f'{identifier}.jpg', archive.request(
                f'/assets/{identifier}/thumbnail?size=preview', binary=True))
            if args.faces:
                faces = archive.request('/faces?' + urllib.parse.urlencode({'id': identifier}))
                # These labels already exist in Immich. This tool neither detects
                # nor matches faces and does not infer an actor from appearance.
                fields = ('id', 'boundingBoxX1', 'boundingBoxX2', 'boundingBoxY1',
                          'boundingBoxY2', 'imageWidth', 'imageHeight', 'sourceType')
                minimal = [{**{k: face.get(k) for k in fields},
                            'person': {k: (face.get('person') or {}).get(k)
                                       for k in ('id', 'name')}} for face in faces]
                save_json(CACHE / 'previews' / f'{identifier}-faces.json', minimal)
            print(CACHE / 'previews' / f'{identifier}.jpg')


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        # Never include request headers or response bodies in diagnostics.
        print(f'Archive request failed (HTTP {error.code}).', file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, urllib.error.URLError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
