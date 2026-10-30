#!/usr/bin/env python3
"""Deploy the current main commit on HomeBox once its CI 'verify' job has passed.

Runs as a oneshot systemd user service (deploy/homebox/) from an installed copy, not from the clone
it updates. That only keeps a broken commit from breaking the poller itself; it is no security
boundary. tool/deploy.py and tool/backup.py run from the pushed commit as the service user (docker
group, root-equivalent), who can also rewrite this copy, its units and its keys. Trust model: whatever
reaches main and passes 'verify' runs on HomeBox. Each round takes the 'theater-web' artifact of the
push run for exactly the current main commit, checks out the same commit in a dedicated clone and hands
over to tool/deploy.py --skip-build, which still backs up first. If the new release does not become
healthy, the previous Compose file is deployed again (never the database). Standard library only; the
GitHub token and the Dokploy key come from private files.
"""
import argparse, datetime, fcntl, hashlib, json, os, pathlib, re, shlex, shutil, stat, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request, zipfile

REPO = 'LoggeL/TheaterApp'
REPO_ID = 1367574965
CLONE_URL = f'https://github.com/{REPO}.git'
WORKFLOW_PATH = '.github/workflows/checks.yml'
VERIFY_JOB = 'verify'
ARTIFACT = 'theater-web'
MAX_ZIP_BYTES = 200 * 1024 * 1024
MAX_UNPACKED_BYTES = 800 * 1024 * 1024
MAX_ENTRIES = 20000
HEALTH_TIMEOUT = 300
DOKPLOY_URL = 'http://localhost:3000/api'
# Alerts: CI that has not finished after an hour, and errors that persist across rounds.
PENDING_ALERT = datetime.timedelta(minutes=60)
ERROR_GRACE = datetime.timedelta(minutes=15)
ALERT_RETENTION = datetime.timedelta(days=30)
# Retention after a successful deploy. Running and previous release are always kept.
KEEP_TARBALLS = 3
KEEP_RELEASE_DIRS = 10
KEEP_IMAGES = 5
MIN_BACKUPS = 3
LOW_DISK_BYTES = 10 * 1024 ** 3
# The service runs with UMask=0077, but the container user must read the checkout and build/web:
# deploy.py's tar and Docker COPY keep file modes, and the Dockerfile only widens directories.
SOURCE_UMASK = 0o022
SECRET_ENV = ('GH_TOKEN_FILE', 'GH_TOKEN', 'GITHUB_TOKEN', 'NOTIFY_CMD')
SHA = re.compile('[0-9a-f]{40}')
RELEASE = re.compile('[0-9a-f]{20}')
BACKUP_NAME = re.compile(r'theater-(\d{8}T\d{6}Z)(?:\.sqlite|-media\.tar\.gz)')


class Skip(Exception):
    """Nothing to do this round (CI still running, main moved). Not a failure."""


class Rejected(Exception):
    """This commit/run attempt cannot be deployed. Recorded once in failed.json, never retried every minute."""
    def __init__(self, stage, message):
        super().__init__(message)
        self.stage = stage


class GitHubError(RuntimeError):
    def __init__(self, status, path):
        super().__init__(f'GitHub {path}: HTTP {status}')
        self.status = status


class Paths:
    def __init__(self, home):
        self.home = pathlib.Path(home).expanduser()
        self.src = self.home / 'src'
        self.state = self.home / 'state'
        self.work = self.home / 'work'
        self.backups = self.home / 'backups'
        self.lock = self.home / '.deploy.lock'
        self.deployed = self.state / 'deployed.json'
        self.failed = self.state / 'failed.json'
        self.alerts = self.state / 'alerts.json'
        self.seen = self.state / 'seen.json'
        self.prev_compose = self.state / 'prev-compose.yml'
        self.prev_release = self.state / 'prev-release.json'

    def prepare(self):
        for folder in (self.home, self.state, self.work, self.backups):
            folder.mkdir(mode=0o700, parents=True, exist_ok=True)


def private_file(path, name):
    path = pathlib.Path(path).expanduser()
    if not path.is_file() or stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise RuntimeError(f'{name} must be a private file (mode 600 or stricter).')
    value = path.read_text().strip()
    if not value or '\n' in value or '\r' in value:
        raise RuntimeError(f'{name} must contain exactly one value.')
    return value


def read_json(path):
    """A missing or unreadable state file counts as empty (after a power cut it can be truncated).
    For deployed.json that costs at most one redeploy; it must never stop the deployer for good."""
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except ValueError:
        print(f'{path.name} ist beschädigt und wird ignoriert.', flush=True)
        return {}
    return value if isinstance(value, dict) else {}


