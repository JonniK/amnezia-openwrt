// test/js/decode-vpn.test.mjs
// Node --test suite for the decodeVpnLink() function.
//
// Uses a self-generated round-trip fixture (test/js/fixtures/sample.vpn /
// sample.conf) produced by make-fixture.mjs using the Amnezia vpn:// framing
// documented in the design spec.
//
// IMPORTANT: This fixture is a SELF-CONSISTENT ROUND-TRIP test — not a test
// against a real Amnezia-app-exported link.  Real-link validation is deferred
// to the VM/manual verification stage (Phase G).  Do not interpret a green
// result here as proof that real links work.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// Import the decoder module.  Use the source in openwrt/ directly.
const __dir = dirname(fileURLToPath(import.meta.url));
const { decodeVpnLink } = await import(
  join(__dir, '../../openwrt/luci-app-amnezia/view/decode-vpn.mjs')
);

const fixturesDir = join(__dir, 'fixtures');
const sampleVpn  = readFileSync(join(fixturesDir, 'sample.vpn'),  'utf8').trim();
const sampleConf = readFileSync(join(fixturesDir, 'sample.conf'), 'utf8').trim();

// --- Positive: round-trip decode ---

test('decodeVpnLink decodes sample fixture to the expected .conf text', async () => {
  const result = await decodeVpnLink(sampleVpn);
  assert.notEqual(result, null, 'decode returned null instead of conf text');
  assert.equal(result, sampleConf, 'decoded conf does not match expected sample.conf');
});

test('decodeVpnLink result contains [Interface] and [Peer] sections', async () => {
  const result = await decodeVpnLink(sampleVpn);
  assert.ok(result && result.includes('[Interface]'), 'missing [Interface]');
  assert.ok(result && result.includes('[Peer]'),      'missing [Peer]');
});

test('decodeVpnLink result contains PrivateKey and Endpoint', async () => {
  const result = await decodeVpnLink(sampleVpn);
  assert.ok(result && result.includes('PrivateKey'),  'missing PrivateKey');
  assert.ok(result && result.includes('Endpoint'),    'missing Endpoint');
});

// --- Negative: garbage / non-vpn:// input returns null without throwing ---

test('decodeVpnLink returns null for null input', async () => {
  const result = await decodeVpnLink(null);
  assert.equal(result, null);
});

test('decodeVpnLink returns null for empty string', async () => {
  const result = await decodeVpnLink('');
  assert.equal(result, null);
});

test('decodeVpnLink returns null for plain .conf text (no vpn:// prefix)', async () => {
  const result = await decodeVpnLink(sampleConf);
  assert.equal(result, null);
});

test('decodeVpnLink returns null for random garbage string', async () => {
  const result = await decodeVpnLink('not a vpn link at all!!@@##');
  assert.equal(result, null);
});

test('decodeVpnLink returns null for vpn:// with truncated/invalid base64', async () => {
  const result = await decodeVpnLink('vpn://!!!NOTBASE64!!!');
  assert.equal(result, null);
});

test('decodeVpnLink returns null for vpn:// with valid base64 but random payload', async (t) => {
  // Random bytes that will fail decompression or JSON parsing.
  // The DecompressionStream may emit an unhandled error on the readable side;
  // we explicitly drain it so the error is caught inside decodeVpnLink's try/catch.
  const result = await decodeVpnLink('vpn://dGhpcyBpcyBub3QgY29tcHJlc3NlZA');
  assert.equal(result, null);
});

test('decodeVpnLink returns null for vpn:// with correct encoding but wrong schema', async () => {
  // Encode a valid zlib stream of JSON with no "containers" key.
  const { deflateSync } = await import('node:zlib');
  const json = JSON.stringify({ notContainers: [] });
  const buf = Buffer.from(json, 'utf8');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(buf.length, 0);
  const compressed = deflateSync(buf);
  const payload = Buffer.concat([lenBuf, compressed]);
  const b64url = payload.toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  const result = await decodeVpnLink('vpn://' + b64url);
  assert.equal(result, null);
});

test('decodeVpnLink returns null for vpn:// with no AmneziaWG container', async () => {
  // A valid doc but the only container has a different code.
  const { deflateSync } = await import('node:zlib');
  const json = JSON.stringify({
    containers: [{ containerCode: 1, last_config: '{}' }]
  });
  const buf = Buffer.from(json, 'utf8');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(buf.length, 0);
  const compressed = deflateSync(buf);
  const payload = Buffer.concat([lenBuf, compressed]);
  const b64url = payload.toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  const result = await decodeVpnLink('vpn://' + b64url);
  assert.equal(result, null);
});
