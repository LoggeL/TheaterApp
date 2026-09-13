import { createReadStream } from 'node:fs';
import { readFile, writeFile, appendFile } from 'node:fs/promises';
import { GoogleAuth } from 'google-auth-library';

const packageName = 'de.kolpingtheater.ramsen.theaterapp';
const base = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}`;
const [mode, statePath, bundlePath] = process.argv.slice(2);
if (!['prepare', 'publish', 'verify'].includes(mode) || !statePath) {
  throw new Error('Usage: node play-release.mjs prepare|publish|verify STATE [BUNDLE]');
}
const client = await new GoogleAuth({
  scopes: ['https://www.googleapis.com/auth/androidpublisher'],
}).getClient();
const request = async (url, method = 'GET', data, extra = {}) =>
  (await client.request({ url, method, data, ...extra })).data;

try {
  if (mode === 'prepare') {
    const { id } = await request(`${base}/edits`, 'POST', {});
    try {
      const { bundles = [] } = await request(`${base}/edits/${id}/bundles`);
      const pubspec = await readFile(new URL('../../pubspec.yaml', import.meta.url), 'utf8');
      const match = pubspec.match(/^version:\s*([^+\s]+)\+(\d+)\s*$/m);
      if (!match) throw new Error('pubspec.yaml must contain version: NAME+CODE');
      const versionCode = Math.max(Number(match[2]), ...bundles.map(b => Number(b.versionCode) + 1));
      if (!Number.isSafeInteger(versionCode) || versionCode > 2100000000) throw new Error('Invalid version code');
      const state = { packageName, editId: id, versionName: match[1], versionCode, commit: process.env.GITHUB_SHA };
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, `version_code=${versionCode}\n`);
      console.log(`Prepared ${state.versionName} (${versionCode}) for internal testing`);
    } catch (error) {
      await request(`${base}/edits/${id}`, 'DELETE').catch(() => {});
      throw error;
    }
  } else {
    const state = JSON.parse(await readFile(statePath, 'utf8'));
    if (state.packageName !== packageName) throw new Error('Unexpected package in release state');
    if (mode === 'publish') {
      if (!bundlePath) throw new Error('Bundle path required');
      const uploadUrl = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${packageName}/edits/${state.editId}/bundles?uploadType=media`;
      const bundle = await request(uploadUrl, 'POST', createReadStream(bundlePath), {
        headers: { 'Content-Type': 'application/octet-stream' }, timeout: 600000,
      });
      if (Number(bundle.versionCode) !== state.versionCode) throw new Error('Uploaded version code differs from prepared version');
      const release = {
        name: `${state.versionName} (${state.versionCode})`, status: 'completed',
        versionCodes: [String(state.versionCode)],
        releaseNotes: [{ language: 'de-DE', text: `Testversion ${state.versionName}. Verbesserungen und Fehlerbehebungen für die Theater-App.` }],
      };
      await request(`${base}/edits/${state.editId}/tracks/internal`, 'PUT', { track: 'internal', releases: [release] });
      await request(`${base}/edits/${state.editId}:validate`, 'POST');
      await request(`${base}/edits/${state.editId}:commit`, 'POST');
      state.bundleSha256 = bundle.sha256;
      await writeFile(statePath, JSON.stringify(state, null, 2) + '\n');
      console.log(`Published internal release ${release.name}`);
    } else {
      const { id } = await request(`${base}/edits`, 'POST', {});
      try {
        const track = await request(`${base}/edits/${id}/tracks/internal`);
        const release = track.releases?.find(r => r.status === 'completed' && r.versionCodes?.includes(String(state.versionCode)));
        if (!release) throw new Error('Published version not found in the internal track');
        console.log(`Verified internal release ${release.name}`);
        if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY,
          `### Google Play internal test\n\nVersion ${release.name}, commit ${state.commit}.\n\n[Install test version](https://play.google.com/apps/internaltest/4701275968106617341)\n`);
      } finally {
        await request(`${base}/edits/${id}`, 'DELETE');
      }
    }
  }
} catch (error) {
  // Never print the authenticated request object or request headers.
  console.error(error.response?.data?.error?.message ?? error.message);
  process.exitCode = 1;
}
