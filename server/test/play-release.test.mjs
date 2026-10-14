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
  assert.equal(requests[3][0], `${base}/edits/test-edit:commit`);
  assert.match(setup.messages[0], /^Submitted closed testing release/);
  assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).bundleSha256, 'test-sha256');
});

for (const [suffix, description] of [
  ['IN_REVIEW', 'In Google review; not yet available'],
  ['APPROVED_NOT_PUBLISHED', 'Approved; waiting for publication'],
  ['PUBLISHED', 'Published and available'],
]) {
  test(`verify reads the release lifecycle without an edit and reports ${suffix}`, async t => {
    const setup = await fixture(t);
    const lifecycle = `RELEASE_LIFECYCLE_STATE_${suffix}`;
    let requests = 0;
    await runRelease({ ...setup, mode: 'verify', request: async (url, method = 'GET') => {
      requests++;
      assert.equal(url, `${base}/tracks/alpha/releases`);
      assert.equal(method, 'GET');
      return { releases: [{ track: 'alpha', releaseName: '0.7.0 (15)', activeArtifacts: [{ versionCode: 15 }], releaseLifecycleState: lifecycle }] };
    } });
    assert.equal(requests, 1);
    const summary = await readFile(setup.env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.ok(summary.includes(lifecycle));
    assert.ok(summary.includes(description));
    assert.ok(summary.includes(`https://play.google.com/apps/testing/${packageName}`));
    assert.equal(JSON.parse(await readFile(setup.statePath, 'utf8')).releaseLifecycleState, lifecycle);
  });
}

for (const suffix of ['NOT_SENT_FOR_REVIEW', 'NOT_APPROVED', 'DRAFT', 'UNSPECIFIED']) {
  test(`verify rejects ${suffix} instead of reporting successful delivery`, async t => {
    const setup = await fixture(t);
    const lifecycle = `RELEASE_LIFECYCLE_STATE_${suffix}`;
    await assert.rejects(runRelease({ ...setup, mode: 'verify', request: async () => ({
      releases: [{ track: 'alpha', releaseName: '0.7.0 (15)', activeArtifacts: [{ versionCode: 15 }], releaseLifecycleState: lifecycle }],
    }) }), new RegExp(lifecycle));
    await assert.rejects(readFile(setup.env.GITHUB_STEP_SUMMARY), { code: 'ENOENT' });
  });
}

test('verify rejects a different version even if it is published', async t => {
  const setup = await fixture(t);
  await assert.rejects(runRelease({ ...setup, mode: 'verify', request: async () => ({
    releases: [{ track: 'alpha', releaseName: 'old', activeArtifacts: [{ versionCode: 10 }], releaseLifecycleState: 'RELEASE_LIFECYCLE_STATE_PUBLISHED' }],
  }) }), /Submitted version not found/);
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
