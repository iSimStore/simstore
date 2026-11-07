from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
from typing import Any

from version import SourceVersion, VERSION, VersionError, git, source_version, version_key, write_json


ARCHIVE = 'SimStore.app.tar.bz2'
METADATA = 'release.json'
INDEX = 'version.json'


@dataclass(frozen=True)
class Release:
    tag: str
    source: SourceVersion
    min_os: str
    size: int
    sha256: str

    def __post_init__(self) -> None:
        if self.source.dirty:
            raise VersionError('A dirty source tree cannot produce release metadata')
        if self.tag != 'latest':
            version_key(self.tag)
            if self.tag != self.source.version or self.source.build != 0:
                raise VersionError('A stable release must be built at its exact version tag')
        if not isinstance(self.min_os, str) or re.fullmatch(r'[1-9][0-9]*(?:\.[0-9]+){0,2}', self.min_os) is None:
            raise VersionError('Expected a minimum macOS version')
        if type(self.size) is not int or self.size <= 0:
            raise VersionError('Expected a positive archive size')
        if not isinstance(self.sha256, str) or re.fullmatch(r'[0-9a-f]{64}', self.sha256) is None:
            raise VersionError('Expected an archive SHA-256 digest')

    def to_dict(self) -> dict[str, object]:
        return {
            'tag': self.tag, 'version': self.source.version, 'build': self.source.build,
            'minOS': self.min_os, 'revision': self.source.revision, 'time': self.source.time,
            'size': self.size, 'sha256': self.sha256,
        }

    @classmethod
    def read(cls, path: Path) -> Release:
        try:
            item = json.loads(path.read_text(encoding='utf-8'))
            source = SourceVersion(item['version'], item['build'], item['revision'], item['time'], False)
            return cls(item['tag'], source, item['minOS'], item['size'], item['sha256'])
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise VersionError(f'Invalid release metadata: {path}') from error


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def package(app: Path, source: Path, directory: Path, tag: str) -> Release:
    app = app.resolve()
    if app.name != 'SimStore.app' or not app.is_dir():
        raise VersionError('Expected an existing SimStore.app bundle')
    if directory.resolve().is_relative_to(app):
        raise VersionError('The archive must be outside the application bundle')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    actual = SourceVersion.from_plist(info)
    if actual != source_version(source):
        raise VersionError('The application does not match the current Git source; rebuild it first')
    if actual.dirty:
        raise VersionError('Commit the source changes and rebuild before packaging a release')
    if tag != 'latest':
        try:
            git(source, 'merge-base', '--is-ancestor', actual.revision, 'refs/remotes/origin/main')
        except VersionError as error:
            raise VersionError('A stable release must belong to origin/main; fetch main before packaging') from error
    if info.get('CFBundlePackageType') != 'APPL' or not info.get('CFBundleIdentifier'):
        raise VersionError('Expected a macOS application bundle')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise VersionError('Invalid bundle executable name')
    if not (app / 'Contents/MacOS' / executable).is_file():
        raise VersionError('Missing bundle executable')
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / ARCHIVE
    with tarfile.open(archive, 'w:bz2') as file:
        file.add(app, arcname=app.name)
    release = Release(tag, actual, info.get('LSMinimumSystemVersion'), archive.stat().st_size, digest(archive))
    write_json(directory / METADATA, release.to_dict())
    return release


def assemble_index(nightly: Release, stable: list[Release]) -> dict[str, object]:
    if nightly.tag != 'latest' or any(item.tag == 'latest' for item in stable):
        raise VersionError('Expected one nightly followed by stable releases')
    if len({item.tag for item in stable}) != len(stable):
        raise VersionError('Duplicate stable release tag')
    ordered = sorted(stable, key=lambda item: item.source.order, reverse=True)
    return {'versions': [item.to_dict() for item in [nightly, *ordered]]}


def release_notes(repo: str, tag: str) -> str:
    command = (
        f'curl -fL https://github.com/{repo}/releases/download/{tag}/{ARCHIVE} '
        f'-o /tmp/{ARCHIVE} && rm -rf ~/Applications/SimStore.app && '
        f'mkdir -p ~/Applications && tar -xjf /tmp/{ARCHIVE} -C ~/Applications && '
        f'rm -f /tmp/{ARCHIVE}'
    )
    return (
        'If SimStore is already installed, choose SimStore → Check for Updates… in the app.\n\n'
        'To install SimStore for the first time or reinstall it manually, run this command in Terminal:\n\n'
        f'```sh\n{command}\n```\n\nDo NOT download by clicking the link below.\n'
    )


