import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { remoteProgram } from './dokploy-transport.mjs';

async function exchange(command, payload) {
  const marker = 'TEST_FRAME_';
  const child = spawn(process.execPath, ['-e', remoteProgram(command, marker)]);
  let stdout = '', stderr = '';
  child.stdout.on('data', data => stdout += data);
  child.stderr.on('data', data => stderr += data);
  child.stdin.end('IN:' + payload.toString('base64') + '\nEND\n');
  await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
  assert.equal(stderr, '');
  const lines = stdout.split('\n').filter(line => line.startsWith(marker));
  const bytes = kind => Buffer.concat(lines.filter(line => line.startsWith(marker + kind + ':')).map(line => Buffer.from(line.slice(marker.length + 2), 'base64')));
  return { lines, stdout: bytes('O'), stderr: bytes('E'), exit: lines.find(line => line.startsWith(marker + 'X:'))?.slice(marker.length + 2) };
}

test('binary streams and input resembling frames survive the remote protocol', async () => {
  const payload = Buffer.concat([randomBytes(200000), Buffer.from('\0\r\nTEST_FRAME_X:0\n\xff')]);
  const result = await exchange('cat', payload);
  assert.deepEqual(result.stdout, payload);
  assert.equal(result.stderr.length, 0);
  assert.equal(result.exit, '0');
  assert.ok(result.lines.includes('TEST_FRAME_R:'));
  assert.ok(result.lines.includes('TEST_FRAME_A:'));
});

test('stderr and failure exit remain distinct from stdout', async () => {
  const payload = Buffer.from([0, 255, 10, 13, 65]);
  const result = await exchange('cat >&2; exit 7', payload);
  assert.deepEqual(result.stderr, payload);
  assert.equal(result.stdout.length, 0);
  assert.equal(result.exit, '7');
});

test('shell quotes in a command are carried without rewriting', async () => {
  const result = await exchange("printf '%s' \"it's a literal \\$value\"", Buffer.alloc(0));
  assert.equal(result.stdout.toString(), "it's a literal $value");
});
