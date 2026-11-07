from __future__ import annotations

import json
from pathlib import Path
import plistlib
import sys
import tarfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))

from release_fixtures import Repository, workspace
from release import ARCHIVE, INDEX, METADATA, GitHub, Release, assemble_index, digest, package, publish, refresh_index, release_notes
from version import SourceVersion, VersionError, source_version, write_json


def record(tag: str = 'latest', version: str = '0.1.0', build: int = 1, revision: str = 'a' * 40) -> Release:
    return Release(tag, SourceVersion(version, build, revision, 1700000000, False), '14.0', 7, '0' * 64)


def listing(item: Release, draft: bool = False, prerelease: bool = False) -> dict[str, object]:
    return {'tag_name': item.tag, 'draft': draft, 'prerelease': prerelease, 'assets': [{'name': METADATA}]}


class FakeGitHub(GitHub):
    def __init__(self, records: list[Release], listings: list[dict[str, object]] | None = None) -> None:
        super().__init__('example/simstore')
        self.records = {item.tag: item for item in records}
        self.listings = listings if listings is not None else [listing(item) for item in records]
        self.calls: list[tuple[str, ...]] = []

    def run(self, *arguments: str) -> str:
        self.calls.append(arguments)
        if arguments[:3] == ('api', '--paginate', '--slurp'):
            return json.dumps([self.listings])
        if arguments[:2] == ('release', 'download'):
            path = Path(arguments[arguments.index('--output') + 1])
            write_json(path, self.records[arguments[2]].to_dict())
        return ''

    @property
    def mutations(self) -> list[tuple[str, ...]]:
        return [call for call in self.calls if call[:2] in [('release', 'create'), ('release', 'edit'), ('release', 'upload')] or '--method' in call]


class ReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = workspace(self)

    def artifacts(self, item: Release) -> Path:
        directory = self.work / 'artifacts'
        directory.mkdir()
        archive = directory / ARCHIVE
        archive.write_bytes(b'Archive')
        actual = Release(item.tag, item.source, item.min_os, archive.stat().st_size, digest(archive))
        write_json(directory / METADATA, actual.to_dict())
        return directory

    def test_package_uses_actual_bundle_metadata_and_hashes_the_archive(self) -> None:
        repo = Repository(self.work / 'source')
        app = repo.root / 'build/SimStore.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/SimStore').write_bytes(b'Executable fixture')
        info = {
            'CFBundlePackageType': 'APPL', 'CFBundleIdentifier': 'org.example.SimStore',
            'CFBundleExecutable': 'SimStore', 'LSMinimumSystemVersion': '14.2',
            **source_version(repo.root).plist_values(),
        }
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        output = repo.root / 'build/artifacts'
        item = package(app, repo.root, output, '0.1.0')
        self.assertEqual(item.min_os, '14.2')
        self.assertEqual(item.size, (output / ARCHIVE).stat().st_size)
        self.assertEqual(item.sha256, digest(output / ARCHIVE))
        self.assertEqual(Release.read(output / METADATA), item)
        with tarfile.open(output / ARCHIVE) as archive:
            self.assertTrue(all(name == 'SimStore.app' or name.startswith('SimStore.app/') for name in archive.getnames()))
            self.assertEqual(plistlib.loads(archive.extractfile('SimStore.app/Contents/Info.plist').read()), info)
        repo.commit()
        with self.assertRaisesRegex(VersionError, 'rebuild'):
            package(app, repo.root, output, 'latest')
        info.update(source_version(repo.root).plist_values())
        (repo.root / 'untracked.txt').write_text('dirty', encoding='utf-8')
        info.update(source_version(repo.root).plist_values())
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(VersionError, 'Commit the source'):
            package(app, repo.root, output, 'latest')

    def test_index_retains_old_os_releases_and_sorts_versions_numerically(self) -> None:
        nightly = record()
        older = record('0.1.9', '0.1.9', 0)
        newer = Release('0.1.10', SourceVersion('0.1.10', 0, 'b' * 40, 1700000001, False), '15.0', 7, '1' * 64)
        result = assemble_index(nightly, [older, newer])
        self.assertEqual([item['tag'] for item in result['versions']], ['latest', '0.1.10', '0.1.9'])
        self.assertEqual(result['versions'][-1]['minOS'], '14.0')
        with self.assertRaisesRegex(VersionError, 'Duplicate'):
            assemble_index(nightly, [older, older])

    def test_stable_packaging_requires_a_main_commit_and_exact_tag(self) -> None:
        repo = Repository(self.work / 'source')
        original_main = repo.git('rev-parse', 'HEAD')
        repo.commit()
        repo.git('tag', '-a', '0.2.0', '-m', 'Release 0.2.0')
        app = repo.root / 'build/SimStore.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/SimStore').write_bytes(b'Executable fixture')
        info = {
            'CFBundlePackageType': 'APPL', 'CFBundleIdentifier': 'org.example.SimStore',
            'CFBundleExecutable': 'SimStore', 'LSMinimumSystemVersion': '14.0',
            **source_version(repo.root).plist_values(),
        }
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        repo.git('update-ref', 'refs/remotes/origin/main', original_main)
        with self.assertRaisesRegex(VersionError, 'origin/main'):
            package(app, repo.root, repo.root / 'build/artifacts', '0.2.0')
        repo.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        with self.assertRaisesRegex(VersionError, 'exact version tag'):
            package(app, repo.root, repo.root / 'build/artifacts', '0.1.0')

    def test_index_ignores_drafts_and_prereleases_and_is_read_only_by_default(self) -> None:
        nightly = record()
        stable = record('0.1.0', '0.1.0', 0)
        draft = record('0.2.0', '0.2.0', 0)
        preview = record('0.3.0', '0.3.0', 0)
        api = FakeGitHub([nightly, stable], [listing(nightly, prerelease=True), listing(stable), listing(draft, draft=True), listing(preview, prerelease=True)])
        refresh_index(api, self.work, False)
        result = json.loads((self.work / INDEX).read_text())
        self.assertEqual([item['tag'] for item in result['versions']], ['latest', '0.1.0'])
        self.assertEqual(api.mutations, [])

    def test_publishing_a_stable_only_refreshes_the_index(self) -> None:
        nightly = record()
        stable = record('0.1.0', '0.1.0', 0)
        api = FakeGitHub([nightly, stable])
        refresh_index(api, self.work, True)
        self.assertEqual(len(api.mutations), 1)
        self.assertEqual(api.mutations[0][:3], ('release', 'upload', 'latest'))
        self.assertEqual(Path(api.mutations[0][3]).name, INDEX)

    def test_nightly_publication_marks_prerelease_and_uploads_index_last(self) -> None:
        api = FakeGitHub([])
        directory = self.artifacts(record())
        publish(api, directory)
        create = next(call for call in api.mutations if call[:2] == ('release', 'create'))
        self.assertIn('--prerelease', create)
        self.assertIn('--latest=false', create)
        self.assertEqual(create[create.index('--target') + 1], 'a' * 40)
        self.assertEqual(Path(api.mutations[-1][3]).name, INDEX)
        self.assertEqual(json.loads((directory / INDEX).read_text())['versions'][0]['tag'], 'latest')

    def test_existing_nightly_without_metadata_is_initialized(self) -> None:
        api = FakeGitHub([], [{'tag_name': 'latest', 'draft': False, 'prerelease': False, 'assets': []}])
        publish(api, self.artifacts(record()))
        self.assertIn('--method', api.mutations[0])
        edit = next(call for call in api.mutations if call[:2] == ('release', 'edit'))
        self.assertIn('--prerelease', edit)
        self.assertEqual(Path(api.mutations[-1][3]).name, INDEX)

    def test_a_new_base_version_advances_even_when_the_counter_resets(self) -> None:
        api = FakeGitHub([record(build=99)])
        directory = self.artifacts(record(version='0.1.1', build=0))
        publish(api, directory)
        result = json.loads((directory / INDEX).read_text())['versions'][0]
        self.assertEqual((result['version'], result['build']), ('0.1.1', 0))
        self.assertEqual(Path(api.mutations[-1][3]).name, INDEX)

    def test_stale_nightly_cannot_overwrite_a_newer_one(self) -> None:
        api = FakeGitHub([record(build=3)])
        directory = self.artifacts(record(build=2))
        publish(api, directory)
        self.assertEqual(api.mutations, [])
        self.assertFalse((directory / INDEX).exists())
        conflict = FakeGitHub([record(build=2, revision='b' * 40)])
        with self.assertRaisesRegex(VersionError, 'Different commits'):
            publish(conflict, directory)
        self.assertEqual(conflict.mutations, [])

    def test_stable_is_a_draft_and_published_assets_cannot_be_overwritten(self) -> None:
        stable = record('0.1.0', '0.1.0', 0)
        directory = self.artifacts(stable)
        api = FakeGitHub([])
        publish(api, directory)
        self.assertEqual(len(api.mutations), 1)
        self.assertIn('--draft', api.mutations[0])
        self.assertIn('--verify-tag', api.mutations[0])
        published = FakeGitHub([stable])
        with self.assertRaisesRegex(VersionError, 'immutable'):
            publish(published, directory)
        self.assertEqual(published.mutations, [])

    def test_bad_archive_or_missing_stable_metadata_prevents_publication(self) -> None:
        directory = self.artifacts(record())
        archive = directory / ARCHIVE
        original = archive.read_bytes()
        archive.write_bytes(b'Changed')
        api = FakeGitHub([])
        with self.assertRaisesRegex(VersionError, 'does not match'):
            publish(api, directory)
        self.assertEqual(api.calls, [])
        archive.write_bytes(original)
        missing = FakeGitHub([], [{'tag_name': '0.1.0', 'draft': False, 'prerelease': False, 'assets': []}])
        with self.assertRaisesRegex(VersionError, 'has no release.json'):
            publish(missing, directory)
        self.assertEqual(missing.mutations, [])

    def test_invalid_release_fields_and_installation_instructions(self) -> None:
        valid = record().to_dict()
        for field, value in [('build', True), ('time', -1), ('version', '01.0.0'), ('size', 0), ('sha256', 'bad'), ('revision', 'main'), ('minOS', '14.x'), ('tag', '0.2.0')]:
            with self.subTest(field=field, value=value), self.assertRaises(VersionError):
                path = self.work / METADATA
                write_json(path, {**valid, field: value})
                Release.read(path)
        for tag in ('latest', '0.1.0'):
            with self.subTest(tag=tag):
                notes = release_notes('example/simstore', tag)
                command = notes.split('```sh\n')[1].split('\n```')[0]
                self.assertIn('SimStore → Check for Updates…', notes)
                self.assertIn('first time or reinstall it manually', notes)
                self.assertNotIn('\n', command)
                self.assertIn(f'/releases/download/{tag}/{ARCHIVE}', command)
                self.assertTrue(command.startswith('curl -fL '))
                self.assertTrue(command.endswith(f'&& rm -f /tmp/{ARCHIVE}'))
                self.assertTrue(notes.endswith('Do NOT download by clicking the link below.\n'))


if __name__ == '__main__':
    unittest.main()
