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
