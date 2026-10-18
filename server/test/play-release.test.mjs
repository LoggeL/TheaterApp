import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { runRelease } from '../scripts/play-release.mjs';

const packageName = 'de.kolpingtheater.ramsen.theaterapp';
const base = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}`;
const state = { packageName, track: 'alpha', editId: 'test-edit', versionName: '0.7.0', versionCode: 15, commit: 'test-commit' };

async function fixture(t, releaseState = state) {
  const directory = await mkdtemp(join(tmpdir(), 'theater-play-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const statePath = join(directory, 'state.json');
  await writeFile(statePath, JSON.stringify(releaseState));
  const messages = [];
  return {
    statePath,
    env: { GITHUB_SHA: 'test-commit', GITHUB_STEP_SUMMARY: join(directory, 'summary.md') },
    log: message => messages.push(message),
    messages,
    directory,
  };
}

test('prepare binds a new release to the closed track and allocates a higher version code', async t => {
  const setup = await fixture(t);
  const requests = [];
  await runRelease({ ...setup, mode: 'prepare', request: async (url, method = 'GET') => {
    requests.push([url, method]);
    if (url === `${base}/edits` && method === 'POST') return { id: 'new-edit' };
    if (url === `${base}/edits/new-edit/bundles`) return { bundles: [{ versionCode: 100 }] };
    throw new Error(`Unexpected request: ${method} ${url}`);
  } });
  const prepared = JSON.parse(await readFile(setup.statePath, 'utf8'));
  assert.equal(prepared.track, 'alpha');
  assert.equal(prepared.versionCode, 101);
  assert.equal(prepared.commit, 'test-commit');
  assert.equal(prepared.editId, 'new-edit');
  assert.equal(requests.length, 2);
});

test('publish sends the bundle only to alpha and reports submission instead of availability', async t => {
  const setup = await fixture(t);
  const bundlePath = join(setup.directory, 'bundle.aab');
  await writeFile(bundlePath, 'test bundle');
  const requests = [];
  await runRelease({ ...setup, mode: 'publish', bundlePath, request: async (url, method = 'GET', data) => {
    requests.push([url, method, data]);
    if (url.includes('/upload/')) {
      for await (const chunk of data) assert.equal(chunk.toString(), 'test bundle');
      return { versionCode: 15, sha256: 'test-sha256' };
    }
    return {};
  } });
  assert.equal(requests.length, 4);
  assert.equal(requests[1][0], `${base}/edits/test-edit/tracks/alpha`);
  assert.equal(requests[1][1], 'PUT');
  assert.equal(requests[1][2].track, 'alpha');
  assert.deepEqual(requests[1][2].releases[0].versionCodes, ['15']);
  assert.equal(requests[2][0], `${base}/edits/test-edit:validate`);
  // Sent for review explicitly, never parked as "changes not sent for review".
  assert.equal(requests[3][0], `${base}/edits/test-edit:commit?changesNotSentForReview=false`);
  assert.match(setup.messages[0], /^Submitted closed testing release/);
  assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).bundleSha256, 'test-sha256');
});

// A fake clock: sleeping advances it, so polling tests run instantly.
function clock() {
  let at = Date.parse('2026-10-18T16:20:00Z');
  const sleeps = [];
  return { now: () => at, sleep: async ms => { sleeps.push(ms); at += ms; }, sleeps };
}
const releaseWith = (lifecycle, versionCode = 15) => ({ track: 'alpha', releaseName: `0.7.0 (${versionCode})`, activeArtifacts: [{ versionCode }], releaseLifecycleState: lifecycle });

for (const [suffix, status, description] of [
  ['IN_REVIEW', 'in_review', 'In Google review; not yet available'],
  ['APPROVED_NOT_PUBLISHED', 'approved_not_published', 'Approved; waiting for publication'],
  ['PUBLISHED', 'available', 'Published and available'],
]) {
  test(`verify reads the release lifecycle without an edit and reports ${suffix}`, async t => {
    const setup = await fixture(t);
    const lifecycle = `RELEASE_LIFECYCLE_STATE_${suffix}`;
    const time = clock();
    let requests = 0;
    await runRelease({ ...setup, ...time, mode: 'verify', request: async (url, method = 'GET') => {
      requests++;
      assert.equal(url, `${base}/tracks/alpha/releases`);
      assert.equal(method, 'GET');
      return { releases: [releaseWith(lifecycle)] };
    } });
    assert.equal(requests, 1);
    assert.deepEqual(time.sleeps, []);
    const summary = await readFile(setup.env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.ok(summary.includes(lifecycle));
    assert.ok(summary.includes(`(${status})`));
    assert.ok(summary.includes(description));
    assert.ok(summary.includes(`https://play.google.com/apps/testing/${packageName}`));
    const verified = JSON.parse(await readFile(setup.statePath, 'utf8'));
    assert.equal(verified.releaseLifecycleState, lifecycle);
    assert.equal(verified.reviewStatus, status);
    assert.match(setup.messages.at(-1), new RegExp(`^Verified closed testing release 0.7.0 \\(15\\): ${lifecycle} \\(${status}\\)`));
  });
}