class GitHub:
    def __init__(self, repo: str) -> None:
        if re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) is None:
            raise VersionError('Expected an owner/repository name')
        self.repo = repo

    def run(self, *arguments: str) -> str:
        result = subprocess.run(['gh', *arguments], capture_output=True, text=True)
        if result.returncode:
            raise VersionError(result.stderr.strip() or 'GitHub command failed')
        return result.stdout

    def release(self, *arguments: str) -> str:
        return self.run('release', *arguments, '--repo', self.repo)

    def releases(self) -> list[dict[str, Any]]:
        pages = json.loads(self.run('api', '--paginate', '--slurp', f'repos/{self.repo}/releases?per_page=100'))
        return [item for page in pages for item in page]

    def metadata(self, listing: dict[str, Any], directory: Path) -> Release:
        tag = listing['tag_name']
        if not isinstance(tag, str) or (tag != 'latest' and VERSION.fullmatch(tag) is None):
            raise VersionError('Invalid release tag')
        if not any(asset['name'] == METADATA for asset in listing['assets']):
            raise VersionError(f'Release {tag} has no {METADATA}; publish its metadata first')
        path = directory / f'{tag}.json'
        self.release('download', tag, '--pattern', METADATA, '--output', str(path))
        record = Release.read(path)
        if record.tag != tag:
            raise VersionError(f'Metadata does not match release {tag}')
        return record

    def upload(self, tag: str, *files: Path) -> None:
        self.release('upload', tag, *(str(file) for file in files), '--clobber')


def stable_records(github: GitHub, listings: list[dict[str, Any]], directory: Path) -> list[Release]:
    return [
        github.metadata(item, directory) for item in listings
        if not item['draft'] and not item['prerelease'] and VERSION.fullmatch(item['tag_name'])
    ]


def refresh_index(github: GitHub, directory: Path, upload: bool) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory, prefix='index-') as temporary:
        work = Path(temporary)
        listings = github.releases()
        nightly = next((item for item in listings if item['tag_name'] == 'latest' and not item['draft']), None)
        if nightly is None:
            raise VersionError('Publish a nightly before generating the version index')
        index = assemble_index(github.metadata(nightly, work), stable_records(github, listings, work))
        write_json(directory / INDEX, index)
        if upload:
            github.upload('latest', directory / INDEX)


def publish(github: GitHub, directory: Path) -> None:
    record = Release.read(directory / METADATA)
    archive = directory / ARCHIVE
    if archive.stat().st_size != record.size or digest(archive) != record.sha256:
        raise VersionError('The archive does not match release.json')
    listings = github.releases()
    existing = next((item for item in listings if item['tag_name'] == record.tag), None)
    with tempfile.TemporaryDirectory(dir=directory, prefix='publish-') as temporary:
        work = Path(temporary)
        notes = work / 'notes.md'
        notes.write_text(release_notes(github.repo, record.tag), encoding='utf-8')
        if record.tag != 'latest':
            if existing is not None and not existing['draft']:
                raise VersionError(f'Stable release {record.tag} is already published; its assets are immutable')
            if existing is None:
                github.release(
                    'create', record.tag, str(archive), str(directory / METADATA),
                    '--verify-tag', '--draft', '--title', record.tag, '--notes-file', str(notes),
                )
            else:
                github.upload(record.tag, archive, directory / METADATA)
                github.release('edit', record.tag, '--prerelease=false', '--title', record.tag, '--notes-file', str(notes))
            return

        stable = stable_records(github, listings, work)
        if existing is not None and any(asset['name'] == METADATA for asset in existing['assets']):
            previous = github.metadata(existing, work)
            if previous.source.order > record.source.order:
                print('Keeping the newer published nightly.')
                return
            if previous.source.order == record.source.order and previous.source.revision != record.source.revision:
                raise VersionError('Different commits have the same nightly version')
        write_json(directory / INDEX, assemble_index(record, stable))
        if existing is None:
            github.release(
                'create', 'latest', str(archive), str(directory / METADATA), '--target', record.source.revision,
                '--prerelease', '--latest=false', '--title', 'Nightly build', '--notes-file', str(notes),
            )
        else:
            github.run(
                'api', '--method', 'PATCH', f'repos/{github.repo}/git/refs/tags/latest',
                '-f', f'sha={record.source.revision}', '-F', 'force=true',
            )
            github.upload('latest', archive, directory / METADATA)
            github.release(
                'edit', 'latest', '--prerelease', '--latest=false', '--draft=false',
                '--title', 'Nightly build', '--notes-file', str(notes),
            )
        github.upload('latest', directory / INDEX)


def main() -> int:
    parser = argparse.ArgumentParser(description='Package SimStore releases and maintain the update index.')
    subparsers = parser.add_subparsers(dest='command', required=True)
    packaging = subparsers.add_parser('package')
    packaging.add_argument('--app', type=Path, required=True)
    packaging.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    packaging.add_argument('--tag', required=True)
    packaging.add_argument('--directory', type=Path, default=Path('build'))
    for command in ['publish', 'index']:
        child = subparsers.add_parser(command)
        child.add_argument('--repo', required=True)
        child.add_argument('--directory', type=Path, default=Path('build'))
        if command == 'index':
            child.add_argument('--upload', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'package':
            record = package(args.app, args.source, args.directory, args.tag)
            print(json.dumps(record.to_dict(), ensure_ascii=False))
        elif args.command == 'publish':
            publish(GitHub(args.repo), args.directory)
        else:
            refresh_index(GitHub(args.repo), args.directory, args.upload)
    except (VersionError, OSError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        print(f'Release error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
