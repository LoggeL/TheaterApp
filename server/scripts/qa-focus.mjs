import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { io } from 'socket.io-client';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { ScriptFocusBridge } from '../src/script-focus.mjs';
const password=(await readFile(new URL('../../.secrets/script-director-password',import.meta.url),'utf8')).trim();
const id='theater-app-qa-'+Date.now(),store=new Store(),theater=new Theater(store,{bootstrapEmail:'qa@example.invalid'});
theater.session({uid:'qa',email:'qa@example.invalid',email_verified:true});
store.put('productions',id,{id,directorMemberIds:[]});store.put('scripts',id,{revision:'qa-v1',cues:[{id:'cue-1',ordinal:1,sceneId:'1'}]});
const bridge=new ScriptFocusBridge(theater,{url:'https://skript.logge.top',password});
const observer=io('https://skript.logge.top',{forceNew:true,autoConnect:false,transports:['websocket']});
const wait=(event,predicate=()=>true)=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>{observer.off(event,listener);reject(new Error('timeout '+event));},10000);const listener=d=>{if(predicate(d)){clearTimeout(timer);observer.off(event,listener);resolve(d);}};observer.on(event,listener);});
try {
 const joined=wait('set_director');observer.on('connect',()=>observer.emit('join_play',{playId:id}));observer.connect();await joined;
 const initial=await bridge.focus('qa',id,null);
 const marker=wait('marker_update');await bridge.focus('qa',id,{revision:'qa-v1',cueId:'cue-1',sequence:initial.sequence});assert.equal((await marker).cueId,'cue-1');
 const takeover=wait('director_takeover',d=>d.isDirector);observer.emit('set_director',{name:'QA Skript-Browser',password});await takeover;
 const clear=wait('marker_clear');observer.emit('clear_marker');await clear;
 assert.equal((await bridge.focus('qa',id,null)).cueId,null);
 const update=wait('marker_update');observer.emit('set_marker',{playId:id,protocolVersion:2,scriptRevision:'qa-v1',cueId:'cue-1',ordinal:1});await update;
 // Both sockets receive the same server event; give the bridge's socket its turn.
 await new Promise(resolve=>setTimeout(resolve,100));
 assert.equal((await bridge.focus('qa',id,null)).cueId,'cue-1');
 console.log('Live Skript bridge: app → browser marker, browser → app clear and marker verified in isolated QA room.');
} finally {observer.disconnect();bridge.close();store.close();}
