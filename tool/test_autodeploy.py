"""Offline tests for the HomeBox auto-deployer; never touch GitHub, Dokploy or production."""
import contextlib
import datetime
import hashlib
import io
import json
import os
import pathlib
import stat
import tempfile
import unittest
import zipfile
from unittest.mock import patch
import autodeploy

SHA = 'a' * 40
OTHER = 'b' * 40
PREVIOUS = '0123456789abcdef0123'
PREVIOUS_COMPOSE = f'services:\n  theater:\n    image: theater-app:{PREVIOUS}\n    pull_policy: never\n'
FUTURE = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
PAST = '2020-01-01T00:00:00Z'


def push_run(**overrides):
    run = {'id': 100, 'run_attempt': 1, 'event': 'push', 'head_branch': 'main', 'head_sha': SHA, 'status': 'completed', 'conclusion': 'success',
           'path': '.github/workflows/checks.yml', 'html_url': 'https://github.com/LoggeL/TheaterApp/actions/runs/100',
           'head_repository': {'id': autodeploy.REPO_ID, 'full_name': autodeploy.REPO}, 'repository': {'id': autodeploy.REPO_ID}}
    run.update(overrides)
    return run


def jobs(verify='success', play='failure', verify_id=1):
    return [{'id': verify_id, 'name': 'verify', 'status': 'completed', 'conclusion': verify},
            {'id': 2, 'name': 'Submit closed Google Play release', 'status': 'completed', 'conclusion': play}]


def web_zip(entries=None):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as bundle:
        for name, data in (entries or {
            'index.html': '<html></html>', 'main.dart.js': 'main', 'flutter_bootstrap.js': 'boot',
            'firebase-web-config.js': 'projectId: "theater-app-6fa5d"', 'assets/a.txt': 'asset'}).items():
            bundle.writestr(name, data)
    return buffer.getvalue()


def artifact(data, **overrides):
    value = {'id': 7, 'name': 'theater-web', 'expired': False, 'expires_at': FUTURE, 'size_in_bytes': len(data),
             'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
             'workflow_run': {'id': 100, 'head_sha': SHA, 'head_branch': 'main', 'repository_id': autodeploy.REPO_ID,
                              'head_repository_id': autodeploy.REPO_ID}}
    value.update(overrides)
    return value


class FakeGitHub:
    def __init__(self, shas=(SHA,), runs=None, job_list=None, artifacts=None, data=None, location='https://storage.example/zip'):
        self.shas, self.data, self.location = list(shas), data if data is not None else web_zip(), location
        self.run_list = [push_run()] if runs is None else runs
        self.job_list = jobs() if job_list is None else job_list
        self.artifact_list = [artifact(self.data)] if artifacts is None else artifacts
        self.calls = []

    def main_sha(self):
        self.calls.append('main')
        return self.shas.pop(0) if len(self.shas) > 1 else self.shas[0]

    def runs(self, sha):
        self.calls.append('runs')
        return self.run_list

    def jobs(self, run_id):
        return self.job_list

    def artifacts(self, run_id):
        return self.artifact_list

    def artifact_location(self, artifact_id):
        return self.location

    def open_download(self, url):
        return io.BytesIO(self.data)


class FakeDeploy(autodeploy.AutoDeploy):
    """Real selection, download and extraction; git, deploy.py, Dokploy, docker, healthz and notifications are recorded."""
    release = 'f' * 20
    healthy = True
    rollback_healthy = True
    compose_file = PREVIOUS_COMPOSE
    free = 500 * 1024 ** 3

    def __init__(self, *args, **kwargs):
        super().__init__(*args, out=lambda text: None, **kwargs)
        self.events, self.messages, self.removed = [], [], []
        self.images = []
        self.sleep = lambda seconds: None
        self.clock = iter(range(0, 100_000, 100)).__next__

    def checkout(self, sha):
        self.events.append(('checkout', sha))
        (self.paths.src / 'config').mkdir(parents=True, exist_ok=True)
        (self.paths.src / 'config/dokploy.json').write_text(json.dumps({
            'firebaseProjectId': 'theater-app-6fa5d', 'host': 'app.example', 'composeId': 'compose-1',
            'remotePath': str(self.paths.home.parent / 'live')}))

    def dokploy(self, path, payload=None):
        self.events.append(('dokploy', (path, payload)))
        if path.startswith('compose.one'):
            return {'composeFile': self.compose_file}
        return {}

    def live_release(self, host):
        return PREVIOUS

    def docker_images(self):
        return list(self.images)

    def remove_image(self, tag):
        self.removed.append(tag)
        return True

    def free_bytes(self, path):
        return self.free

    def run_deploy(self):
        self.events.append(('deploy', self.deploy_env()))
        output = 'Consistent backup verified: /b/theater-1.sqlite\nMedia backup verified: /b/theater-1-media.tar.gz (3 referenced images)\n'
        self.deploy_output = output
        (self.paths.src / 'artifacts').mkdir(exist_ok=True)
        (self.paths.src / 'artifacts/last-deploy.json').write_text(json.dumps({'release': self.release}))
        return output

    def probe(self, host, release):
        if release == PREVIOUS and self.rollback_healthy:
            return None
        return None if self.healthy and release == self.release else 'healthz meldet alt'

    def version_web(self, folder):
        self.events.append(('version-web', folder))

    def notify(self, text):
        self.messages.append(text)


