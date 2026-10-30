"""Offline regression tests for deployment portability; never touch production."""
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch
import deploy

class DeploymentPortabilityTests(unittest.TestCase):
    def test_explicit_environment_credential_on_linux(self):
        with patch.dict(os.environ, {'DOKPLOY_API_KEY': 'test-value'}, clear=True):
            self.assertEqual(deploy.api_key(), 'test-value')

    def test_explicit_private_credential_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'key'
            path.write_text('test-file-value\n')
            path.chmod(0o600)
            with patch.dict(os.environ, {'DOKPLOY_API_KEY_FILE': str(path)}, clear=True):
                self.assertEqual(deploy.api_key(), 'test-file-value')

    def test_insecure_credential_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'key'
            path.write_text('not-a-real-secret')
            path.chmod(0o644)
            with patch.dict(os.environ, {'DOKPLOY_API_KEY_FILE': str(path)}, clear=True):
                with self.assertRaisesRegex(RuntimeError, 'private file'):
                    deploy.api_key()

    def test_mac_keychain_fallback_is_preserved(self):
        with patch.dict(os.environ, {}, clear=True), patch('sys.platform', 'darwin'), patch.object(deploy.subprocess, 'check_output', return_value='test-keychain\n') as command:
            self.assertEqual(deploy.api_key(), 'test-keychain')
            self.assertEqual(command.call_args.args[0][0], 'security')

    def test_missing_linux_credential_fails_closed(self):
        with patch.dict(os.environ, {}, clear=True), patch('sys.platform', 'linux'):
            with self.assertRaisesRegex(RuntimeError, 'Set DOKPLOY'):
                deploy.api_key()

    def test_backup_failure_prevents_build_and_deployment(self):
        with patch('sys.argv', ['deploy.py']), patch.object(deploy, 'run', side_effect=RuntimeError('backup failed')) as run:
            with self.assertRaisesRegex(RuntimeError, 'backup failed'):
                deploy.main()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(pathlib.Path(run.call_args.args[0][1]).name, 'backup.py')

    def test_outdated_card_pictures_stop_a_local_build(self):
        steps = [None, RuntimeError('out of date')]
        with patch('sys.argv', ['deploy.py']), patch.object(deploy, 'run', side_effect=steps) as run:
            with self.assertRaisesRegex(RuntimeError, 'out of date'):
                deploy.main()
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0][1:], ['tool/optimize-sprites.py', '--check'])

    def test_a_ci_build_is_not_checked_again(self):
        steps = [None, RuntimeError('stop here')]
        with patch('sys.argv', ['deploy.py', '--skip-build']), patch.object(deploy, 'run', side_effect=steps) as run:
            with self.assertRaisesRegex(RuntimeError, 'stop here'):
                deploy.main()
        self.assertEqual(run.call_args.args[0], ['node', 'tool/version-web.mjs'])

    def test_local_transport_requires_explicit_opt_in(self):
        config = {'sshKey': '~/.ssh/example', 'sshHost': 'homebox'}
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(deploy.host_transport(config)[0], 'ssh')
        with patch.dict(os.environ, {'THEATER_DEPLOY_LOCAL': '1'}, clear=True):
            self.assertEqual(deploy.host_transport(config), ['sh', '-c'])

    def test_dokploy_transport_requires_explicit_opt_in(self):
        with patch.dict(os.environ, {'THEATER_DEPLOY_TRANSPORT': 'dokploy'}, clear=True):
            command = deploy.host_transport({})
            self.assertEqual(command[0], 'node')
            self.assertEqual(pathlib.Path(command[1]).name, 'dokploy-transport.mjs')
        with patch.dict(os.environ, {'THEATER_DEPLOY_TRANSPORT': 'unknown'}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'must be ssh or dokploy'):
                deploy.host_transport({})

if __name__ == '__main__':
    unittest.main()
