// decode-vpn.mjs — ESM shim exporting decodeVpnLink for testing and for
// inline use by main.js (which imports the implementation as a local function).
//
// Amnezia vpn:// format (documented in design + verified in amnezia-client source):
//   vpn:// + base64url( <4-byte BE uncompressed-length> + <zlib/RFC1950 deflate stream> )
// The decompressed bytes are a UTF-8 JSON document with schema:
//   { containers: [ { containerCode: 9|"clAmneziaWg", last_config: "<JSON string>" }, ... ] }
// last_config is itself JSON: { config: "<WireGuard .conf text>", ... }
// The .config field is the [Interface]/[Peer] text to return.
//
// NOTE: This fixture-validated implementation is consistent with the documented
// Amnezia schema and the round-trip fixture (test/js/fixtures/sample.vpn).
// Real-link validation with an actual Amnezia-app export is deferred to the
// VM/manual verification stage (Phase G). Do not assume real links work until
// the VM stage confirms it.

/**
 * Decode an Amnezia vpn:// share link and return the embedded WireGuard .conf
 * text.  Returns null (never throws) on any failure so the caller can fall back
 * to manual paste.
 *
 * @param {string} text  The raw vpn:// link (or any string; non-vpn:// returns null).
 * @returns {Promise<string|null>}
 */
async function decodeVpnLink(text) {
  if (!text || typeof text !== 'string') return null;
  var t = text.trim();
  if (!t.startsWith('vpn://')) return null;

  try {
    // 1. Strip scheme and base64url-decode to a Uint8Array.
    var b64 = t.slice(6)
      .replace(/-/g, '+')
      .replace(/_/g, '/')
      // Re-add base64 padding.
      + '=='.slice(0, (4 - (t.length - 6) % 4) % 4);

    var raw;
    if (typeof atob !== 'undefined') {
      // Browser / Node 26 global.
      var binStr = atob(b64);
      raw = new Uint8Array(binStr.length);
      for (var i = 0; i < binStr.length; i++) raw[i] = binStr.charCodeAt(i);
    } else {
      // Node without globals: fall back to Buffer.
      raw = new Uint8Array(Buffer.from(b64, 'base64'));
    }

    if (raw.length < 4) return null;

    // 2. Drop the 4-byte big-endian uncompressed-length prefix (qCompress header).
    var compressed = raw.slice(4);

    // 3. Inflate via DecompressionStream('deflate') = zlib/RFC1950 wrapped stream.
    //    We pump both sides concurrently so a decompression error on the readable
    //    is caught inside this try/catch rather than escaping as an unhandled
    //    rejection on the writable side.
    var ds = new DecompressionStream('deflate');
    var writer = ds.writable.getWriter();
    var reader = ds.readable.getReader();

    var chunks = [];
    var totalLen = 0;

    // Write + close the writable side; catch errors so they surface via reader.
    var writeP = writer.write(compressed).then(function() {
      return writer.close();
    }).catch(function() { /* errors surface on reader side */ });

    var readErr = null;
    while (true) {
      var chunk;
      try {
        chunk = await reader.read();
      } catch (re) {
        readErr = re;
        break;
      }
      if (chunk.done) break;
      chunks.push(chunk.value);
      totalLen += chunk.value.length;
    }
    await writeP.catch(function() { /* already handled */ });
    if (readErr) return null;

    var decompressed = new Uint8Array(totalLen);
    var offset = 0;
    for (var j = 0; j < chunks.length; j++) {
      decompressed.set(chunks[j], offset);
      offset += chunks[j].length;
    }

    // 4. UTF-8 decode and JSON.parse the outer document.
    var jsonStr;
    if (typeof TextDecoder !== 'undefined') {
      jsonStr = new TextDecoder().decode(decompressed);
    } else {
      jsonStr = Buffer.from(decompressed).toString('utf8');
    }
    var doc = JSON.parse(jsonStr);

    // 5. Walk containers[] to find the AmneziaWG container.
    //    containerCode 9 (integer) = AmneziaWG in newer clients;
    //    some clients use the string "clAmneziaWg". Accept both.
    var containers = doc && doc.containers;
    if (!Array.isArray(containers)) return null;

    var awgContainer = null;
    for (var k = 0; k < containers.length; k++) {
      var c = containers[k];
      if (c && (c.containerCode === 9 || c.containerCode === 'clAmneziaWg' ||
                c.containerName === 'AmneziaWG')) {
        awgContainer = c;
        break;
      }
    }
    if (!awgContainer || !awgContainer.last_config) return null;

    // 6. last_config is itself a JSON string — JSON.parse it again.
    var inner;
    if (typeof awgContainer.last_config === 'string') {
      inner = JSON.parse(awgContainer.last_config);
    } else {
      // Defensive: some clients may have already parsed it.
      inner = awgContainer.last_config;
    }

    var conf = inner && inner.config;
    if (typeof conf !== 'string' || !conf.trim()) return null;

    return conf.trim();
  } catch (e) {
    return null;
  }
}

export { decodeVpnLink };
