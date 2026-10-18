import { createReadStream } from 'node:fs';
import { readFile, writeFile, appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { GoogleAuth } from 'google-auth-library';

const packageName = 'de.kolpingtheater.ramsen.theaterapp';
const trackName = 'alpha';
const base = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}`;
const testUrl = `https://play.google.com/apps/testing/${packageName}`;
// Outcome of a submitted release, by `releaseLifecycleState` of tracks.releases.list.
const outcomes = {
  RELEASE_LIFECYCLE_STATE_IN_REVIEW: { status: 'in_review', ok: true, description: 'In Google review; not yet available to closed testers.' },
  RELEASE_LIFECYCLE_STATE_APPROVED_NOT_PUBLISHED: { status: 'approved_not_published', ok: true, description: 'Approved; waiting for publication in Play Console (managed publishing).' },
  RELEASE_LIFECYCLE_STATE_PUBLISHED: { status: 'available', ok: true, description: 'Published and available on the closed testing track.' },
  RELEASE_LIFECYCLE_STATE_NOT_APPROVED: { status: 'rejected', ok: false, description: 'Rejected by Google review; see Play Console.' },
};
const notSubmitted = { status: 'not_submitted', ok: false, description: 'Not sent for review; Google has not accepted the release for review.' };
// Right after edits.commit, Google still reports the release as not sent for review (or not at
// all) while it hands it to the review; run 39143454245 read NOT_SENT_FOR_REVIEW 0.4 s after the
// commit, the same release was published later. So these states are only final after a while.
const pendingStates = new Set([undefined, 'RELEASE_LIFECYCLE_STATE_UNSPECIFIED', 'RELEASE_LIFECYCLE_STATE_DRAFT', 'RELEASE_LIFECYCLE_STATE_NOT_SENT_FOR_REVIEW']);
const sleepFor = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function runRelease({ mode, statePath, bundlePath, request, env = process.env, log = console.log, sleep = sleepFor, now = Date.now }) {
  if (!['prepare', 'publish', 'verify'].includes(mode) || !statePath) {
    throw new Error('Usage: node play-release.mjs prepare|publish|verify STATE [BUNDLE]');
  }
  if (mode === 'prepare') {
    const { id } = await request(`${base}/edits`, 'POST', {});
    try {
      const { bundles = [] } = await request(`${base}/edits/${id}/bundles`);
      const pubspec = await readFile(new URL('../../pubspec.yaml', import.meta.url), 'utf8');
      const match = pubspec.match(/^version:\s*([^+\s]+)\+(\d+)\s*$/m);
      if (!match) throw new Error('pubspec.yaml must contain version: NAME+CODE');
      const versionCode = Math.max(Number(match[2]), ...bundles.map(b => Number(b.versionCode) + 1));
      if (!Number.isSafeInteger(versionCode) || versionCode > 2100000000) throw new Error('Invalid version code');
      const state = { packageName, track: trackName, editId: id, versionName: match[1], versionCode, commit: env.GITHUB_SHA };
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      if (env.GITHUB_OUTPUT) await appendFile(env.GITHUB_OUTPUT, `version_code=${versionCode}\n`);
      log(`Prepared ${state.versionName} (${versionCode}) for closed testing (${trackName})`);
    } catch (error) {
      await request(`${base}/edits/${id}`, 'DELETE').catch(() => {});
      throw error;
    }
  } else {
    const state = JSON.parse(await readFile(statePath, 'utf8'));
    if (state.packageName !== packageName) throw new Error('Unexpected package in release state');
    if (state.track !== trackName) throw new Error('Unexpected or missing track in release state; prepare a new closed testing release');
    if (env.GITHUB_SHA && state.commit !== env.GITHUB_SHA) throw new Error('Release state belongs to a different commit');
    if (mode === 'publish') {
      if (!bundlePath) throw new Error('Bundle path required');
      const uploadUrl = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${packageName}/edits/${state.editId}/bundles?uploadType=media`;
      const bundle = await request(uploadUrl, 'POST', createReadStream(bundlePath), {
        headers: { 'Content-Type': 'application/octet-stream' }, timeout: 600000,
      });
      if (Number(bundle.versionCode) !== state.versionCode) throw new Error('Uploaded version code differs from prepared version');
      const releaseNotes = await readFile(new URL(`../../docs/releases/${state.versionName}.txt`, import.meta.url), 'utf8').then(text => text.trim()).catch(error => { if (error.code === 'ENOENT') return `Testversion ${state.versionName}. Verbesserungen und Fehlerbehebungen für die Theater-App.`; throw error; });
      if ([...releaseNotes].length > 500) throw new Error('Play release notes exceed 500 characters');
      const release = {
        name: `${state.versionName} (${state.versionCode})`, status: 'completed',
        versionCodes: [String(state.versionCode)],
        releaseNotes: [{ language: 'de-DE', text: releaseNotes }],
      };
      await request(`${base}/edits/${state.editId}/tracks/${trackName}`, 'PUT', { track: trackName, releases: [release] });
      await request(`${base}/edits/${state.editId}:validate`, 'POST');
      // Sent for review explicitly. Should Google refuse that (e.g. after a rejection), the commit
      // fails instead of silently leaving the release unsubmitted.
      await request(`${base}/edits/${state.editId}:commit?changesNotSentForReview=false`, 'POST');
      state.bundleSha256 = bundle.sha256;
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      log(`Submitted closed testing release ${release.name}; review and availability are checked separately`);
    } else {
      // Poll until Google reports review, approval or publication; give up after the timeout.
      const timeoutMs = Number(env.PLAY_VERIFY_TIMEOUT_MS ?? 15 * 60 * 1000);
      const intervalMs = Number(env.PLAY_VERIFY_INTERVAL_MS ?? 20 * 1000);
      const started = now();
      let release, lifecycle, outcome, attempts = 0;
      for (;;) {
        attempts++;
        const { releases = [] } = await request(`${base}/tracks/${trackName}/releases`);
        release = releases.find(r => r.track === trackName && r.activeArtifacts?.some(a => Number(a.versionCode) === state.versionCode));
        lifecycle = release?.releaseLifecycleState;
        const seconds = Math.round((now() - started) / 1000);
        log(`Check ${attempts} after ${seconds} s: ${release ? `${release.releaseName}: ${lifecycle}` : `version ${state.versionCode} not yet in the closed testing track`}`);
        outcome = pendingStates.has(lifecycle) ? null : outcomes[lifecycle] ?? { status: 'unknown', ok: false, description: 'Unknown release state.' };
        if (outcome || now() - started + intervalMs > timeoutMs) break;
        await sleep(intervalMs);
      }
      outcome ??= notSubmitted;
      const name = release?.releaseName ?? `${state.versionName} (${state.versionCode})`;
      Object.assign(state, { releaseLifecycleState: lifecycle ?? null, reviewStatus: outcome.status, checkedAt: new Date(now()).toISOString(), checks: attempts });
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      if (env.GITHUB_STEP_SUMMARY) await appendFile(env.GITHUB_STEP_SUMMARY,
        `### Google Play closed test\n\nVersion ${name}, commit ${state.commit}, track ${trackName}.\n\nStatus: ${lifecycle ?? 'not found'} (${outcome.status}). ${outcome.description}\n\n[Join the closed test](${testUrl})\n`);
      if (!release) throw new Error(`Submitted version not found in the closed testing track after ${attempts} checks`);
      if (!outcome.ok) throw new Error(`Closed testing release ${name} is not in review or available: ${lifecycle} (${outcome.status}). ${outcome.description}`);
      log(`Verified closed testing release ${name}: ${lifecycle} (${outcome.status}). ${outcome.description}`);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [mode, statePath, bundlePath] = process.argv.slice(2);
    if (!['prepare', 'publish', 'verify'].includes(mode) || !statePath) {
      throw new Error('Usage: node play-release.mjs prepare|publish|verify STATE [BUNDLE]');
    }
    const client = await new GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/androidpublisher'],
    }).getClient();
    const request = async (url, method = 'GET', data, extra = {}) =>
      (await client.request({ url, method, data, ...extra })).data;
    await runRelease({ mode, statePath, bundlePath, request });
  } catch (error) {
    // Never print the authenticated request object or request headers.
    console.error(error.response?.data?.error?.message ?? error.message);
    process.exitCode = 1;
  }
}
