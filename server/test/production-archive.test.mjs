import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, {bootstrapEmail: 'owner@example.invalid'});
  theater.session({uid:'owner',email:'owner@example.invalid',email_verified:true});
  let request = 0;
  const action = body => theater.action('owner', body, 'archive-' + ++request);
  const memberId = action({action:'member.save',name:'Mara Beispiel'}).id;
  theater.session({uid:'member',name:'Mara Beispiel',email:'member@example.invalid',email_verified:true});
  action({action:'account.approve',uid:'member',personId:memberId,version:1,role:'member'});
  const document = {productionId:'summer',revision:'r1',roles:[{id:'A',name:'Rolle A'}],scenes:[{id:'1',title:'Anfang',ordinal:0}],cues:[{id:'line',sceneId:'1',ordinal:0,kind:'dialogue',role:'A',text:'Der alte Text.'}]};
  theater.importScript('owner',{id:'summer',title:'Sommerstück 2025'},document);
  action({action:'production.save',id:'summer',version:1,title:'Sommerstück 2025',casting:{A:memberId},directorMemberIds:[memberId]});
  store.put('events','old-event',{id:'old-event',startsAt:'2025-07-12T17:00:00Z',productionId:'summer',sceneIds:['1']});
  store.put('comments','note',{id:'note',productionId:'summer',cueId:'line',text:'Eine Markierung'});
  return {store,theater,action,document,memberId};
}

test('archiving and restoring preserve script access, casting, comments and event links', t => {
  const {store,theater,action} = setup(t);
  const previous = store.get('productions','summer');
  const script = theater.script('member','summer'); delete script.fetchedAt;
  action({action:'production.archive',id:'summer',version:2,archived:true});
  const archived = theater.snapshot('member').productions.find(p=>p.id==='summer');
  assert.deepEqual(archived,{...previous,archived:true,version:3});
  const after = theater.script('member','summer'); delete after.fetchedAt;
  assert.deepEqual(after,script);
  assert.equal(store.get('events','old-event').productionId,'summer');
  assert.equal(store.get('comments','note').text,'Eine Markierung');
  action({action:'production.archive',id:'summer',version:3,archived:false});
  assert.deepEqual(store.get('productions','summer'),{...previous,archived:false,version:4});
});

test('only admins can archive and stale versions or invalid flags cannot change production state', t => {
  const {store,theater,action} = setup(t);
  const before = store.get('productions','summer');
  assert.throws(()=>theater.action('member',{action:'production.archive',id:'summer',version:2,archived:true},'member-archive'),{status:403});
  assert.throws(()=>action({action:'production.archive',id:'summer',version:1,archived:true}),{status:409});
  assert.throws(()=>action({action:'production.archive',id:'summer',version:2,archived:'true'}),{status:400});
  assert.throws(()=>action({action:'production.archive',id:'missing',version:2,archived:true}),{status:404});
  assert.deepEqual(store.get('productions','summer'),before);
});

test('reimport and older casting clients retain the archived status', t => {
  const {store,theater,action,document,memberId} = setup(t);
  action({action:'production.archive',id:'summer',version:2,archived:true});
  theater.importScript('owner',{id:'summer',title:'Sommerstück 2025',archived:false},{...document,revision:'r2'});
  assert.equal(store.get('productions','summer').archived,true);
  assert.deepEqual(store.get('productions','summer').casting,{A:memberId});
  action({action:'production.save',id:'summer',version:4,title:'Sommerstück 2025',casting:{A:memberId},directorMemberIds:[memberId]});
  assert.equal(store.get('productions','summer').archived,true);
});
