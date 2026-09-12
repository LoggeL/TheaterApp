// Explicit integration test against this project's production test instance.
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { readFile, writeFile } from 'node:fs/promises';
import { randomBytes, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url),config=JSON.parse(await readFile(new URL('.secrets/qa-native.json',root)));
const auth=getAuth(initializeApp({projectId:config.FIREBASE_PROJECT_ID,credential:applicationDefault()}));
async function login(email,password){const r=await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${config.FIREBASE_API_KEY}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});const data=await r.json();if(!r.ok)throw new Error('Firebase sign-in failed');return data.idToken;}
const adminToken=await login(config.QA_EMAIL,config.QA_PASSWORD);
async function api(token,path,body,status=200){const r=await fetch(config.API_BASE_URL+'/api/mobile/v1'+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','Idempotency-Key':randomUUID()},...(body?{body:JSON.stringify(body)}:{})});assert.equal(r.status,status,`Unexpected status for ${path}`);return r.json();}
const password=randomBytes(24).toString('base64url');const user=await auth.createUser({email:`qa-pending-${Date.now()}@theater.test`,password,emailVerified:false});
const cleanup={uid:user.uid};await writeFile(new URL('.secrets/qa-production-cleanup.json',root),JSON.stringify(cleanup),{mode:0o600});
let token=await login(user.email,password);
let session=(await api(token,'/auth/session',{})).user;assert.equal(session.status,'pending');assert.equal(session.identityReady,false);
await api(token,'/snapshot',null,403);
await auth.updateUser(user.uid,{emailVerified:true});token=await login(user.email,password);session=(await api(token,'/auth/session',{})).user;assert.equal(session.status,'pending');await api(token,'/snapshot',null,403);
const person=await api(adminToken,'/actions',{action:'member.save',name:'Temporäre Freigabeprüfung',group:'QA',active:true});cleanup.personId=person.id;await writeFile(new URL('.secrets/qa-production-cleanup.json',root),JSON.stringify(cleanup),{mode:0o600});
let account=(await api(adminToken,'/admin/accounts')).accounts.find(a=>a.uid===user.uid);
await api(adminToken,'/actions',{action:'account.approve',uid:user.uid,personId:person.id,version:account.version,role:'member'});
session=(await api(token,'/auth/session',{})).user;assert.equal(session.status,'approved');assert.equal(session.personId,person.id);
let snapshot=await api(token,'/snapshot');assert.ok(snapshot.productions.length>=2);assert.equal(snapshot.pendingAccounts.length,0);
const event=snapshot.events.find(e=>e.id==='testprobe');
const eta=new Date(Date.parse(event.startsAt)+1800000).toISOString();
await api(token,'/actions',{action:'attendance',eventId:event.id,status:'late',expectedArrivalAt:eta});snapshot=await api(token,'/snapshot');assert.equal(snapshot.attendanceByEvent[event.id],'late');assert.equal(snapshot.expectedArrivals[event.id],eta);
await api(token,'/actions',{action:'member.save',name:'Illegal admin change'},403);
const message=await api(adminToken,'/actions',{action:'message.send',audience:'selected',title:'Temporäre QA-Mitteilung',body:'Nur für die automatische Abnahme.',recipientPersonIds:[person.id],push:false});cleanup.messageId=message.id;await writeFile(new URL('.secrets/qa-production-cleanup.json',root),JSON.stringify(cleanup),{mode:0o600});
snapshot=await api(token,'/snapshot');assert.ok(snapshot.messages.some(m=>m.id===message.id));
await api(token,'/actions',{action:'message.read',id:message.id});snapshot=await api(token,'/snapshot');assert.equal(snapshot.messages.find(m=>m.id===message.id).read,true);
account=(await api(adminToken,'/admin/accounts')).accounts.find(a=>a.uid===user.uid);
await api(adminToken,'/actions',{action:'account.status',uid:user.uid,status:'suspended',version:account.version});await api(token,'/snapshot',null,403);
console.log('Live API verified: pending + unverified denied; explicit person approval; late arrival persisted; member admin-write denied; targeted message and read receipt; suspension enforced.');
await auth.deleteUser(user.uid);
