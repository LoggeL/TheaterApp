#!/usr/bin/env python3
"""Build a web release and deploy its immutable Docker image to the existing Dokploy app.
Secrets stay in macOS Keychain / the server's private bind mount.
"""
import argparse, hashlib, json, pathlib, shlex, subprocess, tarfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
CFG = ROOT / 'config/dokploy.json'

def run(args, **kw):
    return subprocess.run(args, cwd=ROOT, check=True, **kw)

def api(path, payload=None):
    key = subprocess.check_output(['security', 'find-generic-password', '-s', 'dokploy.logge.top API Key', '-w'], text=True).strip()
    config = 'header = ' + json.dumps('x-api-key: ' + key) + '\n'
    if payload is not None:
        config += 'request = "POST"\nheader = "Content-Type: application/json"\ndata = ' + json.dumps(json.dumps(payload)) + '\n'
    r = run(['curl', '--config', '-', '-sS', '--max-time', '45', '-w', '\n%{http_code}', 'https://dokploy.logge.top/api/' + path], input=config, text=True, capture_output=True)
    body, _, status = r.stdout.rpartition('\n')
    if status != '200':
        raise RuntimeError(f'Dokploy {path}: HTTP {status}')
    return json.loads(body)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-build', action='store_true', help='Use the existing production build/web after checking config')
    args = parser.parse_args()
    c = json.loads(CFG.read_text())
    if not args.skip_build:
        run(['node', 'tool/configure.mjs', 'config/production.web.json'])
        run(['flutter', 'build', 'web', '--release', '--dart-define-from-file=config/production.web.json', '--pwa-strategy=none'])
    run(['node', 'tool/version-web.mjs'])
    # The SW config must belong to the same production project as the backend.
    if c['firebaseProjectId'] not in (ROOT/'build/web/firebase-web-config.js').read_text():
        raise RuntimeError('build/web contains another Firebase configuration; build the production app first.')
    files = [ROOT/'Dockerfile', ROOT/'server/package.json', ROOT/'server/package-lock.json']
    files += sorted(p for p in (ROOT/'server/src').rglob('*') if p.is_file())
    files += [ROOT/'server/scripts/bootstrap-admin.mjs']
    files += sorted(p for p in (ROOT/'build/web').rglob('*') if p.is_file())
    digest = hashlib.sha256()
    for f in files:
        digest.update(str(f.relative_to(ROOT)).encode()); digest.update(f.read_bytes())
    release = digest.hexdigest()[:20]
    artifacts = ROOT/'artifacts'; artifacts.mkdir(exist_ok=True)
    archive = artifacts/f'deploy-{release}.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for f in files: tar.add(f, arcname=str(f.relative_to(ROOT)), recursive=False)
    ssh = ['ssh', '-i', str(pathlib.Path(c['sshKey']).expanduser()), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', c['sshHost']]
    remote = c['remotePath']; context = f'{remote}/releases/{release}'
    command = f'mkdir -p {shlex.quote(context)} && tar xzf - -C {shlex.quote(context)} && docker build --build-arg RELEASE_SHA={release} -t theater-app:{release} {shlex.quote(context)}'
    with archive.open('rb') as stream: run(ssh+[command], stdin=stream)
    compose = f'''services:
  theater:
    image: theater-app:{release}
    pull_policy: never
    restart: unless-stopped
    environment:
      NODE_ENV: production
      FIREBASE_PROJECT_ID: {c['firebaseProjectId']}
      GOOGLE_APPLICATION_CREDENTIALS: /run/secrets/firebase-service-account.json
      AUTH_PROVIDERS: password,google.com
      ALLOWED_ORIGINS: https://{c['host']}
      APP_ORIGIN: https://{c['host']}
      SCRIPT_SERVICE_URL: https://skript.logge.top/
      SCRIPT_CACHE_DIR: /data/mobile-script-cache
      SCRIPT_FOCUS_BRIDGE: 'true'
      SCRIPT_DIRECTOR_PASSWORD_FILE: /run/secrets/script-director-password
      MOBILE_PUSH_ENABLED: 'true'
    volumes:
      - {remote}/data:/data:Z
      - {remote}/secrets/firebase-service-account.json:/run/secrets/firebase-service-account.json:ro,Z
      - {remote}/secrets/script-director-password:/run/secrets/script-director-password:ro,Z
    expose:
      - '8787'
    mem_limit: 512m
    cpus: 1.0
'''
    compose_id = c.get('composeId')
    if not compose_id:
        # Recover an interrupted first deployment without creating a duplicate.
        matches = [app for p in api('project.all') for e in p.get('environments', []) if e['environmentId'] == c['environmentId'] for app in e.get('compose', []) if app['name'] == 'Theater-App']
        if len(matches) > 1: raise RuntimeError('Multiple Theater-App services found; inspect Dokploy before proceeding.')
        app = matches[0] if matches else api('compose.create', {'name': 'Theater-App', 'environmentId': c['environmentId'], 'description': 'Flutter Theater-App mit Firebase Auth und persistentem Probenbackend', 'sourceType': 'raw', 'composeType': 'docker-compose', 'composeFile': compose})
        compose_id = c['composeId'] = app['composeId']
        CFG.write_text(json.dumps(c, indent=2)+'\n')
    api('compose.update', {'composeId': compose_id, 'composeFile': compose, 'sourceType': 'raw', 'composeType': 'docker-compose'})
    details = api('compose.one?composeId='+compose_id)
    if not any(d['host'] == c['host'] for d in details.get('domains', [])):
        api('domain.create', {'host': c['host'], 'composeId': compose_id, 'serviceName': 'theater', 'domainType': 'compose', 'path': '/', 'internalPath': '/', 'port': 8787, 'https': True, 'certificateType': 'letsencrypt', 'stripPath': False})
    api('compose.deploy', {'composeId': compose_id, 'title': 'Theater-App '+release, 'description': 'Geprüfter Flutter-Web-Build mit Firebase Auth'})
    (artifacts/'last-deploy.json').write_text(json.dumps({'release': release, 'composeId': compose_id, 'url': 'https://'+c['host']}, indent=2)+'\n')
    print(f'Deployment started: https://{c["host"]} (release {release}). Verify /api/healthz before reporting completion.')

if __name__ == '__main__': main()
