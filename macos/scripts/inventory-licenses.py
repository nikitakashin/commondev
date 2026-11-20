#!/usr/bin/env python3
"""Inventory package metadata/license-file presence in a packaged sidecar.

Usage: python3 commondev-license-inventory.py /path/to/FreeLLMAPI > inventory.json
This is an inventory, not a compliance determination. Bundle provenance is
reported only when matching build metadata is present; the contents of native
binaries and actual license obligations require separate review.
"""
import collections
import hashlib
import json
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
modules = root / 'node_modules'
if not modules.is_dir():
    raise SystemExit(f'node_modules not found: {modules}')
records = []
errors = []
for current, dirs, files in os.walk(modules, followlinks=False):
    dirs[:] = [d for d in dirs if d != '.bin']
    current = pathlib.Path(current)
    if 'package.json' not in files:
        continue
    parts = current.relative_to(modules).parts
    try:
        last = max(i for i, part in enumerate(parts) if part == 'node_modules')
        package_parts = parts[last + 1:]
    except ValueError:
        package_parts = parts
    if len(package_parts) != (2 if package_parts and package_parts[0].startswith('@') else 1):
        continue
    try:
        meta = json.loads((current / 'package.json').read_text())
        name, version = meta['name'], meta['version']
    except (KeyError, ValueError, OSError) as exc:
        errors.append({'path': str(current.relative_to(root)), 'error': str(exc)})
        continue
    notices = sorted(name for name in files if re.match(
        r'^(?:third[-_ ]?party[-_ ]?)?(?:license|licence|copying|notice|unlicense)',
        name, re.IGNORECASE,
    ))
    records.append({
        'name': name,
        'version': version,
        'declared_license': meta.get('license'),
        'license_notice_files': notices,
        'path': str(current.relative_to(root)),
    })
records.sort(key=lambda r: (r['name'].lower(), r['version'], r['path']))
counts = collections.Counter(str(r['declared_license']) for r in records)
bundle_inventory_path = root / 'server-input-inventory.json'
bundle_inventory = {'status': 'unavailable', 'reason': 'Build predates bundle input inventory; rebuild the gateway to collect it.'}
if bundle_inventory_path.is_file():
    try:
        bundle = json.loads(bundle_inventory_path.read_text())
        digest = hashlib.sha256()
        with (root / 'server.mjs').open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        checksum = digest.hexdigest()
        bundle_inventory = {
            'status': 'available',
            'server_sha256_matches': checksum == bundle['server_sha256'],
            'input_count': bundle['input_count'],
            'packages': bundle['packages'],
            'packages_without_license_notice': bundle['packages_without_license_notice'],
            'external_imports': bundle['external_imports'],
            'unresolved_inputs': bundle['unresolved_inputs'],
        }
    except (KeyError, TypeError, ValueError, OSError) as exc:
        bundle_inventory = {'status': 'invalid', 'reason': str(exc)}
result = {
    'sidecar': str(root),
    'revision': (root / 'FREELLMAPI_REVISION').read_text().strip() if (root / 'FREELLMAPI_REVISION').is_file() else None,
    'package_count': len(records),
    'declared_licenses': dict(sorted(counts.items())),
    'packages_without_local_license_notice': [r for r in records if not r['license_notice_files']],
    'packages': records,
    'read_errors': errors,
    'bundle_inventory': bundle_inventory,
    'limitations': 'Metadata and local filenames only. Nested packages inside examples excluded. License terms and native dependencies require separate review.',
}
print(json.dumps(result, ensure_ascii=False, indent=2))
