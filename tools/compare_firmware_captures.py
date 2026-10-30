#!/usr/bin/env python3
"""Verify and compare existing macOS/Windows firmware adaptation ZIPs offline.

No extraction or execution. Only firmware labels and static component metadata
leave the reader; activity, private identifiers and runtime responses do not.
Byte equality is not a claim of functional compatibility.
"""
import argparse
import hashlib
import json
from pathlib import PurePosixPath
import re
import stat
import sys
import zipfile

MAX_ENTRY = 256 * 1024 * 1024
MAX_TOTAL = 1024 * 1024 * 1024
MAX_JSON = 2 * 1024 * 1024


class CaptureError(ValueError):
    pass


def require(value, code):
    if not value:
        raise CaptureError(code)


def safe_path(value):
    require(isinstance(value, str) and 0 < len(value) < 512, 'invalid_archive_path')
    require(not value.startswith('/') and '\\' not in value and
            all(ord(c) >= 32 and ord(c) != 127 for c in value), 'invalid_archive_path')
    require(all(p not in ('', '.', '..') for p in value.rstrip('/').split('/')), 'invalid_archive_path')
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def size(value):
    # Swift's manifest historically serializes sizes as decimal strings.
    require(type(value) is int or isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]{0,9}', value), 'invalid_size')
    result = int(value)
    require(0 <= result <= MAX_ENTRY, 'entry_size_limit')
    return result


def digest(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'invalid_digest')
    return value


def public_label(value):
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9._/ -]{1,256}', value) else 'not_assessed'


def public_source(value, backup):
    require(isinstance(value, str) and len(value) < 1024, 'invalid_component_source')
    for path in value.split(' | '):
        require(re.fullmatch(r'/[A-Za-z0-9_./+-]+', path) and '..' not in path.split('/'), 'invalid_component_source')
        allowed = ('/data/zte-imei-screen-ru/backup/',) if backup else ('/bin/', '/sbin/', '/lib/', '/usr/', '/etc/init.d/', '/firmware/image/')
        require(path.startswith(allowed), 'unexpected_component_source')
    return value