class SelectionTests(unittest.TestCase):
    def test_pull_request_run_on_a_branch_named_main_is_ignored(self):
        self.assertIsNone(autodeploy.select_run([push_run(event='pull_request')], SHA))

    def test_fork_head_repository_is_ignored(self):
        fork = push_run(head_repository={'id': 42, 'full_name': 'someone/TheaterApp'})
        self.assertIsNone(autodeploy.select_run([fork], SHA))

    def test_other_commit_or_workflow_is_ignored(self):
        self.assertIsNone(autodeploy.select_run([push_run(head_sha=OTHER)], SHA))
        self.assertIsNone(autodeploy.select_run([push_run(path='.github/workflows/other.yml')], SHA))

    def test_newest_trusted_run_wins(self):
        runs = [push_run(id=100, run_attempt=2), push_run(id=101), push_run(id=102, event='pull_request')]
        self.assertEqual(autodeploy.select_run(runs, SHA)['id'], 101)

    def test_gate_is_verify_not_google_play(self):
        run = push_run()
        self.assertEqual(autodeploy.verify_state(run, jobs('success', 'failure'))[0], 'success')
        self.assertEqual(autodeploy.verify_state(run, jobs('failure', 'skipped'))[0], 'failure')
        self.assertEqual(autodeploy.verify_state(run, jobs('cancelled', 'skipped'))[0], 'failure')
        running = [{'id': 1, 'name': 'verify', 'status': 'in_progress', 'conclusion': None}]
        self.assertEqual(autodeploy.verify_state(push_run(status='in_progress', conclusion=None), running)[0], 'pending')
        self.assertEqual(autodeploy.verify_state(push_run(status='queued', conclusion=None), [])[0], 'pending')

    def test_finished_run_without_verify_job_is_missing_not_pending(self):
        for conclusion in ('startup_failure', 'failure', 'cancelled'):
            with self.subTest(conclusion=conclusion):
                self.assertEqual(autodeploy.verify_state(push_run(conclusion=conclusion), []), ('missing', None))

    def test_failure_key_is_the_verify_job_not_the_run_attempt(self):
        record = {'commit': SHA, **autodeploy.attempt_key(push_run(), {'id': 1})}
        # 'Re-run failed jobs' for Google Play only: new attempt, same verify job.
        self.assertTrue(autodeploy.same_attempt(record, SHA, push_run(run_attempt=2), {'id': 1}))
        # verify itself ran again.
        self.assertFalse(autodeploy.same_attempt(record, SHA, push_run(run_attempt=2), {'id': 9}))
        self.assertFalse(autodeploy.same_attempt(record, OTHER, push_run(), {'id': 1}))
        missing = {'commit': SHA, **autodeploy.attempt_key(push_run(), None)}
        self.assertTrue(autodeploy.same_attempt(missing, SHA, push_run(), None))
        self.assertFalse(autodeploy.same_attempt(missing, SHA, push_run(run_attempt=2), None))

    def test_artifact_must_come_from_the_selected_run(self):
        data = web_zip()
        pr = artifact(data, id=9, workflow_run={'id': 555, 'head_sha': SHA, 'head_branch': 'main', 'repository_id': autodeploy.REPO_ID, 'head_repository_id': autodeploy.REPO_ID})
        with self.assertRaisesRegex(autodeploy.Rejected, 'fehlt'):
            autodeploy.select_artifact([pr], push_run(), SHA)
        self.assertEqual(autodeploy.select_artifact([pr, artifact(data)], push_run(), SHA)['id'], 7)

    def test_expired_artifact_is_rejected(self):
        data = web_zip()
        for stale in (artifact(data, expired=True), artifact(data, expires_at=PAST)):
            with self.assertRaisesRegex(autodeploy.Rejected, 'abgelaufen'):
                autodeploy.select_artifact([stale], push_run(), SHA)

    def test_implausible_size_is_rejected(self):
        with self.assertRaisesRegex(autodeploy.Rejected, 'Größe'):
            autodeploy.select_artifact([artifact(b'', size_in_bytes=autodeploy.MAX_ZIP_BYTES + 1)], push_run(), SHA)


