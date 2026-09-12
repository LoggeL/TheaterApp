// Disposable QA identity. Never changes the real administrator's credentials.
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const root = new URL('../../', import.meta.url);
const auth=getAuth(initializeApp({projectId:'theater-app-6fa5d',credential:applicationDefault()}));
const file=new URL('.secrets/qa-native.json', root);
const ssh=['-i','/Users/logge/.ssh/id_ed25519_homebox','-o','IdentitiesOnly=yes','-o','BatchMode=yes','logge@192.168.178.46'];
const container='compose-calculate-neural-driver-q79whz-theater-1';
if(process.argv.includes('--cleanup')) {
 const c=JSON.parse(await readFile(file));
 await auth.deleteUser(c.QA_UID);
 const script=`import {Store} from './src/store.mjs';const s=new Store('/data/theater.sqlite');const a=s.account(${JSON.stringify(c.QA_UID)});if(a){for(const d of s.all('devices').filter(d=>d.uid===a.uid))s.delete('devices',d.id);s.delete('members',a.personId);s.db.prepare('DELETE FROM accounts WHERE uid=?').run(a.uid);}s.close();`;
 const r=spawnSync('ssh',[...ssh,`docker exec -i ${container} node --input-type=module`],{input:script,encoding:'utf8'});if(r.status)throw new Error('QA cleanup failed');
 console.log('Disposable Firebase QA account and server person removed.');process.exit(0);
}
const password=randomBytes(24).toString('base64url');
const user=await auth.createUser({email:`qa-${Date.now()}@theater.test`,password,emailVerified:true,displayName:'Temporärer Gerätetest'});
const config={...JSON.parse(await readFile(new URL('config/production.android.json',root))),QA_EMAIL:user.email,QA_PASSWORD:password,QA_UID:user.uid};
await writeFile(file,JSON.stringify(config),{mode:0o600,flag:'wx'});
const script=`import {Store} from './src/store.mjs';const s=new Store('/data/theater.sqlite');const id=Math.max(0,...s.all('members').map(m=>m.id))+1;s.put('members',id,{id,name:'Temporärer Gerätetest',group:'Test',initials:'QA',active:true,version:1});s.saveAccount({uid:${JSON.stringify(user.uid)},personId:id,status:'approved',role:'admin',email:${JSON.stringify(user.email)},name:'Temporärer Gerätetest',emailVerified:true,identityReady:true,provider:'password',version:1});s.close();`;
const r=spawnSync('ssh',[...ssh,`docker exec -i ${container} node --input-type=module`],{input:script,encoding:'utf8'});if(r.status)throw new Error('QA server setup failed');
console.log('Disposable QA identity created. Credentials saved privately.');