def read_capture(path):
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            require(0 < len(infos) <= 2048, 'entry_count_limit')
            names = {}
            for info in infos:
                name = safe_path(info.filename)
                require(name not in names, 'duplicate_zip_entry')
                mode = info.external_attr >> 16
                require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'non_regular_zip_entry')
                require(not info.flag_bits & 1, 'encrypted_zip_entry')
                require(0 <= info.file_size <= MAX_ENTRY, 'entry_size_limit')
                names[name] = info
            require(sum(i.file_size for i in infos) <= MAX_TOTAL, 'archive_size_limit')
            candidates = [n for n in names if PurePosixPath(n).name == 'manifest.json' and len(PurePosixPath(n).parts) <= 2 and not n.startswith(('research/', 'radio/'))]
            require(len(candidates) == 1, 'ambiguous_manifest')
            manifest_name = candidates[0]
            prefix = manifest_name.removesuffix('manifest.json')
            require(all(n.startswith(prefix) for n in names), 'unexpected_archive_root')

            def json_file(name):
                require(name in names and names[name].file_size <= MAX_JSON, 'missing_or_large_metadata')
                return json.loads(archive.read(name), object_pairs_hook=unique_object)

            manifest = json_file(manifest_name)
            windows = manifest.get('schemaVersion') == 2 and 'payloads' in manifest
            require(windows or manifest.get('schema') == 1 and 'files' in manifest, 'unsupported_capture_schema')
            payloads = manifest['payloads' if windows else 'files']
            require(isinstance(payloads, list) and len(payloads) <= 2048, 'invalid_manifest')
            verified = {}
            for record in payloads:
                relative = safe_path(record['path'])
                name = prefix + relative
                require(name in names and not names[name].is_dir() and relative not in verified, 'missing_or_duplicate_payload')
                expected_size, expected_hash = size(record['bytes']), digest(record['sha256'])
                require(names[name].file_size == expected_size, 'payload_size_mismatch')
                actual = hashlib.sha256()
                read = 0
                with archive.open(name) as stream:
                    while block := stream.read(1024 * 1024):
                        read += len(block)
                        require(read <= expected_size, 'payload_size_mismatch')
                        actual.update(block)
                require(read == expected_size and actual.hexdigest() == expected_hash, 'payload_hash_mismatch')
                verified[relative] = (expected_size, expected_hash)
            require({n for n, info in names.items() if not info.is_dir()} ==
                    {prefix + n for n in verified} | {manifest_name}, 'unlisted_payload')
            metadata = manifest if windows else json_file(prefix + 'metadata.json')
            if windows:
                facts = metadata['factsBefore']
                rows = metadata['files']
            else:
                facts = metadata['before']['facts']
                rows = [{'id': o['id'], 'path': metadata['sources'][o['id']],
                         'archivePath': 'files/' + o['id'], 'observation': o,
                         'captureStatus': 'verified' if 'files/' + o['id'] in verified else
                        ('over_limit' if any(x.get('id') == o['id'] and x.get('reason') == 'over_limit'
                                             for x in metadata.get('omissions', [])) else 'unavailable')}
                        for o in metadata['before']['files']]
            components = {}
            for row in rows:
                component = row['id']
                require(isinstance(component, str) and re.fullmatch('[a-z][a-z0-9_]{0,63}', component), 'invalid_component_id')
                require(component not in components, 'duplicate_component_id')
                backup = component.startswith('original_')
                source = public_source(row['path'], backup)
                observation = row['observation']
                require(observation['id'] == component, 'component_id_mismatch')
                state = observation.get('state', observation.get('status'))
                require(state in {'present', 'missing', 'not_assessed', 'symlink', 'not_regular', 'unreadable', 'empty', 'unsafe_target', 'not_elf', 'ambiguous'}, 'invalid_component_state')
                output = {'kind': 'backup' if backup else 'current', 'source': source, 'state': state, 'captured': False}
                relative = safe_path(row['archivePath'])
                if row['captureStatus'] == 'verified':
                    require(state == 'present' and relative in verified, 'missing_component_payload')
                    pair = (size(observation['bytes']), digest(observation['sha256']))
                    require(pair == verified[relative], 'component_observation_mismatch')
                    output.update(captured=True, bytes=pair[0], sha256=pair[1])
                else:
                    require(relative not in verified, 'unverified_component_payload')
                    output['state'] = 'over_limit' if row['captureStatus'] == 'over_limit' else state
                components[component] = output
            return {'integrity': 'verified', 'complete': metadata.get('complete') is True,
                    'firmware': public_label(facts.get('firmware')), 'inner': public_label(facts.get('inner')),
                    'application_version': public_label(metadata.get('applicationVersion')),
                    'payloads_verified': len(verified), 'components': components}
    except CaptureError:
        raise
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, EOFError, RuntimeError) as error:
        raise CaptureError('unreadable_or_malformed_capture') from error


def compare(paths):
    captures = [read_capture(path) for path in paths]
    require(len(captures) >= 1, 'capture_required')
    rows = []
    counts = {'same': 0, 'different': 0, 'not_comparable': 0}
    for component in sorted(set().union(*(c['components'] for c in captures))):
        observations = [c['components'].get(component, {'state': 'not_in_capture', 'captured': False}) for c in captures]
        if len(captures) < 2 or not all(o['captured'] for o in observations):
            status = 'not_comparable'
        else:
            status = 'same' if len({(o['source'], o['bytes'], o['sha256']) for o in observations}) == 1 else 'different'
        counts[status] += 1
        rows.append({'id': component, 'comparison': status, 'observations': observations})
    return {'schema': 1, 'functional_compatibility': 'not_tested',
            'captures': [{k: v for k, v in c.items() if k != 'components'} for c in captures],
            'counts': counts, 'components': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', nargs='+', help='Existing firmware adaptation ZIPs, in comparison-column order')
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.captures), ensure_ascii=False, indent=2))
    except CaptureError as error:
        print('Firmware capture comparison failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
