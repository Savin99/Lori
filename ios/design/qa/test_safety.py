import json
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


safe = load('safe-container')
installer = load('install-qa')


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'sample.wav').write_bytes(b'synthetic')
        self.container = self.root / 'container'
        self.destination = self.container / 'Documents/Lori/Workspace'
        self.destination.mkdir(parents=True)
        (self.destination / 'personal.wav').write_bytes(b'keep')

    def test_add_keeps_existing_audio(self):
        safe.copy_new(self.source, self.container, 'Documents/Lori/Workspace')
        self.assertEqual((self.destination / 'personal.wav').read_bytes(), b'keep')
        self.assertEqual((self.destination / 'sample.wav').read_bytes(), b'synthetic')

    def test_share_inbox_is_append_only_fixture(self):
        inbox = self.container / 'Documents/Inbox'
        inbox.mkdir(parents=True)
        (inbox / 'sample.wav').write_bytes(b'shared earlier')
        with self.assertRaises(FileExistsError):
            safe.copy_new(self.source, self.container, 'Documents/Inbox')
        self.assertEqual((inbox / 'sample.wav').read_bytes(), b'shared earlier')
        (inbox / 'sample.wav').unlink()
        safe.copy_new(self.source, self.container, 'Documents/Inbox')
        self.assertEqual((inbox / 'sample.wav').read_bytes(), b'synthetic')

    def test_existing_file_refused_without_any_overwrite(self):
        (self.destination / 'sample.wav').write_bytes(b'original')
        with self.assertRaises(FileExistsError):
            safe.copy_new(self.source, self.container, 'Documents/Lori/Workspace')
        self.assertEqual((self.destination / 'sample.wav').read_bytes(), b'original')

    def test_parent_root_and_absolute_paths_refused(self):
        for path in ['.', 'Documents', '../outside', '/tmp', 'Documents/Lori/Workspace/../../x']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                safe.copy_new(self.source, self.container, path)

    def test_destination_symlink_refused(self):
        (self.destination / 'link').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            safe.copy_new(self.source, self.container, 'Documents/Lori/Workspace/link')
        self.assertFalse((self.root / 'sample.wav').exists())

    def test_source_symlink_refused(self):
        (self.source / 'link').symlink_to(self.destination / 'personal.wav')
        with self.assertRaises(ValueError):
            safe.copy_new(self.source, self.container, 'Documents/Lori/Workspace')

    def test_booted_alias_refused_without_invoking_tools(self):
        with patch.object(safe.subprocess, 'check_output') as tool:
            with self.assertRaises(ValueError):
                safe.container_for('booted')
            tool.assert_not_called()

    def test_personal_container_metadata_is_refused(self):
        device = '3FA136B9-4BDC-42FA-82D4-32F309A33BFC'
        path = self.root / 'Library/Developer/CoreSimulator/Devices' / device / 'data/Containers/Data/Application/container'
        path.mkdir(parents=True)
        (path / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(
            plistlib.dumps({'MCMMetadataIdentifier': 'ru.ilyaqa.lori.local'}))
        listing = json.dumps({'devices': {'iOS': [{'udid': device}]}}).encode()
        with patch.object(safe.Path, 'home', return_value=self.root), patch.object(
                safe.subprocess, 'check_output', side_effect=[listing, str(path)]):
            with self.assertRaisesRegex(ValueError, 'non-QA'):
                safe.container_for(device)

    def test_personal_app_cannot_be_installed_by_qa_tool(self):
        (self.root / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'ru.ilyaqa.lori.local', 'CFBundleDisplayName': 'Lori'}))
        with patch.object(installer.subprocess, 'run') as tool:
            with self.assertRaises(ValueError):
                installer.install(self.root, '3FA136B9-4BDC-42FA-82D4-32F309A33BFC')
            tool.assert_not_called()

    def test_qa_install_never_uninstalls_or_copies_data(self):
        (self.root / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': installer.QA_BUNDLE, 'CFBundleDisplayName': 'Lori QA'}))
        with patch.object(installer.subprocess, 'run') as tool:
            installer.install(self.root, '3FA136B9-4BDC-42FA-82D4-32F309A33BFC')
            self.assertEqual(tool.call_count, 1)
            self.assertEqual(tool.call_args.args[0][1:5], ['devicectl', 'device', 'install', 'app'])


if __name__ == '__main__':
    unittest.main()