test('verify waits while Google still reports the fresh release as not sent for review', async t => {
  // As in run 39143454245: right after the commit the release is missing or not yet sent.
  const setup = await fixture(t);
  const time = clock();
  const answers = [
    { releases: [releaseWith('RELEASE_LIFECYCLE_STATE_PUBLISHED', 14)] },
    { releases: [releaseWith('RELEASE_LIFECYCLE_STATE_NOT_SENT_FOR_REVIEW')] },
    { releases: [releaseWith('RELEASE_LIFECYCLE_STATE_DRAFT')] },
    { releases: [releaseWith('RELEASE_LIFECYCLE_STATE_IN_REVIEW')] },
  ];
  await runRelease({ ...setup, ...time, env: { ...setup.env, PLAY_VERIFY_INTERVAL_MS: '30000' }, mode: 'verify', request: async () => answers.shift() });
  assert.equal(answers.length, 0);
  assert.deepEqual(time.sleeps, [30000, 30000, 30000]);
  const verified = JSON.parse(await readFile(setup.statePath, 'utf8'));
  assert.equal(verified.reviewStatus, 'in_review');
  assert.equal(verified.checks, 4);
  assert.match(setup.messages[1], /Check 2 after 30 s: 0.7.0 \(15\): RELEASE_LIFECYCLE_STATE_NOT_SENT_FOR_REVIEW/);
});

for (const suffix of ['NOT_SENT_FOR_REVIEW', 'DRAFT', 'UNSPECIFIED']) {
  test(`verify reports ${suffix} as not submitted once the wait is over`, async t => {
    const setup = await fixture(t);
    const lifecycle = `RELEASE_LIFECYCLE_STATE_${suffix}`;
    const time = clock();
    let requests = 0;
    await assert.rejects(runRelease({ ...setup, ...time, env: { ...setup.env, PLAY_VERIFY_TIMEOUT_MS: '120000', PLAY_VERIFY_INTERVAL_MS: '30000' }, mode: 'verify', request: async () => {
      requests++;
      return { releases: [releaseWith(lifecycle)] };
    } }), new RegExp(`${lifecycle} \\(not_submitted\\)`));
    // Checks at 0, 30, 60, 90 and 120 s, never beyond the timeout.
    assert.equal(requests, 5);
    assert.ok(time.sleeps.reduce((a, b) => a + b, 0) <= 120000);
    const summary = await readFile(setup.env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.ok(summary.includes(`${lifecycle} (not_submitted)`));
    assert.ok(!summary.includes('available'));
    assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).reviewStatus, 'not_submitted');
  });
}

for (const [suffix, status] of [['NOT_APPROVED', 'rejected'], ['SOMETHING_NEW', 'unknown']]) {
  test(`verify fails at once for ${suffix} instead of reporting successful delivery`, async t => {
    const setup = await fixture(t);
    const lifecycle = `RELEASE_LIFECYCLE_STATE_${suffix}`;
    const time = clock();
    await assert.rejects(runRelease({ ...setup, ...time, mode: 'verify', request: async () => ({ releases: [releaseWith(lifecycle)] }) }), new RegExp(`${lifecycle} \\(${status}\\)`));
    assert.deepEqual(time.sleeps, []);
    assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).reviewStatus, status);
  });
}

test('verify rejects a different version even if it is published', async t => {
  const setup = await fixture(t);
  const time = clock();
  await assert.rejects(runRelease({ ...setup, ...time, env: { ...setup.env, PLAY_VERIFY_TIMEOUT_MS: '60000' }, mode: 'verify', request: async () => ({
    releases: [{ track: 'alpha', releaseName: 'old', activeArtifacts: [{ versionCode: 10 }], releaseLifecycleState: 'RELEASE_LIFECYCLE_STATE_PUBLISHED' }],
  }) }), /Submitted version not found/);
  assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).reviewStatus, 'not_submitted');
});

test('old, mismatched or foreign release states are rejected before any API request', async t => {
  for (const change of [{ track: 'internal' }, { track: undefined }, { commit: 'old-commit' }, { packageName: 'other.app' }]) {
    const setup = await fixture(t, { ...state, ...change });
    for (const mode of ['publish', 'verify']) {
      await assert.rejects(runRelease({ ...setup, mode, request: async () => {
        assert.fail('Invalid state must not reach the API');
      } }), /release state|different commit/);
    }
  }
});
