// test/js/inline-drift.test.mjs
// M2 drift guard: the inline decodeVpnLink in main.js and the tested
// decode-vpn.mjs are intentionally duplicated (LuCI cannot import ESM
// modules at runtime). This test asserts they behave identically on the
// same fixtures and negative inputs, so any future drift fails CI.
//
// Known intentional differences (NOT treated as drift):
//   1. decode-vpn.mjs uses `t.startsWith('vpn://')`, main.js uses
//      `t.indexOf('vpn://') !== 0`  — both are functionally equivalent.
//   2. decode-vpn.mjs falls back to Buffer.from() for Node without globals;
//      main.js always uses atob() (browser environment assumed by LuCI).
//
// Strategy: extract the inline function body from main.js by text-slicing
// between the function signature and its matching closing `}`, then wrap it
// in a Node-compatible shim that provides atob + DecompressionStream, and
// run both implementations against identical inputs.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dir = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(__dir, 'fixtures');

// Import the reference implementation (tested in decode-vpn.test.mjs).
const { decodeVpnLink: refDecode } = await import(
  join(__dir, '../../openwrt/luci-app-amnezia/view/decode-vpn.mjs')
);

const sampleVpn  = readFileSync(join(fixturesDir, 'sample.vpn'),  'utf8').trim();
const sampleConf = readFileSync(join(fixturesDir, 'sample.conf'), 'utf8').trim();

// ── Extract inline function from main.js ──────────────────────────────────────
// We look for the unique marker `function decodeVpnLink(text)` and balance
// braces to find the full function body.  This is more robust than a fixed
// line range.
const mainJsPath = join(__dir, '../../openwrt/luci-app-amnezia/view/main.js');
const mainJs = readFileSync(mainJsPath, 'utf8');

const marker = 'function decodeVpnLink(text)';
const markerIdx = mainJs.indexOf(marker);
if (markerIdx === -1) throw new Error('inline decodeVpnLink not found in main.js');

// Walk forward from the marker to collect the full function body by counting
// braces. Stop at the first `}` that closes the opening `{`.
let braceDepth = 0;
let fnStart = markerIdx;
let fnEnd = -1;
let inStr = false;
let strChar = '';
for (let i = fnStart; i < mainJs.length; i++) {
  const ch = mainJs[i];
  if (inStr) {
    if (ch === '\\') { i++; continue; }
    if (ch === strChar) inStr = false;
    continue;
  }
  if (ch === '"' || ch === "'" || ch === '`') { inStr = true; strChar = ch; continue; }
  if (ch === '{') braceDepth++;
  if (ch === '}') {
    braceDepth--;
    if (braceDepth === 0) { fnEnd = i; break; }
  }
}
if (fnEnd === -1) throw new Error('Could not find closing brace for inline decodeVpnLink');

const inlineFnText = mainJs.slice(fnStart, fnEnd + 1);

// Verify the extracted text is non-trivially long (sanity check).
assert.ok(inlineFnText.length > 500,
  'Extracted inline function body is suspiciously short (' + inlineFnText.length + ' chars); check extraction');

// Wrap in an async IIFE that shims the browser globals expected by main.js:
//   atob (Buffer fallback), DecompressionStream (Node native), TextDecoder (native).
// Then expose it as inlineDecode.
const wrappedSrc = `
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';

// Shim atob for Node environments that don't have it as a global.
const atob = globalThis.atob || ((b64) => Buffer.from(b64, 'base64').toString('binary'));

${inlineFnText}

export { decodeVpnLink };
`;

// Write to a temp file so we can dynamic-import it.
import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const tmpDir = mkdtempSync(join(tmpdir(), 'amnezia-drift-'));
const tmpFile = join(tmpDir, 'inline-shim.mjs');
writeFileSync(tmpFile, wrappedSrc, 'utf8');

let inlineDecode;
try {
  const mod = await import(pathToFileURL(tmpFile).href);
  inlineDecode = mod.decodeVpnLink;
} finally {
  try { unlinkSync(tmpFile); } catch (_) { /* ignore */ }
  try { import('node:fs').then(m => m.rmdirSync(tmpDir)); } catch (_) { /* ignore */ }
}

assert.ok(typeof inlineDecode === 'function',
  'inlineDecode should be a function after extraction');

// ── Drift tests ───────────────────────────────────────────────────────────────

test('inline decodeVpnLink decodes the same fixture as the reference', async () => {
  const ref    = await refDecode(sampleVpn);
  const inline = await inlineDecode(sampleVpn);
  assert.equal(inline, ref, 'inline result differs from reference on sample fixture');
  assert.equal(inline, sampleConf, 'inline result does not match expected sample.conf');
});

test('inline decodeVpnLink returns null for null input (same as reference)', async () => {
  assert.equal(await inlineDecode(null), null);
  assert.equal(await refDecode(null), null);
});

test('inline decodeVpnLink returns null for empty string (same as reference)', async () => {
  assert.equal(await inlineDecode(''), null);
  assert.equal(await refDecode(''), null);
});

test('inline decodeVpnLink returns null for plain .conf (same as reference)', async () => {
  const r1 = await inlineDecode(sampleConf);
  const r2 = await refDecode(sampleConf);
  assert.equal(r1, null);
  assert.equal(r2, null);
});

test('inline decodeVpnLink returns null for garbage input (same as reference)', async () => {
  const garbage = 'not a vpn link at all!!@@##';
  assert.equal(await inlineDecode(garbage), null);
  assert.equal(await refDecode(garbage), null);
});

test('inline decodeVpnLink returns null for truncated base64 payload (same as reference)', async () => {
  const bad = 'vpn://!!!NOTBASE64!!!';
  assert.equal(await inlineDecode(bad), null);
  assert.equal(await refDecode(bad), null);
});
