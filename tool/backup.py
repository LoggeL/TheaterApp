#!/usr/bin/env python3
"""Download a consistent backup from the Theater-App container without stopping it."""
from pathlib import Path
import json,subprocess,datetime,shlex,os,sqlite3
from deploy import api
root=Path(__file__).resolve().parents[1]; c=json.loads((root/'config/dokploy.json').read_text())
app=api('compose.one?composeId='+c['composeId']); app_name=app['appName']
ssh=['ssh','-i',str(Path(c['sshKey']).expanduser()),'-o','IdentitiesOnly=yes','-o','BatchMode=yes',c['sshHost']]
ps=subprocess.run(ssh+['docker ps --filter '+shlex.quote('label=com.docker.compose.project='+app_name)+' --filter label=com.docker.compose.service=theater --format "{{.Names}}"'],capture_output=True,text=True,check=True)
containers=ps.stdout.splitlines()
if len(containers)!=1:raise RuntimeError('Expected exactly one running Theater-App container')
name=containers[0]
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
remote=f'/tmp/theater-backup-{stamp}.sqlite'
js=f"import {{DatabaseSync,backup}} from 'node:sqlite';const db=new DatabaseSync('/data/theater.sqlite');await backup(db,{json.dumps(remote)});db.close();"
subprocess.run(ssh+[f'docker exec {shlex.quote(name)} node --input-type=module -e {shlex.quote(js)}'],check=True)
folder=root/'.secrets/backups';folder.mkdir(parents=True,exist_ok=True,mode=0o700)
dest=folder/f'theater-{stamp}.sqlite'
with dest.open('xb') as f:
 os.chmod(dest,0o600)
 subprocess.run(ssh+[f'docker exec {shlex.quote(name)} cat {shlex.quote(remote)}'],stdout=f,check=True)
subprocess.run(ssh+[f'docker exec {shlex.quote(name)} rm {shlex.quote(remote)}'],check=True)
with sqlite3.connect(dest) as db:
 if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise RuntimeError('Backup integrity check failed')
print(f'Consistent backup verified: {dest}')

# Media files are immutable and are written before their database record.
# Copying them after the SQLite snapshot includes every referenced image.
media_dest = folder/f'theater-{stamp}-media.tar.gz'
command = f'docker exec {shlex.quote(name)} sh -c '+shlex.quote('if [ -d /data/media ]; then tar czf - -C /data media; else tar czf - --files-from /dev/null; fi')
with media_dest.open('xb') as f:
 os.chmod(media_dest, 0o600)
 subprocess.run(ssh+[command], stdout=f, check=True)
import tarfile
with tarfile.open(media_dest, 'r:gz') as archive:
 with sqlite3.connect(dest) as db:
  records = [json.loads(row[0]) for row in db.execute("SELECT data FROM entities WHERE kind='media'")]
 files = set(archive.getnames())
 for record in records:
  if 'media/'+record['id']+'.webp' not in files: raise RuntimeError('A referenced media file is missing from the backup')
print(f'Media backup verified: {media_dest} ({len(records)} referenced images)')
