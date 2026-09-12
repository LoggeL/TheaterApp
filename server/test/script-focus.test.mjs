import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { ScriptFocusBridge } from '../src/script-focus.mjs';

function setup(t) {
 const store=new Store(); const theater=new Theater(store,{bootstrapEmail:'admin@example.invalid'});
 theater.session({uid:'admin',email:'admin@example.invalid',email_verified:true});
 store.put('productions','play',{id:'play',directorMemberIds:[]});store.put('scripts','play',{revision:'v1',cues:[{id:'cue',ordinal:1,sceneId:'1'}]});
 class FakeSocket extends EventEmitter {
  connected=false; sent=[];
  connect(){this.connected=true; super.emit('connect');}
  disconnect(){this.connected=false; super.emit('disconnect');}
  incoming(event,data){super.emit(event,data);}
  emit(event,data){this.sent.push([event,data]);queueMicrotask(()=>{
   if(event==='join_play')this.incoming('set_director',{director:'Niemand',isDirector:false,success:true});
   if(event==='set_director')this.incoming('set_director',{director:data.name,isDirector:true,success:true});
   if(event==='set_marker')this.incoming('marker_update',{...data,sequence:10});
   if(event==='clear_marker')this.incoming('marker_clear',{playId:'play',sequence:11});
  });return true;}
 }
 const socket=new FakeSocket(), bridge=new ScriptFocusBridge(theater,{url:'https://example.invalid',password:'test',socketFactory:()=>socket});
 t.after(()=>{bridge.close();store.close();});return {store,theater,bridge,socket};
}

test('app publishes canonical marker to the legacy room and recovers its clear',async t=>{
 const {bridge,socket}=setup(t);
 const initial=await bridge.focus('admin','play',null);
 const update=await bridge.focus('admin','play',{revision:'v1',cueId:'cue',sequence:initial.sequence});
 assert.equal(update.cueId,'cue');assert.equal(update.source,'skript');assert.equal(update.connected,true);
 assert.ok(socket.sent.some(([e,d])=>e==='set_marker'&&d.scriptRevision==='v1'&&d.ordinal===1));
 const clear=await bridge.focus('admin','play',{revision:'v1',cueId:null});assert.equal(clear.cueId,null);assert.ok(clear.sequence>update.sequence);
});
test('wrong revision, unknown cue and foreign room cannot corrupt app focus',async t=>{
 const {bridge,socket}=setup(t);await bridge.focus('admin','play',null);
 for(const change of [{playId:'other',scriptRevision:'v1',cueId:'cue'},{playId:'play',scriptRevision:'v2',cueId:'cue'},{playId:'play',scriptRevision:'v1',cueId:'missing'}])socket.incoming('marker_update',change);
 assert.equal((await bridge.focus('admin','play',null)).cueId,null);
 socket.incoming('marker_update',{playId:'play',scriptRevision:'v1',cueId:'cue',sequence:22});
 socket.incoming('marker_clear',{playId:'play',sequence:21});
 assert.equal((await bridge.focus('admin','play',null)).cueId,'cue');
});
test('member cannot claim legacy director and stale app writes are rejected',async t=>{
 const {bridge,theater,store,socket}=setup(t);theater.session({uid:'m',email:'m@example.invalid',email_verified:true});
 store.put('members',99,{id:99,name:'Member',active:true});store.saveAccount({...store.account('m'),personId:99,status:'approved'});
 await assert.rejects(()=>bridge.focus('m','play',{revision:'v1',cueId:'cue'}),e=>e.status===403);
 assert.equal(socket.sent.some(([e])=>e==='set_director'),false);
 await assert.rejects(()=>bridge.focus('admin','play',{revision:'old',cueId:'cue'}),e=>e.status===409);
});