def write_text(path, text):
    """Atomic and durable: the temp file reaches the disk before it replaces the old one."""
    temp = path.with_name(path.name + '.tmp')
    with open(temp, 'w') as out:
        out.write(text)
        out.flush()
        os.fchmod(out.fileno(), 0o600)
        os.fsync(out.fileno())
    temp.replace(path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def write_json(path, value):
    write_text(path, json.dumps(value, indent=2) + '\n')


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def stamp(now=None):
    return (now or utc_now()).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_time(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class GitHub:
    """Minimal read-only client. The token never follows the redirect to artifact storage."""
    def __init__(self, token, base='https://api.github.com/'):
        self.token, self.base = token, base
        self.opener = urllib.request.build_opener(_NoRedirect)

    def _open(self, path):
        request = urllib.request.Request(self.base + path, headers={
            'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'theater-autodeploy'})
        request.add_unredirected_header('Authorization', 'Bearer ' + self.token)
        return self.opener.open(request, timeout=30)

    def get(self, path):
        try:
            with self._open(path) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            error.close()
            raise GitHubError(error.code, path.split('?')[0]) from None

    def main_sha(self):
        sha = self.get(f'repos/{REPO}/commits/main')['sha']
        if not SHA.fullmatch(sha):
            raise RuntimeError('GitHub returned an invalid commit SHA for main.')
        return sha

    def runs(self, sha):
        query = urllib.parse.urlencode({'branch': 'main', 'event': 'push', 'head_sha': sha, 'exclude_pull_requests': 'true', 'per_page': 20})
        return self.get(f'repos/{REPO}/actions/workflows/{pathlib.PurePath(WORKFLOW_PATH).name}/runs?{query}')['workflow_runs']

    def jobs(self, run_id):
        return self.get(f'repos/{REPO}/actions/runs/{int(run_id)}/jobs?filter=latest&per_page=100')['jobs']

    def artifacts(self, run_id):
        query = urllib.parse.urlencode({'name': ARTIFACT, 'per_page': 100})
        return self.get(f'repos/{REPO}/actions/runs/{int(run_id)}/artifacts?{query}')['artifacts']

    def artifact_location(self, artifact_id):
        path = f'repos/{REPO}/actions/artifacts/{int(artifact_id)}/zip'
        try:
            with self._open(path) as response:
                raise GitHubError(response.status, path)
        except urllib.error.HTTPError as error:
            location = error.headers.get('Location')
            error.close()
            if error.code in (301, 302, 303, 307, 308) and location:
                return location
            raise GitHubError(error.code, path) from None

    def open_download(self, url):
        # The signed storage URL is valid for about a minute and must not see the token.
        return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'theater-autodeploy'}), timeout=60)


def select_run(runs, sha):
    """Only the push run of checks.yml on this repository's main for exactly this commit.

    Pull requests, including fork PRs from a branch named main, upload an artifact of the same name.
    """
    def trusted(run):
        head = run.get('head_repository') or {}
        return (run.get('event') == 'push' and run.get('head_branch') == 'main' and run.get('head_sha') == sha
                and run.get('path') == WORKFLOW_PATH and head.get('id') == REPO_ID and head.get('full_name') == REPO
                and (run.get('repository') or {}).get('id', REPO_ID) == REPO_ID)
    return max(filter(trusted, runs), key=lambda run: (run['id'], run.get('run_attempt') or 1), default=None)


def verify_state(run, jobs):
    """Gate on the web build only; the Google Play job is deliberately not awaited.

    'missing': the run finished without a verify job (workflow syntax error, startup_failure, cancelled
    before the jobs were created). Waiting would never end, so the caller rejects it.
    """
    matches = [job for job in jobs if job.get('name') == VERIFY_JOB]
    job = max(matches, key=lambda job: (job.get('run_attempt') or 1, job['id']), default=None)
    if job and job.get('status') == 'completed':
        return ('success' if job.get('conclusion') == 'success' else 'failure'), job
    if not job and run.get('status') == 'completed':
        return 'missing', None
    return 'pending', job


def run_started(run):
    """When this attempt began; a re-run keeps created_at but gets a new run_started_at."""
    times = [parse_time(run[key]) for key in ('created_at', 'run_started_at') if run.get(key)]
    return max(times, default=None)


def select_artifact(artifacts, run, sha, now=None):
    now = now or utc_now()
    def from_run(artifact):
        origin = artifact.get('workflow_run') or {}
        return (artifact.get('name') == ARTIFACT and origin.get('id') == run['id'] and origin.get('head_sha') == sha
                and origin.get('head_branch') == 'main' and origin.get('repository_id') == REPO_ID
                and origin.get('head_repository_id') == REPO_ID)
    candidates = [artifact for artifact in artifacts if from_run(artifact)]
    if not candidates:
        raise Rejected('artifact', f'Artefakt {ARTIFACT} fehlt im Push-Lauf {run["id"]}.')
    usable = [artifact for artifact in candidates if not artifact.get('expired') and artifact.get('expires_at') and parse_time(artifact['expires_at']) > now]
    if not usable:
        raise Rejected('artifact', f'Artefakt {ARTIFACT} aus Lauf {run["id"]} ist abgelaufen; CI für diesen Commit neu starten.')
    artifact = max(usable, key=lambda artifact: artifact['id'])
    if not 0 < (artifact.get('size_in_bytes') or 0) <= MAX_ZIP_BYTES:
        raise Rejected('artifact', f'Artefakt {artifact["id"]} hat eine unplausible Größe ({artifact.get("size_in_bytes")} Bytes).')
    return artifact


def check_digest(artifact, actual):
    expected = artifact.get('digest')
    if not expected:
        return
    algorithm, _, value = expected.partition(':')
    if algorithm != 'sha256' or value.lower() != actual:
        raise Rejected('artifact', f'Prüfsumme von Artefakt {artifact["id"]} stimmt nicht.')


def download_artifact(github, artifact, destination):
    try:
        location = github.artifact_location(artifact['id'])
    except GitHubError as error:
        if error.status in (404, 410):
            raise Rejected('artifact', f'Artefakt {artifact["id"]} ist nicht mehr abrufbar ({error}).') from None
        raise
    if urllib.parse.urlsplit(location).scheme != 'https':
        raise Rejected('artifact', 'GitHub leitet den Artefakt-Download nicht auf HTTPS um.')
    digest, size = hashlib.sha256(), 0
    with github.open_download(location) as response, open(destination, 'xb') as target:
        while chunk := response.read(1 << 20):
            size += len(chunk)
            if size > MAX_ZIP_BYTES:
                raise Rejected('artifact', f'Artefakt {artifact["id"]} ist größer als erlaubt.')
            digest.update(chunk)
            target.write(chunk)
    check_digest(artifact, digest.hexdigest())


def safe_extract(archive, target):
    """Extract an untrusted zip into a new directory: no absolute paths, no '..', no links or devices."""
    target.mkdir(mode=0o755)
    target.chmod(0o755)
    with zipfile.ZipFile(archive) as bundle:
        entries, names, total = bundle.infolist(), set(), 0
        if not entries or len(entries) > MAX_ENTRIES:
            raise Rejected('artifact', 'Artefakt ist leer oder hat zu viele Einträge.')
        for entry in entries:
            name = entry.filename
            parts = name.rstrip('/').split('/')
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if (not name or name.startswith('/') or '\\' in name or '\0' in name or re.match(r'^[A-Za-z]:', name)
                    or any(part in ('', '.', '..') for part in parts)):
                raise Rejected('artifact', f'Unsicherer Pfad im Artefakt: {name!r}')
            if (kind not in (0, stat.S_IFREG, stat.S_IFDIR) or (kind == stat.S_IFDIR and not entry.is_dir())
                    or (kind == stat.S_IFREG and entry.is_dir())):
                raise Rejected('artifact', f'Link oder Sonderdatei im Artefakt: {name!r}')
            if entry.flag_bits & 0x1:
                raise Rejected('artifact', f'Verschlüsselter Eintrag im Artefakt: {name!r}')
            key = '/'.join(parts)
            if key in names:
                raise Rejected('artifact', f'Doppelter Eintrag im Artefakt: {name!r}')
            names.add(key)
            total += entry.file_size
            if total > MAX_UNPACKED_BYTES:
                raise Rejected('artifact', 'Artefakt ist entpackt größer als erlaubt.')
        root = target.resolve()
        for entry in entries:
            path = target.joinpath(*entry.filename.rstrip('/').split('/'))
            if root not in path.resolve().parents:
                raise Rejected('artifact', f'Unsicherer Pfad im Artefakt: {entry.filename!r}')
            if entry.is_dir():
                path.mkdir(mode=0o755, parents=True, exist_ok=True)
                continue
            for parent in reversed(path.relative_to(target).parents[:-1]):
                folder = target / parent
                if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
                    raise Rejected('artifact', f'Unsicherer Pfad im Artefakt: {entry.filename!r}')
                folder.mkdir(mode=0o755, exist_ok=True)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o644)
            with os.fdopen(descriptor, 'wb') as out, bundle.open(entry) as source:
                shutil.copyfileobj(source, out, 1 << 20)
                os.fchmod(out.fileno(), 0o644)
        for folder in [target, *(p for p in target.rglob('*') if p.is_dir())]:
            folder.chmod(0o755)