class DownloadAndExtractTests(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__('shutil').rmtree, self.folder)

    def test_digest_mismatch_is_rejected(self):
        github = FakeGitHub()
        bad = artifact(github.data, digest='sha256:' + '0' * 64)
        with self.assertRaisesRegex(autodeploy.Rejected, 'Prüfsumme'):
            autodeploy.download_artifact(github, bad, self.folder / 'a.zip')

    def test_matching_digest_and_https_redirect_are_accepted(self):
        github = FakeGitHub()
        autodeploy.download_artifact(github, github.artifact_list[0], self.folder / 'a.zip')
        self.assertEqual((self.folder / 'a.zip').read_bytes(), github.data)

    def test_plain_http_storage_redirect_is_rejected(self):
        github = FakeGitHub(location='http://storage.example/zip')
        with self.assertRaisesRegex(autodeploy.Rejected, 'HTTPS'):
            autodeploy.download_artifact(github, github.artifact_list[0], self.folder / 'a.zip')

    def test_oversized_download_is_rejected(self):
        github = FakeGitHub()
        with patch.object(autodeploy, 'MAX_ZIP_BYTES', 10):
            with self.assertRaisesRegex(autodeploy.Rejected, 'größer'):
                autodeploy.download_artifact(github, github.artifact_list[0], self.folder / 'a.zip')

    def extract(self, data):
        archive = self.folder / 'a.zip'
        archive.write_bytes(data)
        autodeploy.safe_extract(archive, self.folder / 'web')

    def test_zip_slip_and_absolute_paths_are_rejected(self):
        for name in ('../evil.js', 'assets/../../evil.js', '/etc/evil.js', 'C:/evil.js', 'a\\..\\evil.js'):
            with self.subTest(name=name):
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, 'w') as bundle:
                    bundle.writestr(zipfile.ZipInfo(name), 'x')
                with self.assertRaisesRegex(autodeploy.Rejected, 'Unsicherer Pfad'):
                    self.extract(buffer.getvalue())
                self.assertFalse((self.folder / 'evil.js').exists())
                __import__('shutil').rmtree(self.folder / 'web', ignore_errors=True)

    def test_symlink_in_zip_is_rejected(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as bundle:
            link = zipfile.ZipInfo('index.html')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            bundle.writestr(link, '/etc/passwd')
        with self.assertRaisesRegex(autodeploy.Rejected, 'Link'):
            self.extract(buffer.getvalue())
        self.assertEqual(list((self.folder / 'web').iterdir()), [])

    def test_extracted_build_is_readable_for_the_container_user(self):
        old = os.umask(0o077)
        try:
            self.extract(web_zip())
        finally:
            os.umask(old)
        web = self.folder / 'web'
        self.assertEqual((web / 'assets/a.txt').read_text(), 'asset')
        self.assertEqual(stat.S_IMODE((web / 'assets/a.txt').stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((web / 'assets').stat().st_mode), 0o755)
        autodeploy.check_web(web, 'theater-app-6fa5d')
        with self.assertRaisesRegex(autodeploy.Rejected, 'Firebase'):
            autodeploy.check_web(web, 'another-project')


class RoundTests(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__('shutil').rmtree, self.folder)
        self.paths = autodeploy.Paths(self.folder / 'home')
        self.paths.prepare()

    def deployer(self, github, **kwargs):
        return FakeDeploy(self.paths, github, **kwargs)

    def test_verify_green_and_play_red_deploys_and_writes_receipt(self):
        github = FakeGitHub(job_list=jobs('success', 'failure'))
        deployer = self.deployer(github)
        self.assertEqual(deployer.round(SHA), 'deployed')
        receipt = json.loads(self.paths.deployed.read_text())
        self.assertEqual((receipt['commit'], receipt['run_id'], receipt['release']), (SHA, 100, FakeDeploy.release))
        self.assertEqual(receipt['backup'], '/b/theater-1.sqlite')
        self.assertEqual(stat.S_IMODE(self.paths.deployed.stat().st_mode), 0o600)
        self.assertEqual((self.paths.src / 'build/web/index.html').read_text(), '<html></html>')
        self.assertFalse(self.paths.failed.exists())
        self.assertEqual(list(self.paths.work.iterdir()), [])
        self.assertIn('ist live', deployer.messages[0])

    def test_deploy_environment_is_local_and_without_github_token(self):
        deployer = self.deployer(FakeGitHub())
        with patch.dict(os.environ, {'GH_TOKEN_FILE': '/x', 'NOTIFY_CMD': 'echo', 'THEATER_DEPLOY_TRANSPORT': 'dokploy', 'DOKPLOY_API_KEY_FILE': '/k'}):
            deployer.round(SHA)
        env = next(value for kind, value in deployer.events if kind == 'deploy')
        self.assertEqual((env['THEATER_DEPLOY_LOCAL'], env['DOKPLOY_API_URL']), ('1', 'http://localhost:3000/api'))
        self.assertEqual(env['THEATER_BACKUP_DIR'], str(self.paths.backups))
        self.assertEqual(env['DOKPLOY_API_KEY_FILE'], '/k')
        for name in ('GH_TOKEN_FILE', 'NOTIFY_CMD', 'THEATER_DEPLOY_TRANSPORT'):
            self.assertNotIn(name, env)

    def test_already_deployed_commit_is_a_no_op(self):
        autodeploy.write_json(self.paths.deployed, {'commit': SHA})
        github = FakeGitHub()
        deployer = self.deployer(github)
        self.assertEqual(deployer.round(SHA), 'current')
        self.assertNotIn('runs', github.calls)
        self.assertEqual(deployer.events, [])

    def test_pending_verify_waits_without_recording(self):
        github = FakeGitHub(job_list=[{'id': 1, 'name': 'verify', 'status': 'queued', 'conclusion': None}])
        with self.assertRaises(autodeploy.Skip):
            self.deployer(github).round(SHA)
        self.assertFalse(self.paths.failed.exists())

    def test_main_moved_before_rollout_skips_without_deploy(self):
        github = FakeGitHub(shas=(OTHER,))
        deployer = self.deployer(github)
        with self.assertRaisesRegex(autodeploy.Skip, 'bewegt'):
            deployer.round(SHA)
        self.assertNotIn('deploy', [kind for kind, _ in deployer.events])
        self.assertFalse(self.paths.failed.exists())
        self.assertFalse(self.paths.deployed.exists())

    def test_health_timeout_rolls_back_the_previous_compose_file(self):
        deployer = self.deployer(FakeGitHub())
        deployer.healthy = False
        with self.assertRaises(autodeploy.Rejected) as caught:
            deployer.round(SHA)
        self.assertEqual(caught.exception.stage, 'health')
        message = str(caught.exception)
        for part in (FakeDeploy.release, f'Rollback auf Release {PREVIOUS} ist live', '/b/theater-1.sqlite', 'nicht automatisch'):
            self.assertIn(part, message)
        calls = [value for kind, value in deployer.events if kind == 'dokploy']
        self.assertEqual([path for path, _ in calls], ['compose.one?composeId=compose-1', 'compose.update', 'compose.deploy'])
        self.assertEqual(calls[1][1]['composeFile'], PREVIOUS_COMPOSE)
        self.assertEqual(self.paths.prev_compose.read_text(), PREVIOUS_COMPOSE)
        self.assertEqual(json.loads(self.paths.prev_release.read_text())['release'], PREVIOUS)
        self.assertFalse(self.paths.deployed.exists())

    def test_failed_rollback_names_the_manual_step(self):
        deployer = self.deployer(FakeGitHub())
        deployer.healthy = deployer.rollback_healthy = False
        with self.assertRaises(autodeploy.Rejected) as caught:
            deployer.round(SHA)
        self.assertIn(f'Rollback auf Release {PREVIOUS} fehlgeschlagen', str(caught.exception))
        self.assertIn(str(self.paths.prev_compose), str(caught.exception))

    def test_no_rollout_without_a_rollback_point(self):
        deployer = self.deployer(FakeGitHub())
        deployer.compose_file = 'services: {}\n'
        with self.assertRaises(autodeploy.Rejected) as caught:
            deployer.round(SHA)
        self.assertEqual(caught.exception.stage, 'rollback')
        self.assertNotIn('deploy', [kind for kind, _ in deployer.events])

    def test_success_prunes_old_tarballs_releases_images_and_work(self):
        stale = self.paths.work / 'run-old'
        (stale / 'web').mkdir(parents=True)
        artifacts = self.paths.src / 'artifacts'
        artifacts.mkdir(parents=True)
        for index in range(5):
            tarball = artifacts / f'deploy-{index:020x}.tar.gz'
            tarball.write_bytes(b'x')
            os.utime(tarball, (index, index))
        releases = self.folder / 'live/releases'
        names = [f'{index:020x}' for index in range(14)]
        for index, name in enumerate(names):
            (releases / name).mkdir(parents=True)
            os.utime(releases / name, (index, index))
        os.utime(releases / names[0], (0, 0))
        (releases / 'not-a-release').mkdir()
        deployer = self.deployer(FakeGitHub())
        oldest = names[0]
        deployer.live_release = lambda host: oldest
        deployer.compose_file = PREVIOUS_COMPOSE.replace(PREVIOUS, oldest)
        deployer.images = [FakeDeploy.release, *reversed(names), 'latest']
        self.assertEqual(deployer.round(SHA), 'deployed')
        self.assertFalse(stale.exists())
        self.assertEqual(len(list(artifacts.glob('deploy-*.tar.gz'))), autodeploy.KEEP_TARBALLS)
        left = sorted(p.name for p in releases.iterdir())
        # Newest 10 plus the previous (rollback) release; foreign folders stay.
        self.assertEqual(left, sorted([*names[4:], oldest, 'not-a-release']))
        self.assertNotIn(oldest, deployer.removed)
        self.assertNotIn(FakeDeploy.release, deployer.removed)
        self.assertNotIn('latest', deployer.removed)
        self.assertEqual(len(deployer.removed), len(names) + 1 - autodeploy.KEEP_IMAGES - 1)

    def test_backup_retention_is_opt_in_and_keeps_the_newest(self):
        backups = self.paths.backups
        stamps = [f'202610{day:02d}T000000Z' for day in range(1, 8)]
        for value in stamps:
            (backups / f'theater-{value}.sqlite').write_text('db')
            (backups / f'theater-{value}-media.tar.gz').write_text('media')
        (backups / 'notes.txt').write_text('keep')
        deployer = self.deployer(FakeGitHub())
        deployer.round(SHA)
        self.assertEqual(len(list(backups.iterdir())), 15)
        self.paths.deployed.unlink()
        with patch.dict(os.environ, {'THEATER_BACKUP_KEEP': '1'}):
            self.deployer(FakeGitHub()).round(SHA)
        left = sorted(p.name for p in backups.iterdir())
        self.assertEqual(left, sorted(['notes.txt', *(f'theater-{v}{suffix}' for v in stamps[-autodeploy.MIN_BACKUPS:] for suffix in ('.sqlite', '-media.tar.gz'))]))

    def test_low_disk_space_alerts_before_the_backup(self):
        deployer = self.deployer(FakeGitHub())
        deployer.free = 1024 ** 3
        self.assertEqual(deployer.round(SHA), 'deployed')
        self.assertIn('frei auf HomeBox', deployer.messages[0])

    def test_ci_pending_for_an_hour_alerts_once_a_day(self):
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=90)).strftime('%Y-%m-%dT%H:%M:%SZ')
        running = [{'id': 1, 'name': 'verify', 'status': 'queued', 'conclusion': None}]
        github = FakeGitHub(runs=[push_run(status='queued', conclusion=None, created_at=old)], job_list=running)
        first, second = self.deployer(github), self.deployer(github)
        for deployer in (first, second):
            with self.assertRaises(autodeploy.Skip):
                deployer.round(SHA)
        self.assertEqual(len(first.messages), 1)
        self.assertIn('wartet seit 90 Minuten', first.messages[0])
        self.assertEqual(second.messages, [])
        fresh = FakeGitHub(runs=[push_run(status='queued', conclusion=None, created_at=autodeploy.stamp())], job_list=running)
        quiet = self.deployer(fresh)
        with self.assertRaises(autodeploy.Skip):
            quiet.round(SHA)
        self.assertEqual(quiet.messages, [])

    def test_missing_push_run_alerts_after_an_hour_since_first_seen(self):
        github = FakeGitHub(runs=[])
        deployer = self.deployer(github)
        with self.assertRaisesRegex(autodeploy.Skip, 'Noch kein Push-Lauf'):
            deployer.round(SHA)
        self.assertEqual(deployer.messages, [])
        autodeploy.write_json(self.paths.seen, {'commit': SHA, 'since': '2020-01-01T00:00:00Z'})
        later = self.deployer(github)
        with self.assertRaises(autodeploy.Skip):
            later.round(SHA)
        self.assertIn('Noch kein Push-Lauf', later.messages[0])

    def test_dry_run_checks_idempotence_without_backup_or_state(self):
        autodeploy.write_json(self.paths.deployed, {'commit': SHA})
        deployer = self.deployer(FakeGitHub(), dry_run=True)
        self.assertEqual(deployer.round(SHA), 'dry-run')
        kinds = [kind for kind, _ in deployer.events]
        # The rollback point is read (compose.one) but not written; nothing else touches Dokploy.
        self.assertEqual(kinds, ['checkout', 'version-web', 'dokploy'])
        self.assertTrue(deployer.events[-1][1][0].startswith('compose.one'))
        self.assertFalse(self.paths.failed.exists())
        self.assertFalse(self.paths.prev_compose.exists())

    def test_dry_run_reports_a_changing_version_step(self):
        class Changing(FakeDeploy):
            def version_web(self, folder):
                (folder / 'index.html').write_text('changed')
        deployer = Changing(self.paths, FakeGitHub(), dry_run=True)
        with self.assertRaisesRegex(autodeploy.Rejected, 'index.html'):
            deployer.round(SHA)


