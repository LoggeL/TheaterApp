#!/usr/bin/env node
// Explicit fallback for an unreachable LAN SSH route. Uses the existing Dokploy API key and
// existing manager container; no keys, access rules, ports or containers are created.
// Binary stdin/stdout travel in acknowledged base64 frames, never as terminal keystrokes.
import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const require = createRequire(new URL('../server/package.json', import.meta.url));
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

export function apiKey(env = process.env) {
  let key = env.DOKPLOY_API_KEY?.trim();
  if (!key && env.DOKPLOY_API_KEY_FILE) {
    const path = env.DOKPLOY_API_KEY_FILE;
    if (!statSync(path).isFile() || (statSync(path).mode & 0o077)) throw new Error('DOKPLOY_API_KEY_FILE must be a private file.');
    key = readFileSync(path, 'utf8').trim();
  }
  if (!key && process.platform === 'darwin') key = execFileSync('security', ['find-generic-password', '-s', 'dokploy.logge.top API Key', '-w'], { encoding: 'utf8' }).trim();
  if (!key || /[\r\n]/.test(key)) throw new Error('No valid Dokploy API credential is configured.');
  return key;
}

export function remoteProgram(command, marker) {
  return `const {spawn}=require('node:child_process');const {createInterface}=require('node:readline');
const marker=${JSON.stringify(marker)};const frame=(kind,data='')=>process.stdout.write(marker+kind+':'+data+'\\n');
const child=spawn('sh',['-c',${JSON.stringify(command)}],{stdio:['pipe','pipe','pipe']});
for(const [stream,kind] of [[child.stdout,'O'],[child.stderr,'E']])stream.on('data',data=>{if(!frame(kind,data.toString('base64'))){stream.pause();process.stdout.once('drain',()=>stream.resume());}});
child.on('error',()=>{frame('E',Buffer.from('Remote command could not start.\\n').toString('base64'));});
child.on('close',code=>process.stdout.write(marker+'X:'+(Number.isInteger(code)?code:1)+'\\n',()=>process.exit(0)));
child.stdin.on('error',()=>{});
const input=createInterface({input:process.stdin,terminal:false});
input.on('line',line=>{if(line==='END')child.stdin.end();else if(line.startsWith('IN:'))child.stdin.write(Buffer.from(line.slice(3),'base64'),()=>frame('A'));});
process.stdout.write('\\n');frame('R');`;
}

export async function run(command, { env = process.env, input = process.stdin, output = process.stdout, errorOutput = process.stderr } = {}) {
  if (!command) throw new Error('Usage: node tool/dokploy-transport.mjs COMMAND');
  const WebSocket = require('ws');
  const key = apiKey(env);
  const api = new URL(env.DOKPLOY_API_URL ?? 'https://dokploy.logge.top/api');
  if (api.protocol !== 'https:' && !['localhost', '127.0.0.1', '[::1]'].includes(api.hostname)) throw new Error('Remote Dokploy transport requires HTTPS.');
  const response = await fetch(new URL(api.pathname.replace(/\/$/, '') + '/docker.getContainersByAppLabel?appName=dokploy&type=swarm', api), { headers: { 'x-api-key': key }, signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`Dokploy manager discovery returned HTTP ${response.status}.`);
  const containers = (await response.json()).filter(x => x.state === 'running');
  if (containers.length !== 1 || !/^[a-zA-Z0-9._-]+$/.test(containers[0].containerId)) throw new Error('Expected exactly one running Dokploy manager container.');
  const url = new URL('/docker-container-terminal', api);
  url.protocol = api.protocol === 'https:' ? 'wss:' : 'ws:';
  url.search = new URLSearchParams({ containerId: containers[0].containerId, activeWay: 'sh', cols: '240', rows: '30' }).toString();
  const marker = 'THEATER_' + randomBytes(12).toString('hex') + '_';
  const ws = new WebSocket(url, { headers: { 'x-api-key': key }, handshakeTimeout: 15000 });
  let bootstrapSent = false, ready = false, buffer = '', acknowledge, rejectAcknowledgement, exitCode;
  return await new Promise((resolve, reject) => {
    const deadline = setTimeout(() => fail(new Error('Dokploy command exceeded its timeout.')), Number(env.THEATER_TRANSPORT_TIMEOUT_MS ?? 30 * 60 * 1000));
    const startup = setTimeout(() => fail(new Error('Dokploy container terminal did not become ready.')), 20000);
    let done = false;
    function finish(error) {
      if (done) return;
      done = true; clearTimeout(deadline); clearTimeout(startup);
      rejectAcknowledgement?.(error ?? new Error('Remote command finished.'));
      ws.close();
      if (error) reject(error); else resolve(exitCode);
    }
    function fail(error) { finish(error); ws.terminate(); }
    async function sendInput() {
      try {
        if (!input.isTTY) for await (const chunk of input) {
          const bytes = Buffer.from(chunk);
          for (let start = 0; start < bytes.length; start += 12288) {
            if (done) return;
            const acknowledged = new Promise((ok, bad) => { acknowledge = ok; rejectAcknowledgement = bad; });
            ws.send('IN:' + bytes.subarray(start, start + 12288).toString('base64') + '\n');
            await acknowledged;
          }
        }
        if (!done) ws.send('END\n');
      } catch (error) { if (!done) fail(error); }
    }
    ws.on('message', bytes => {
      if (!bootstrapSent) {
        bootstrapSent = true;
        ws.send('stty -echo -icanon -onlcr; exec node -e ' + quote(remoteProgram(command, marker)) + '\n');
      }
      buffer += bytes.toString();
      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline).replace(/\r$/, ''); buffer = buffer.slice(newline + 1);
        if (!line.startsWith(marker)) continue;
        const kind = line[marker.length], data = line.slice(marker.length + 2);
        if (kind === 'R' && !ready) { ready = true; clearTimeout(startup); void sendInput(); }
        else if (kind === 'A') { acknowledge?.(); acknowledge = null; rejectAcknowledgement = null; }
        else if (kind === 'O' || kind === 'E') (kind === 'O' ? output : errorOutput).write(Buffer.from(data, 'base64'));
        else if (kind === 'X') {
          if (!/^\d+$/.test(data) || Number(data) > 255) return fail(new Error('Invalid remote command exit status.'));
          exitCode = Number(data); finish();
        }
      }
      if (buffer.length > 4 * 1024 * 1024) fail(new Error('Invalid Dokploy terminal frame.'));
    });
    ws.on('error', error => fail(new Error(`Dokploy transport failed: ${error.message}`)));
    ws.on('close', () => { if (!done) fail(new Error('Dokploy terminal closed before the command completed.')); });
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.exitCode = await run(process.argv[2]); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