def check_web(web, firebase_project):
    for name in ('index.html', 'main.dart.js', 'flutter_bootstrap.js', 'firebase-web-config.js'):
        if not (web / name).is_file():
            raise Rejected('artifact', f'Artefakt enthält kein {name}.')
    if firebase_project not in (web / 'firebase-web-config.js').read_text(errors='replace'):
        raise Rejected('artifact', 'Artefakt gehört zu einem anderen Firebase-Projekt.')


def tree_digest(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(folder.rglob('*')) if p.is_file()}


def attempt_key(run, job):
    """What a failure is recorded against. The verify job id survives a re-run of only the Play job
    (same build, same artifact, so the same verdict); a new run of verify gets a new id."""
    if job:
        return {'verify_job_id': job['id']}
    return {'verify_job_id': None, 'run_id': run['id'], 'run_attempt': run.get('run_attempt') or 1}


def same_attempt(record, sha, run, job):
    key = attempt_key(run, job)
    return record.get('commit') == sha and all(record.get(name, '?') == value for name, value in key.items())


def backup_files(output):
    found = {}
    for line in output.splitlines():
        for key, prefix in (('backup', 'Consistent backup verified: '), ('media_backup', 'Media backup verified: ')):
            if line.startswith(prefix):
                found[key] = line[len(prefix):].split(' (')[0].strip()
    return found


