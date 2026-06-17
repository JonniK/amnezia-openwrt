#!/usr/bin/env node
// Generates test/js/fixtures/sample.vpn and sample.conf using the Amnezia
// vpn:// framing documented in the design:
//   base64url( <4-byte BE uncompressed-length> + <zlib/RFC1950 stream> )
// The inner JSON schema (containers[].last_config as a JSON string containing
// {config: "<wg conf text>"}) is derived from the Amnezia client source
// (amnezia-client/src/core/vpnconfigurations.cpp) and the design doc.
//
// NOTE: This fixture is self-consistent (encode→decode round-trip) but is NOT
// verified against a real Amnezia-app-exported link. Real-link validation is
// deferred to the VM/manual stage. See test/js/decode-vpn.test.mjs.

import { deflateSync } from 'zlib';
import { writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dir = dirname(fileURLToPath(import.meta.url));

// A minimal but structurally complete AmneziaWG .conf.
// Uses obviously-fake keys so nobody accidentally uses this on a real server.
const SAMPLE_CONF = `[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25`;

// Inner last_config JSON (a JSON string inside the outer JSON).
// containerCode 9 = AmneziaWG (integer form used in newer clients;
// older clients may use string "clAmneziaWg" — the decoder handles both).
const innerConfig = {
  config: SAMPLE_CONF,
  // Additional fields the real app embeds; the decoder ignores them.
  splitTunnelEnabled: false,
  splitTunnelSites: []
};

const outerDoc = {
  containers: [
    {
      // containerCode as both integer and string to test robust matching.
      containerCode: 9,
      containerName: 'AmneziaWG',
      last_config: JSON.stringify(innerConfig)
    }
  ],
  defaultContainer: 9,
  description: 'Test fixture — not a real Amnezia export'
};

const json = JSON.stringify(outerDoc);
const buf = Buffer.from(json, 'utf8');

// 4-byte big-endian uncompressed length (qCompress prefix).
const lenBuf = Buffer.alloc(4);
lenBuf.writeUInt32BE(buf.length, 0);

// zlib-wrapped (deflate, RFC 1950) compressed stream.
const compressed = deflateSync(buf);

// Concatenate prefix + compressed.
const payload = Buffer.concat([lenBuf, compressed]);

// base64url encode (URL-safe base64, no padding).
const b64url = payload.toString('base64')
  .replace(/\+/g, '-')
  .replace(/\//g, '_')
  .replace(/=/g, '');

const vpnLink = 'vpn://' + b64url;

const fixturesDir = join(__dir, 'fixtures');
writeFileSync(join(fixturesDir, 'sample.vpn'), vpnLink + '\n', 'utf8');
writeFileSync(join(fixturesDir, 'sample.conf'), SAMPLE_CONF + '\n', 'utf8');

console.log('Generated:');
console.log('  fixtures/sample.vpn  (' + vpnLink.length + ' chars)');
console.log('  fixtures/sample.conf (' + SAMPLE_CONF.length + ' chars)');
console.log('Inner JSON length:', buf.length, 'bytes');
console.log('Compressed:', compressed.length, 'bytes');
