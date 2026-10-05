import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  let current = new Date('2026-10-05T12:00:00Z');
  const theater = new Theater(store, { bootstrapEmail: 'owner@example.invalid', clock: () => current });
  theater.session({ uid: 'owner', email: 'owner@example.invalid', name: 'Theaterleitung', email_verified: true });
  let request = 0;
  const action = (body, uid = 'owner') => theater.action(uid, body, `privacy-${++request}`);
  const personId = action({ action: 'member.save', name: 'Mara Beispiel' }).id;
  theater.session({ uid: 'member', name: 'Mara Beispiel', email: 'member@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'member', personId, version: 1, role: 'member' });
  const body = { action: 'poll.save', title: 'Probenpause', options: [{ label: 'Drinnen' }, { label: 'Draußen' }], closesAt: '2026-10-06T12:00:00Z' };
  return { store, theater, action, personId, body, setClock: value => { current = new Date(value); } };
}

test('new and legacy polls stay anonymous and expose no voter names to members or admins', t => {
  const { store, theater, action, body } = setup(t);
  const id = action(body).id;
  const poll = store.get('polls', id);
  action({ action: 'poll.vote', pollId: id, optionId: poll.options[0].id }, 'member');
  for (const uid of ['owner', 'member']) {
    const view = theater.snapshot(uid).polls[0];
    assert.equal(view.anonymous, true);
    assert.equal(view.options[0].votes, 1);
    assert(!JSON.stringify(view).includes('Mara Beispiel'));
    assert(view.options.every(o => !('voters' in o)));
  }
  // The output must not trust stale voter arrays inside legacy option records.
  delete poll.anonymous;
  poll.options[0].voters = [{ personId: 999, name: 'MUST NOT LEAK' }];
  store.put('polls', id, poll);
  assert(!JSON.stringify(theater.snapshot('owner').polls).includes('MUST NOT LEAK'));
  assert.equal(theater.snapshot('member').polls[0].anonymous, true);
});

test('named votes reveal the member name and move it when a person changes answers', t => {
  const { store, theater, action, body, personId } = setup(t);
  const id = action({ ...body, anonymous: false }).id;
  const poll = store.get('polls', id);
  action({ action: 'poll.vote', pollId: id, optionId: poll.options[0].id }, 'member');
  for (const uid of ['owner', 'member']) {
    const view = theater.snapshot(uid).polls[0];
    assert.equal(view.anonymous, false);
    assert.deepEqual(view.options[0].voters, [{ personId, name: 'Mara Beispiel' }]);
  }
  action({ action: 'poll.vote', pollId: id, optionId: poll.options[1].id }, 'member');
  const changed = theater.snapshot('member').polls[0];
  assert.deepEqual(changed.options.map(o => o.votes), [0, 1]);
  assert.deepEqual(changed.options[0].voters, []);
  assert.deepEqual(changed.options[1].voters, [{ personId, name: 'Mara Beispiel' }]);
});

test('privacy is editable before voting, fixed after voting, and preserved for older clients', t => {
  const { store, theater, action, body } = setup(t);
  assert.throws(() => action({ ...body, anonymous: 'false' }), { status: 400 });
  assert.throws(() => action({ ...body, anonymous: false }, 'member'), { status: 403 });
  const id = action(body).id;
  action({ ...body, id, version: 1, anonymous: false });
  const poll = store.get('polls', id);
  action({ action: 'poll.vote', pollId: id, optionId: poll.options[0].id }, 'member');
  assert.throws(() => action({ ...body, id, version: 2, anonymous: true }), { status: 409 });
  action({ ...body, id, version: 2, description: 'Older client edit' });
  assert.equal(theater.snapshot('member').polls[0].anonymous, false);
  const anonymousId = action(body).id;
  action({ action: 'poll.vote', pollId: anonymousId, optionId: store.get('polls', anonymousId).options[0].id }, 'member');
  assert.throws(() => action({ ...body, id: anonymousId, version: 1, anonymous: false }), { status: 409 });
});

test('deadline closes exactly at the configured instant and expired descriptions remain editable', t => {
  const { store, theater, action, body, setClock } = setup(t);
  assert.throws(() => action({ ...body, closesAt: '2026-10-05T11:59:00Z' }), { status: 400 });
  const id = action({ ...body, anonymous: false }).id;
  const poll = store.get('polls', id);
  setClock('2026-10-06T11:59:59Z');
  action({ action: 'poll.vote', pollId: id, optionId: poll.options[0].id }, 'member');
  setClock(body.closesAt);
  assert.equal(theater.snapshot('member').polls[0].closed, true);
  assert.throws(() => action({ action: 'poll.vote', pollId: id, optionId: poll.options[1].id }, 'member'), { status: 409 });
  action({ ...body, id, version: 1, anonymous: false, description: 'Ergebnis dokumentiert' });
  assert.equal(Date.parse(store.get('polls', id).closesAt), Date.parse(body.closesAt));
});
