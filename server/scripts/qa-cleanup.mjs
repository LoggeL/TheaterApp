import { initializeApp,applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { readFile,unlink } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const auth=getAuth(initializeApp({projectId:'theater-app-6fa5d',credential:applicationDefault()}));
const root=new URL('../../',import.meta.url);
const files=process.argv.includes('--pending-only')?['.secrets/qa-production-cleanup.json']:['.secrets/qa-production-cleanup.json','.secrets/qa-native.json'];
for(const file of files){
 let data;try{data=JSON.parse(await readFile(new URL(file,root)));}catch(e){if(e.code==='ENOENT')continue;throw e;}
 const uid=data.uid??data.QA_UID;
 try{const u=await auth.getUser(uid);if(!u.email.endsWith('@theater.test'))throw new Error('Refusing to remove non-QA user');await auth.deleteUser(uid);}catch(e){if(e.code!=='auth/user-not-found')throw e;}
 const command=`import {Store} from './src/store.mjs';const s=new Store('/data/theater.sqlite');const uid=${JSON.stringify(uid)},a=s.account(uid);if(a){const personId=a.personId;for(const kind of ['responses','checkins','receipts','reminders','absences','devices','messages','pushJobs'])for(const r of s.db.prepare('SELECT id,data FROM entities WHERE kind=?').all(kind)){const d=JSON.parse(r.data);if(d.personId===personId||d.uid===uid||d.authorId===personId||(kind==='pushJobs'&&d.recipientPersonIds?.length===1&&d.recipientPersonIds[0]===personId))s.delete(kind,r.id);}s.delete('members',personId);s.db.prepare('DELETE FROM accounts WHERE uid=?').run(uid);s.db.prepare('DELETE FROM requests WHERE uid=?').run(uid);}s.close();`;
 const r=spawnSync('ssh',['-i','/Users/logge/.ssh/id_ed25519_homebox','-o','IdentitiesOnly=yes','-o','BatchMode=yes','logge@192.168.178.46','docker exec -i compose-calculate-neural-driver-q79whz-theater-1 node --input-type=module'],{input:command,encoding:'utf8'});
 if(r.status)throw new Error('Server QA cleanup failed');await unlink(new URL(file,root));console.log('Disposable QA account and related test data removed.');
}
