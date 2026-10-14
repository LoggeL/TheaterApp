import { createReadStream } from 'node:fs';
import { readFile, writeFile, appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { GoogleAuth } from 'google-auth-library';

const packageName = 'de.kolpingtheater.ramsen.theaterapp';
const trackName = 'alpha';
const base = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}`;
const testUrl = `https://play.google.com/apps/testing/${packageName}`;
const lifecycleDescriptions = {
  RELEASE_LIFECYCLE_STATE_IN_REVIEW: 'In Google review; not yet available to closed testers.',
  RELEASE_LIFECYCLE_STATE_APPROVED_NOT_PUBLISHED: 'Approved; waiting for publication in Play Console.',
  RELEASE_LIFECYCLE_STATE_PUBLISHED: 'Published and available on the closed testing track.',
};

export async function runRelease({ mode, statePath, bundlePath, request, env = process.env, log = console.log }) {
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
      await request(`${base}/edits/${state.editId}:commit`, 'POST');
      state.bundleSha256 = bundle.sha256;
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      log(`Submitted closed testing release ${release.name}; review and availability are checked separately`);
    } else {
      const { releases = [] } = await request(`${base}/tracks/${trackName}/releases`);
      const release = releases.find(r => r.track === trackName && r.activeArtifacts?.some(a => Number(a.versionCode) === state.versionCode));
      if (!release) throw new Error('Submitted version not found in the closed testing track');
      const lifecycle = release.releaseLifecycleState;
      const description = lifecycleDescriptions[lifecycle];
      if (!description) throw new Error(`Closed testing release ${release.releaseName} is not submitted or available: ${lifecycle}`);
      state.releaseLifecycleState = lifecycle;
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      log(`Verified closed testing release ${release.releaseName}: ${lifecycle}. ${description}`);
      if (env.GITHUB_STEP_SUMMARY) await appendFile(env.GITHUB_STEP_SUMMARY,
        `### Google Play closed test\n\nVersion ${release.releaseName}, commit ${state.commit}, track ${trackName}.\n\nStatus: ${lifecycle}. ${description}\n\n[Join the closed test](${testUrl})\n`);
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