class AutoDeploy:
    def __init__(self, paths, github, dry_run=False, retry=False, out=print):
        self.paths, self.github, self.dry_run, self.retry, self.out = paths, github, dry_run, retry, out
        self.sleep, self.clock = time.sleep, time.monotonic

    # --- side effects; tests replace these -------------------------------------------------
    def command(self, args, cwd=None, capture=True, env=None):
        result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True, umask=SOURCE_UMASK,
                                stdout=subprocess.PIPE if capture else None, stderr=None)
        return (result.stdout or '').strip()

    def git(self, *args):
        return self.command(['git', '-C', str(self.paths.src), *args], env={**self.deploy_env(), 'GIT_TERMINAL_PROMPT': '0'})

    def deploy_env(self):
        env = {k: v for k, v in os.environ.items() if k not in SECRET_ENV and k != 'THEATER_DEPLOY_TRANSPORT'}
        env.update({'THEATER_DEPLOY_LOCAL': '1', 'DOKPLOY_API_URL': 'http://localhost:3000/api'})
        env.setdefault('THEATER_BACKUP_DIR', str(self.paths.backups))
        return env

    def run_deploy(self):
        """tool/deploy.py --skip-build from the checkout; it backs up before anything else."""
        process = subprocess.Popen([sys.executable, 'tool/deploy.py', '--skip-build'], cwd=self.paths.src, env=self.deploy_env(),
                                   umask=SOURCE_UMASK, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        for line in process.stdout:
            sys.stdout.write(line)
            lines.append(line)
        self.deploy_output = output = ''.join(lines)
        if process.wait():
            stage = 'backup' if 'Media backup verified' not in output else 'deploy'
            raise Rejected(stage, f'tool/deploy.py endete mit Code {process.returncode}' + (' vor dem Backup-Abschluss; Produktion unverändert.' if stage == 'backup' else '.'))
        return output

    def version_web(self, folder):
        self.command(['node', 'tool/version-web.mjs', str(folder)], cwd=self.paths.src)

    def healthz(self, host):
        return json.loads(self.command(['curl', '--fail', '--silent', '--show-error', '--max-time', '20', '-H', 'Cache-Control: no-cache', f'https://{host}/api/healthz']))

    def live_release(self, host):
        try:
            return self.healthz(host).get('release')
        except (subprocess.CalledProcessError, ValueError, AttributeError):
            return None

    def probe(self, host, release):
        """None when the public edge serves the release and its container is healthy, else the reason."""
        try:
            body = self.healthz(host)
        except (subprocess.CalledProcessError, ValueError) as error:
            return f'healthz nicht erreichbar ({error})'
        if body.get('release') != release:
            return f'healthz meldet {body.get("release")}'
        try:
            status = self.command(['docker', 'ps', '--filter', 'label=com.docker.compose.service=theater', '--filter', f'ancestor=theater-app:{release}', '--format', '{{.Status}}'])
        except subprocess.CalledProcessError as error:
            return f'docker ps fehlgeschlagen ({error})'
        if '(healthy)' not in status:
            return f'Container theater-app:{release} ist nicht healthy ({status or "nicht gefunden"})'
        return None

    def dokploy(self, path, payload=None):
        """Local Dokploy API, as in tool/deploy.py: the key goes to curl on stdin, never as an argument."""
        key = os.environ.get('DOKPLOY_API_KEY', '').strip() or private_file(os.environ.get('DOKPLOY_API_KEY_FILE', ''), 'DOKPLOY_API_KEY_FILE')
        config = 'header = ' + json.dumps('x-api-key: ' + key) + '\n'
        if payload is not None:
            config += 'request = "POST"\nheader = "Content-Type: application/json"\ndata = ' + json.dumps(json.dumps(payload)) + '\n'
        result = subprocess.run(['curl', '--config', '-', '-sS', '--max-time', '45', '-w', '\n%{http_code}', f'{DOKPLOY_URL}/{path}'],
                                input=config, text=True, capture_output=True, check=True)
        body, _, status = result.stdout.rpartition('\n')
        if status != '200':
            raise RuntimeError(f'Dokploy {path.split("?")[0]}: HTTP {status}')
        return json.loads(body) if body.strip() else {}

    def docker_images(self):
        """theater-app tags, newest first (docker's own order)."""
        return self.command(['docker', 'image', 'ls', 'theater-app', '--format', '{{.Tag}}']).split()

    def remove_image(self, tag):
        # No --force: an image that a container still uses stays.
        return subprocess.run(['docker', 'image', 'rm', f'theater-app:{tag}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

    def free_bytes(self, path):
        return shutil.disk_usage(path).free

    def notify(self, text):
        self.out(text)
        command = os.environ.get('NOTIFY_CMD')
        if command and not self.dry_run:
            try:
                subprocess.run([*shlex.split(command), text], check=True, timeout=60)
            except Exception as error:
                self.out(f'Benachrichtigung fehlgeschlagen: {error}')

    # --- steps --------------------------------------------------------------------------------
    def checkout(self, sha):
        if not (self.paths.src / '.git').is_dir():
            self.command(['git', 'clone', '--no-checkout', CLONE_URL, str(self.paths.src)], env={**self.deploy_env(), 'GIT_TERMINAL_PROMPT': '0'})
        if self.git('remote', 'get-url', 'origin') != CLONE_URL:
            raise Rejected('checkout', f'Der Clone {self.paths.src} zeigt nicht auf {CLONE_URL}.')
        self.git('fetch', '--quiet', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main')
        if self.git('rev-parse', 'refs/remotes/origin/main') != sha:
            raise Skip('main hat sich während des Durchgangs bewegt.')
        # Never 'git clean -x': local backups and artifacts/ live in ignored folders.
        self.git('checkout', '--quiet', '--force', '--detach', sha)
        if self.git('rev-parse', 'HEAD') != sha:
            raise Rejected('checkout', 'Checkout steht nicht auf dem erwarteten Commit.')
        dirty = self.git('status', '--porcelain', '--untracked-files=no')
        stray = self.git('status', '--porcelain', '--untracked-files=all', '--ignored', '--', 'Dockerfile', 'server/src', 'server/scripts', 'server/package.json', 'server/package-lock.json')
        if dirty or stray:
            raise Rejected('checkout', f'Der Clone enthält fremde Dateien im Release-Inhalt: {(dirty + stray).splitlines()[:5]}')
        for path in [self.paths.src / 'Dockerfile', *(self.paths.src / 'server').glob('package*.json'), *(self.paths.src / 'server/src').rglob('*'), *(self.paths.src / 'server/scripts').rglob('*')]:
            if path.is_file() and not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) & 0o044 != 0o044:
                path.chmod(stat.S_IMODE(path.stat().st_mode) | 0o044)

    def install_web(self, web):
        build = self.paths.src / 'build'
        build.mkdir(mode=0o755, exist_ok=True)
        target = build / 'web'
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
        shutil.move(str(web), str(target))
        (self.paths.src / 'artifacts' / 'last-deploy.json').unlink(missing_ok=True)

    def check_idempotent(self, work):
        """version-web.mjs runs again in deploy.py; on a CI build it must change nothing."""
        copy = work / 'idempotence'
        shutil.copytree(self.paths.src / 'build/web', copy, symlinks=True)
        self.version_web(copy)
        before, after = tree_digest(self.paths.src / 'build/web'), tree_digest(copy)
        changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        if changed:
            raise Rejected('dry-run', f'version-web.mjs ändert den CI-Build erneut: {changed[:10]}')

    def clean_work(self):
        """Runs under the lock, so every leftover in work/ is stale (e.g. after a kill by TimeoutStartSec)."""
        for old in self.paths.work.glob('run-*'):
            shutil.rmtree(old, ignore_errors=True)

    def backup_dir(self):
        return pathlib.Path(self.deploy_env()['THEATER_BACKUP_DIR']).expanduser()

    def newest_backup(self):
        names = sorted(p.name for p in self.backup_dir().glob('theater-*.sqlite')) if self.backup_dir().is_dir() else []
        return names[-1] if names else 'keins gefunden'

    def snapshot(self, config):
        """Rollback point: the Compose file Dokploy runs now. No rollout without it."""
        compose_id = config.get('composeId')
        if not compose_id:
            raise Rejected('rollback', 'config/dokploy.json hat keine composeId; ohne Rückfallpunkt kein Rollout.')
        compose = self.dokploy('compose.one?composeId=' + urllib.parse.quote(compose_id)).get('composeFile') or ''
        images = re.findall(r'(?m)^\s*image:\s*theater-app:([0-9a-f]{20})\s*$', compose)
        if len(images) != 1:
            raise Rejected('rollback', 'Dokploy liefert keine Compose-Datei mit genau einem theater-app-Image; ohne Rückfallpunkt kein Rollout.')
        previous = {'compose_id': compose_id, 'release': images[0], 'live_release': self.live_release(config['host']), 'saved_at': stamp()}
        if not self.dry_run:
            write_text(self.paths.prev_compose, compose)
            write_json(self.paths.prev_release, previous)
        return {**previous, 'compose': compose}

    def rollback(self, config, previous):
        """Deploy the saved Compose file again. Never touches the database. Returns a sentence for the alert."""
        release = previous['release']
        try:
            self.dokploy('compose.update', {'composeId': previous['compose_id'], 'composeFile': previous['compose'], 'sourceType': 'raw', 'composeType': 'docker-compose'})
            self.dokploy('compose.deploy', {'composeId': previous['compose_id'], 'title': f'Theater-App Rollback {release}', 'description': 'Automatischer Rollback des Auto-Deploys'})
            self.wait_healthy(config['host'], release)
        except Exception as error:
            return (f' Rollback auf Release {release} fehlgeschlagen ({error}); Produktion prüfen. Manuell: '
                    f'{self.paths.prev_compose} in Dokploy als Compose-Datei setzen und deployen.')
        return f' Automatischer Rollback auf Release {release} ist live.'

    def prune(self, config, keep):
        """Retention after a successful deploy; every push adds a tarball, a build context, an image and a backup."""
        problems = []
        tarballs = sorted((self.paths.src / 'artifacts').glob('deploy-*.tar.gz'), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in tarballs[KEEP_TARBALLS:]:
            old.unlink(missing_ok=True)
        releases = pathlib.Path(config['remotePath']) / 'releases'
        if releases.is_absolute() and releases.is_dir():
            folders = sorted((p for p in releases.iterdir() if RELEASE.fullmatch(p.name) and p.is_dir() and not p.is_symlink()),
                             key=lambda p: p.stat().st_mtime, reverse=True)
            for old in folders[KEEP_RELEASE_DIRS:]:
                if old.name not in keep:
                    try:
                        shutil.rmtree(old)
                    except OSError as error:
                        problems.append(str(error))
        tags = [tag for tag in self.docker_images() if RELEASE.fullmatch(tag)]
        for tag in tags[KEEP_IMAGES:]:
            if tag not in keep:
                self.remove_image(tag)
        limit = os.environ.get('THEATER_BACKUP_KEEP', '').strip()
        if limit and self.backup_dir().is_dir():
            stamps = sorted({m.group(1) for p in self.backup_dir().iterdir() if (m := BACKUP_NAME.fullmatch(p.name))}, reverse=True)
            for old in stamps[max(int(limit), MIN_BACKUPS):]:
                for name in (f'theater-{old}.sqlite', f'theater-{old}-media.tar.gz'):
                    (self.backup_dir() / name).unlink(missing_ok=True)
        if problems:
            self.out(f'Aufräumen unvollständig: {problems[:3]}')

    def check_disk(self):
        folder = self.backup_dir() if self.backup_dir().is_dir() else self.paths.home
        free = self.free_bytes(folder)
        if free < LOW_DISK_BYTES:
            self.alert('disk', f'Theater-Auto-Deploy: nur noch {free // 1024 ** 3} GB frei auf HomeBox ({folder}). Backups und Releases aufräumen.', datetime.timedelta(days=1))

    def waiting(self, sha, since, text):
        """Skip quietly, but say so once a day when CI has not delivered for an hour."""
        if since is None:
            seen = read_json(self.paths.seen)
            if seen.get('commit') != sha or not seen.get('since'):
                seen = {'commit': sha, 'since': stamp()}
                if not self.dry_run:
                    write_json(self.paths.seen, seen)
            since = parse_time(seen['since'])
        if utc_now() - since >= PENDING_ALERT:
            minutes = int((utc_now() - since).total_seconds() // 60)
            self.alert(f'pending-{sha}', f'Theater-Auto-Deploy wartet seit {minutes} Minuten auf CI für {sha[:7]}: {text}', datetime.timedelta(days=1))
        raise Skip(text)

    def wait_healthy(self, host, release, timeout=HEALTH_TIMEOUT, interval=5):
        deadline = self.clock() + timeout
        while (reason := self.probe(host, release)) is not None:
            if self.clock() >= deadline:
                raise Rejected('health', f'Release {release} ist nach {timeout // 60} Minuten nicht live: {reason}')
            self.sleep(interval)

    def round(self, sha):
        """One polling round for main at sha. Returns a short status word; raises Skip or Rejected."""
        self.clean_work()
        deployed = read_json(self.paths.deployed)
        if deployed.get('commit') == sha and not self.dry_run:
            return 'current'
        run = select_run(self.github.runs(sha), sha)
        if not run:
            self.waiting(sha, None, f'Noch kein Push-Lauf von checks.yml für {sha[:7]}.')
        self.current_run = run
        state, job = verify_state(run, self.github.jobs(run['id']))
        self.current_job = job
        if same_attempt(read_json(self.paths.failed), sha, run, job) and not (self.retry or self.dry_run):
            return 'failed-before'
        if state == 'pending':
            self.waiting(sha, run_started(run), f'verify für {sha[:7]} läuft noch (Lauf {run["id"]}, {run.get("status")}).')
        if state == 'missing':
            raise Rejected('ci', f'Lauf {run["id"]} endete mit {run.get("conclusion")} ohne verify-Job: {run.get("html_url", run["id"])}')
        if state == 'failure':
            raise Rejected('ci', f'verify ist {job.get("conclusion")}: {run.get("html_url", run["id"])}')
        artifact = select_artifact(self.github.artifacts(run['id']), run, sha)
        work = pathlib.Path(tempfile.mkdtemp(prefix='run-', dir=self.paths.work))
        try:
            self.checkout(sha)
            archive = work / 'theater-web.zip'
            download_artifact(self.github, artifact, archive)
            safe_extract(archive, work / 'web')
            config = json.loads((self.paths.src / 'config/dokploy.json').read_text())
            check_web(work / 'web', config['firebaseProjectId'])
            self.install_web(work / 'web')
            if self.dry_run:
                self.check_idempotent(work)
                previous = self.snapshot(config)
                moved = self.github.main_sha() != sha
                self.out(f'Probelauf ok: {sha[:7]}, Lauf {run["id"]}, Artefakt {artifact["id"]} geprüft und nach build/web übernommen; version-web.mjs ist idempotent. '
                         f'Rückfallpunkt: Release {previous["release"]} (healthz: {previous["live_release"]}).'
                         + (' Achtung: main hat sich inzwischen bewegt.' if moved else '') + ' Kein Backup, kein Rollout.')
                return 'dry-run'
            if self.github.main_sha() != sha:
                raise Skip('main hat sich vor dem Rollout bewegt; der nächste Durchgang übernimmt den neuen Commit.')
            previous = self.snapshot(config)
            self.check_disk()
            # From here on every error is recorded: a retry would take another backup every minute.
            # The marker also covers a kill by TimeoutStartSec or a reboot: it has no 'notified', so the
            # next round reports it once (main). Success removes it.
            self.deploy_output = ''
            self.record(sha, 'deploy', f'Deploy wurde unterbrochen (Timeout, Neustart oder Abbruch); Produktion prüfen. '
                                       f'Vorher lief Release {previous["release"]}, Compose-Datei in {self.paths.prev_compose}.')
            try:
                backups = backup_files(self.run_deploy())
                last = read_json(self.paths.src / 'artifacts' / 'last-deploy.json')
                if not last.get('release'):
                    raise Rejected('deploy', 'tool/deploy.py hat keine artifacts/last-deploy.json geschrieben.')
                self.wait_healthy(config['host'], last['release'])
            except Exception as error:
                stage = error.stage if isinstance(error, Rejected) else 'deploy'
                backups = backup_files(self.deploy_output)
                hint = f' Backup: {backups["backup"]}. Datenbank nicht automatisch zurückspielen.' if backups.get('backup') else ''
                if stage == 'health':
                    hint = self.rollback(config, previous) + hint
                elif stage != 'backup':
                    hint += f' Vorher lief Release {previous["release"]}, Compose-Datei in {self.paths.prev_compose}.'
                raise Rejected(stage, f'{error}{hint}') from error
            receipt = {'commit': sha, 'run_id': run['id'], 'run_attempt': run.get('run_attempt') or 1, 'verify_job_id': job['id'],
                       'artifact_id': artifact['id'], 'release': last['release'], 'previous_release': previous['release'],
                       **backups, 'deployed_at': stamp()}
            write_json(self.paths.deployed, receipt)
            self.paths.failed.unlink(missing_ok=True)
            self.notify(f'Theater-App {sha[:7]} ist live (Release {last["release"]}). Backup: {pathlib.Path(backups.get("backup", "unbekannt")).name}.')
            try:
                self.prune(config, {last['release'], previous['release'], previous.get('live_release')})
            except Exception as error:
                self.out(f'Aufräumen fehlgeschlagen: {error!r}')
            return 'deployed'
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def record(self, sha, stage, message, notified=False):
        run = getattr(self, 'current_run', None) or {}
        key = attempt_key(run, getattr(self, 'current_job', None)) if run else {}
        write_json(self.paths.failed, {'commit': sha, 'run_id': run.get('id'), 'run_attempt': run.get('run_attempt') or 1, **key,
                                       'stage': stage, 'message': message, 'failed_at': stamp(), **({'notified': True} if notified else {})})

    def record_failure(self, error, sha):
        self.record(sha, error.stage, str(error), notified=True)
        prefix = 'kein Deploy, CI rot' if error.stage == 'ci' else f'Deploy abgebrochen ({error.stage})'
        self.notify(f'Theater-App {sha[:7]}: {prefix}. {error}')

    def report_unnotified(self, sha):
        """A round killed mid-deploy leaves only the marker; report it once instead of skipping silently."""
        record = read_json(self.paths.failed)
        if record.get('notified') or self.dry_run:
            return
        self.notify(f'Theater-App {sha[:7]}: {record.get("message", "Deploy unterbrochen.")} Neuestes Backup: {self.newest_backup()}. '
                    'Datenbank nicht automatisch zurückspielen. Erneut versuchen mit --retry.')
        record['notified'] = True
        write_json(self.paths.failed, record)

    def alert(self, key, text, every):
        if self.dry_run:
            self.out(text)
            return
        alerts = read_json(self.paths.alerts)
        last = alerts.get(key)
        if last and utc_now() - parse_time(last) < every:
            self.out(text)
            return
        alerts = {name: value for name, value in alerts.items() if name == 'error-since' or utc_now() - parse_time(value) < ALERT_RETENTION}
        alerts[key] = stamp()
        try:
            write_json(self.paths.alerts, alerts)
        except OSError as error:
            # Disk full must not swallow the alert.
            self.out(f'alerts.json nicht schreibbar: {error}')
        self.notify(text)

    def report_error(self, error):
        """Errors outside a deploy (network, git, disk, corrupt clone) repeat every minute. Alert once they
        have lasted ERROR_GRACE, then every 6 hours; a clean round resets the clock."""
        try:
            alerts = read_json(self.paths.alerts)
            since = alerts.get('error-since')
            if not since:
                since = alerts['error-since'] = stamp()
                if not self.dry_run:
                    write_json(self.paths.alerts, alerts)
            if self.dry_run or utc_now() - parse_time(since) >= ERROR_GRACE:
                self.alert('error', f'Theater-Auto-Deploy-Fehler seit {since}: {error!r}', datetime.timedelta(hours=6))
        except Exception as nested:
            print(f'Fehlermeldung nicht möglich: {nested!r}', flush=True)

    def clear_error(self):
        alerts = read_json(self.paths.alerts)
        if 'error-since' in alerts and not self.dry_run:
            del alerts['error-since']
            write_json(self.paths.alerts, alerts)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Deploy the current main commit after a green verify job (one round).')
    parser.add_argument('--dry-run', action='store_true', help='Download, check and check out, test version-web.mjs and the rollback point; no backup, no rollout, no state')
    parser.add_argument('--retry', action='store_true', help='Ignore failed.json for the current commit once')
    parser.add_argument('--once', action='store_true', help='One round, then exit (default; for systemd)')
    args = parser.parse_args(argv)
    os.umask(0o077)
    paths = Paths(os.environ.get('THEATER_AUTODEPLOY_HOME', '~/projects/theater-autodeploy'))
    if paths.src.resolve() in pathlib.Path(__file__).resolve().parents:
        raise SystemExit('Run the installed copy, not the clone that this script updates.')
    paths.prepare()
    with paths.lock.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Ein anderer Theater-Deploy hält die Sperre; dieser Durchgang endet.', flush=True)
            return 0
        deployer = AutoDeploy(paths, None, dry_run=args.dry_run, retry=args.retry, out=lambda text: print(text, flush=True))
        sha = None
        try:
            deployer.github = github = GitHub(private_file(os.environ.get('GH_TOKEN_FILE', ''), 'GH_TOKEN_FILE'))
            sha = github.main_sha()
            status = deployer.round(sha)
            if status == 'failed-before':
                print(f'{sha[:7]} ist bereits als fehlgeschlagen vermerkt (state/failed.json); --retry oder neuer verify-Lauf.', flush=True)
                deployer.report_unnotified(sha)
            deployer.clear_error()
            return 0
        except Skip as skip:
            print(skip, flush=True)
            deployer.clear_error()
            return 0
        except Rejected as error:
            if args.dry_run:
                print(f'Probelauf fehlgeschlagen ({error.stage}): {error}', flush=True)
                return 1
            deployer.record_failure(error, sha)
            deployer.clear_error()
            return 1
        except GitHubError as error:
            if error.status in (401, 403):
                deployer.alert('github-auth', f'Theater-Auto-Deploy gestoppt: GitHub lehnt das Token ab ({error}). Token erneuern.', datetime.timedelta(days=1))
            else:
                deployer.report_error(error)
            raise
        except Exception as error:
            deployer.report_error(error)
            raise


if __name__ == '__main__':
    sys.exit(main())