class CheckoutTests(unittest.TestCase):
    def test_checkout_never_cleans_and_skips_when_main_moved(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = autodeploy.Paths(pathlib.Path(folder))
            (paths.src / '.git').mkdir(parents=True)
            calls = []
            deployer = autodeploy.AutoDeploy(paths, FakeGitHub(), out=lambda text: None)
            def git(*args):
                calls.append(args)
                return {('remote', 'get-url', 'origin'): autodeploy.CLONE_URL, ('rev-parse', 'refs/remotes/origin/main'): OTHER}.get(args, '')
            deployer.git = git
            with self.assertRaisesRegex(autodeploy.Skip, 'bewegt'):
                deployer.checkout(SHA)
            self.assertFalse(any(args[0] in ('checkout', 'clean') for args in calls))

    def test_checkout_rejects_stray_files_in_release_content(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = autodeploy.Paths(pathlib.Path(folder))
            (paths.src / '.git').mkdir(parents=True)
            deployer = autodeploy.AutoDeploy(paths, FakeGitHub(), out=lambda text: None)
            def git(*args):
                if args[0] == 'status' and '--ignored' in args:
                    return '?? server/src/leftover.mjs'
                return {('remote', 'get-url', 'origin'): autodeploy.CLONE_URL}.get(args, SHA if args[0] == 'rev-parse' else '')
            deployer.git = git
            with self.assertRaisesRegex(autodeploy.Rejected, 'fremde Dateien'):
                deployer.checkout(SHA)

    def test_wrong_origin_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = autodeploy.Paths(pathlib.Path(folder))
            (paths.src / '.git').mkdir(parents=True)
            deployer = autodeploy.AutoDeploy(paths, FakeGitHub(), out=lambda text: None)
            deployer.git = lambda *args: 'https://github.com/someone/TheaterApp.git'
            with self.assertRaisesRegex(autodeploy.Rejected, 'zeigt nicht'):
                deployer.checkout(SHA)


class GitHubClientTests(unittest.TestCase):
    """Against a local HTTP server: the token must not follow the redirect to artifact storage."""
    def setUp(self):
        import http.server, threading
        self.seen = seen = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get('Authorization')))
                if self.path.endswith('/zip'):
                    self.send_response(302)
                    self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/blob?sig=1')
                    self.end_headers()
                elif self.path.startswith('/blob'):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'zipdata')
                elif 'commits/main' in self.path:
                    body = json.dumps({'sha': SHA}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(401)
                    self.end_headers()
            def log_message(self, *args):
                pass
        self.server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.github = autodeploy.GitHub('test-token', base=f'http://127.0.0.1:{self.server.server_port}/')

    def test_api_calls_carry_the_token(self):
        self.assertEqual(self.github.main_sha(), SHA)
        self.assertEqual(self.seen[-1][1], 'Bearer test-token')

    def test_artifact_redirect_is_followed_without_the_token(self):
        location = self.github.artifact_location(7)
        self.assertTrue(location.startswith('http://127.0.0.1:'))
        with self.github.open_download(location) as response:
            self.assertEqual(response.read(), b'zipdata')
        self.assertEqual(self.seen, [('/repos/LoggeL/TheaterApp/actions/artifacts/7/zip', 'Bearer test-token'), ('/blob?sig=1', None)])

    def test_http_errors_carry_the_status(self):
        with self.assertRaises(autodeploy.GitHubError) as caught:
            self.github.jobs(5)
        self.assertEqual(caught.exception.status, 401)


class MainTests(unittest.TestCase):
    """The systemd entry point: failures are recorded once and not retried every minute."""
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__('shutil').rmtree, self.folder)
        token = self.folder / 'token'
        token.write_text('test-token\n')
        token.chmod(0o600)
        self.env = {'THEATER_AUTODEPLOY_HOME': str(self.folder / 'home'), 'GH_TOKEN_FILE': str(token)}
        self.instances = []
        test = self
        class Recording(FakeDeploy):
            def __init__(self, *args, **kwargs):
                kwargs.pop('out', None)
                super().__init__(*args, **kwargs)
                test.instances.append(self)
        self.recording = Recording

    def main(self, github, *argv):
        with patch.dict(os.environ, self.env), patch.object(autodeploy, 'GitHub', return_value=github), patch.object(autodeploy, 'AutoDeploy', self.recording), \
                contextlib.redirect_stdout(io.StringIO()):
            return autodeploy.main(list(argv))

    def test_red_verify_is_recorded_and_reported_once(self):
        github = FakeGitHub(job_list=jobs('failure', 'skipped'))
        self.assertEqual(self.main(github), 1)
        self.assertEqual(self.main(github), 0)
        failed = json.loads((self.folder / 'home/state/failed.json').read_text())
        self.assertEqual((failed['commit'], failed['stage'], failed['run_id']), (SHA, 'ci', 100))
        self.assertEqual(len(self.instances[0].messages), 1)
        self.assertEqual(self.instances[1].messages, [])

    def test_a_new_verify_run_is_evaluated_again(self):
        self.main(FakeGitHub(job_list=jobs('failure', 'skipped')))
        rerun = FakeGitHub(runs=[push_run(run_attempt=2)], job_list=jobs('success', 'success', verify_id=9))
        self.assertEqual(self.main(rerun), 0)
        self.assertEqual(json.loads((self.folder / 'home/state/deployed.json').read_text())['run_attempt'], 2)
        self.assertFalse((self.folder / 'home/state/failed.json').exists())

    def test_rerunning_only_google_play_does_not_redeploy_a_failed_release(self):
        class Unhealthy(self.recording):
            healthy = False
        self.recording = Unhealthy
        self.assertEqual(self.main(FakeGitHub()), 1)
        self.assertEqual(json.loads((self.folder / 'home/state/failed.json').read_text())['stage'], 'health')
        play_rerun = FakeGitHub(runs=[push_run(run_attempt=2)], job_list=jobs('success', 'success'))
        self.assertEqual(self.main(play_rerun), 0)
        deploys = [kind for instance in self.instances for kind, _ in instance.events if kind == 'deploy']
        self.assertEqual(deploys, ['deploy'])
        self.assertEqual(self.instances[1].messages, [])

    def test_finished_run_without_verify_job_is_recorded_once(self):
        github = FakeGitHub(runs=[push_run(conclusion='startup_failure')], job_list=[])
        self.assertEqual(self.main(github), 1)
        self.assertEqual(self.main(github), 0)
        failed = json.loads((self.folder / 'home/state/failed.json').read_text())
        self.assertEqual(failed['stage'], 'ci')
        self.assertIn('ohne verify-Job', failed['message'])
        self.assertEqual(len(self.instances[0].messages), 1)
        self.assertEqual(self.instances[1].messages, [])

    def test_deploy_failure_is_recorded_and_not_looped(self):
        class Failing(self.recording):
            def run_deploy(self):
                self.events.append(('deploy', None))
                raise autodeploy.Rejected('backup', 'tool/deploy.py endete mit Code 1')
        self.recording = Failing
        github = FakeGitHub()
        self.assertEqual(self.main(github), 1)
        self.assertEqual(self.main(github), 0)
        deploys = [kind for instance in self.instances for kind, _ in instance.events if kind == 'deploy']
        self.assertEqual(deploys, ['deploy'])
        self.assertEqual(json.loads((self.folder / 'home/state/failed.json').read_text())['stage'], 'backup')
        self.assertEqual(self.main(github, '--retry'), 1)

    def test_interrupted_deploy_leaves_a_failure_marker(self):
        class Killed(self.recording):
            def run_deploy(self):
                raise KeyboardInterrupt
        self.recording = Killed
        with self.assertRaises(KeyboardInterrupt):
            self.main(FakeGitHub())
        failed = json.loads((self.folder / 'home/state/failed.json').read_text())
        self.assertEqual((failed['commit'], failed['stage']), (SHA, 'deploy'))
        self.assertNotIn('notified', failed)
        self.assertIn(PREVIOUS, failed['message'])

    def test_interrupted_deploy_is_reported_once_on_the_next_round(self):
        class Killed(self.recording):
            def run_deploy(self):
                raise KeyboardInterrupt
        self.recording = Killed
        with self.assertRaises(KeyboardInterrupt):
            self.main(FakeGitHub())
        backups = self.folder / 'home/backups'
        (backups / 'theater-20261030T010203Z.sqlite').write_text('db')
        self.assertEqual(self.main(FakeGitHub()), 0)
        self.assertEqual(self.main(FakeGitHub()), 0)
        self.assertEqual(len(self.instances[1].messages), 1)
        self.assertIn('unterbrochen', self.instances[1].messages[0])
        self.assertIn('theater-20261030T010203Z.sqlite', self.instances[1].messages[0])
        self.assertEqual(self.instances[2].messages, [])
        self.assertTrue(json.loads((self.folder / 'home/state/failed.json').read_text())['notified'])

    def test_persistent_unexpected_errors_alert_after_the_grace_period(self):
        class Offline(FakeGitHub):
            def main_sha(self):
                raise OSError('network down')
        sent = []
        with patch.object(autodeploy.AutoDeploy, 'notify', lambda self, text: sent.append(text)):
            for _ in range(2):
                with patch.dict(os.environ, self.env), patch.object(autodeploy, 'GitHub', return_value=Offline()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(OSError):
                        autodeploy.main([])
            self.assertEqual(sent, [])
            alerts = self.folder / 'home/state/alerts.json'
            autodeploy.write_json(alerts, {'error-since': '2020-01-01T00:00:00Z'})
            for _ in range(2):
                with patch.dict(os.environ, self.env), patch.object(autodeploy, 'GitHub', return_value=Offline()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(OSError):
                        autodeploy.main([])
            self.assertEqual(len(sent), 1)
            self.assertIn('network down', sent[0])
            # A clean round resets the clock.
            with patch.dict(os.environ, self.env), patch.object(autodeploy, 'GitHub', return_value=FakeGitHub()), \
                    patch.object(autodeploy, 'AutoDeploy', self.recording), contextlib.redirect_stdout(io.StringIO()):
                autodeploy.main([])
            self.assertNotIn('error-since', json.loads(alerts.read_text()))

    def test_corrupt_state_files_do_not_stop_the_deployer(self):
        state = self.folder / 'home/state'
        state.mkdir(parents=True)
        for name in ('deployed.json', 'failed.json', 'alerts.json'):
            (state / name).write_text('')
        self.assertEqual(self.main(FakeGitHub()), 0)
        self.assertEqual(json.loads((state / 'deployed.json').read_text())['commit'], SHA)

    def test_held_lock_ends_the_round_quietly(self):
        import fcntl
        home = self.folder / 'home'
        home.mkdir(mode=0o700)
        with (home / '.deploy.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            github = FakeGitHub()
            self.assertEqual(self.main(github), 0)
            self.assertEqual(github.calls, [])

    def test_rejected_token_alerts_at_most_daily(self):
        class Unauthorized(FakeGitHub):
            def main_sha(self):
                raise autodeploy.GitHubError(401, 'repos/LoggeL/TheaterApp/commits/main')
        sent = []
        with patch.object(autodeploy.AutoDeploy, 'notify', lambda self, text: sent.append(text)):
            for _ in range(2):
                with patch.dict(os.environ, self.env), patch.object(autodeploy, 'GitHub', return_value=Unauthorized()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(autodeploy.GitHubError):
                        autodeploy.main([])
        self.assertEqual(len(sent), 1)
        self.assertIn('Token erneuern', sent[0])

    def test_insecure_token_file_is_refused(self):
        pathlib.Path(self.env['GH_TOKEN_FILE']).chmod(0o644)
        with patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(RuntimeError, 'private file'):
                autodeploy.main([])


if __name__ == '__main__':
    unittest.main()
