'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require amnezia.util';
'require amnezia.section.routing';
'require amnezia.section.zapret';
'require amnezia.section.dns';

// Module-level handle for the poll callback. LuCI has no teardown hook for
// views, so the poller self-unregisters when its DOM anchor disappears
// (i.e. the user navigated to another page). On return, render() registers
// a fresh poller. Steady state during navigation: 0 active pollers.
var pollFn = null;
// True once refresh() has seen the view's DOM anchor at least once. LuCI's
// poll.add() fires one synchronous step() *before* render() returns (and thus
// before LuCI inserts the rendered DOM), so the very first poll runs with the
// anchor absent. We must NOT treat that as "navigated away" -- otherwise the
// poller kills itself on initial load and refresh-only fields (the force-update
// stamp) are never painted. Only self-unregister once the anchor has appeared.
var domSeen = false;

// Guards for the new tunnel-management operations.
var addTunnelInFlight = false;
var removeTunnelInFlight = false;

// Guards for autolearn operations.
var autolearnToggleInFlight = false;
var autolearnVetoInFlight = false;
var autolearnPromoteInFlight = false;
var autolearnPurgeInFlight = false;

function parseFailoverState(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

// self is the view instance; pass it so toggle/remove buttons can call handlers.
// self may be null when called without toggle support (e.g. in tests).
function renderTunnelTable(state, self) {
	if (!state || !state.tunnels || !state.tunnels.length) {
		return E('div', { 'style': 'color:#888;font-style:italic;' },
			_('No tunnel state available. Start the amnezia-failover service.'));
	}
	var table = E('table', {
		'style': 'border-collapse:collapse;font-size:12px;width:100%;table-layout:fixed;'
	});
	var head = E('tr', {}, [
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:11%;' }, _('Tunnel')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:9%;' }, _('State')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:10%;' }, _('Role')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Metric')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Weight')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:14%;' }, _('Handshake')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:12%;' }, _('Exit IP')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:8%;' }, _('Toggle')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Remove'))
	]);
	table.appendChild(head);
	for (var i = 0; i < state.tunnels.length; i++) {
		var t = state.tunnels[i];
		var upColor = t.up ? '#3c763d' : '#a94442';
		var upText = t.up ? _('UP') : _('DOWN');
		var role = t.carrying ? _('active') : (t.enabled ? _('standby') : _('disabled'));
		var roleColor = t.carrying ? '#3c763d' : (t.enabled ? '#666' : '#888');
		// Visually distinguish DOWN tunnels with a dim background.
		var rowBg = t.up ? '' : 'background:#fdf2f2;';
		var toggleBtn = self
			? E('button', {
				'id': 'awg-toggle-' + t.name,
				'class': 'btn btn-sm ' + (t.enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
				'style': 'padding:2px 8px;font-size:11px;',
				'click': ui.createHandlerFn(self, 'handleTunnelToggle', t.name)
			  }, t.enabled ? _('Disable') : _('Enable'))
			: E('span', {}, '');
		var removeBtn = self
			? E('button', {
				'id': 'awg-remove-' + t.name,
				'class': 'btn btn-sm cbi-button-negative',
				'style': 'padding:2px 8px;font-size:11px;',
				'click': ui.createHandlerFn(self, 'handleTunnelRemove', t.name, t.exit_ip || '')
			  }, _('Remove'))
			: E('span', {}, '');
		var row = E('tr', {}, [
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;font-weight:bold;' },
				t.label ? (t.name + ' (' + t.label + ')') : t.name),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;color:' + upColor + ';font-weight:bold;' },
				upText),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;color:' + roleColor + ';' },
				role),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:right;color:#555;' },
				t.metric !== undefined ? t.metric : ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:right;color:#555;' },
				t.weight !== undefined ? t.weight : ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;color:#666;font-family:monospace;font-size:11px;' },
				(function(age) {
					// age is seconds-since-handshake from the daemon (-1 = never).
					// Do NOT convert via Date.now() — the value is already an age, not an epoch.
					if (age === undefined || age === null) return _('never');
					if (age < 0) return _('never');
					if (age < 60) return age + 's ago';
					if (age < 3600) return Math.floor(age / 60) + 'm ago';
					if (age < 86400) return Math.floor(age / 3600) + 'h ago';
					return Math.floor(age / 86400) + 'd ago';
				})(t.handshake_age)),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;color:#444;font-family:monospace;font-size:11px;' },
				t.exit_ip || ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				toggleBtn),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				removeBtn)
		]);
		table.appendChild(row);
	}
	return table;
}

// Update the prominent "Active tunnel" banner on each poll.
function paintFailoverSummary(state) {
	var dot = document.getElementById('failover-active-dot');
	var label = document.getElementById('failover-active-label');
	var modeEl = document.getElementById('failover-mode-label');

	if (!state) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = _('no data');
		if (modeEl) modeEl.textContent = '';
		return;
	}

	var allDown = !!state.all_down;
	if (dot) dot.style.background = allDown ? '#a94442' : '#3c763d';
	if (label) label.textContent = allDown ? _('ALL DOWN') : (state.active_pool || _('unknown'));
	if (modeEl) modeEl.textContent = 'mode: ' + (state.mode || '?');
}

// ── vpn:// decoder ──────────────────────────────────────────────────────────
// Decodes an Amnezia vpn:// share link and returns the embedded WireGuard
// .conf text (Promise<string|null>).  Returns null on any failure so the
// caller can fall back to manual paste.
//
// Schema (design §Feature 1 – vpn:// decoding):
//   vpn:// + base64url( <4-byte BE uncompressed-length> + <zlib/RFC1950> )
// Decompressed JSON: { containers: [{ containerCode: 9|"clAmneziaWg",
//   last_config: "<JSON string: {config: '<wg conf>'}>" }] }
//
// NOTE: Validated against a self-consistent round-trip fixture in
// test/js/decode-vpn.test.mjs.  Real Amnezia-app link validation is deferred
// to the VM/manual stage (Phase G).
function decodeVpnLink(text) {
	if (!text || typeof text !== 'string') return Promise.resolve(null);
	var t = text.trim();
	if (t.indexOf('vpn://') !== 0) return Promise.resolve(null);

	return Promise.resolve().then(function() {
		// 1. Strip scheme and base64url-decode to Uint8Array.
		var b64 = t.slice(6)
			.replace(/-/g, '+')
			.replace(/_/g, '/');
		// Re-add base64 padding.
		var pad = (4 - b64.length % 4) % 4;
		for (var p = 0; p < pad; p++) b64 += '=';

		var binStr = atob(b64);
		var raw = new Uint8Array(binStr.length);
		for (var i = 0; i < binStr.length; i++) raw[i] = binStr.charCodeAt(i);

		if (raw.length < 4) return null;

		// 2. Drop the 4-byte big-endian qCompress length prefix.
		var compressed = raw.slice(4);

		// 3. Inflate via DecompressionStream('deflate') = zlib/RFC1950.
		//    Pump both sides concurrently so errors surface on the reader.
		var ds = new DecompressionStream('deflate');
		var writer = ds.writable.getWriter();
		var reader = ds.readable.getReader();

		var writeP = writer.write(compressed).then(function() {
			return writer.close();
		}).catch(function() { /* errors surface via reader side */ });

		var chunks = [];
		var totalLen = 0;
		var readErr = null;

		function readAll() {
			return reader.read().then(function(chunk) {
				if (chunk.done) return;
				chunks.push(chunk.value);
				totalLen += chunk.value.length;
				return readAll();
			}).catch(function(e) { readErr = e; });
		}

		return readAll().then(function() {
			return writeP.catch(function() {});
		}).then(function() {
			if (readErr) return null;

			// 4. Assemble chunks and UTF-8 decode.
			var decompressed = new Uint8Array(totalLen);
			var off = 0;
			for (var j = 0; j < chunks.length; j++) {
				decompressed.set(chunks[j], off);
				off += chunks[j].length;
			}
			var jsonStr = new TextDecoder().decode(decompressed);

			// 5. Parse outer document and find AmneziaWG container.
			var doc;
			try { doc = JSON.parse(jsonStr); } catch (e) { return null; }

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

			// 6. last_config is itself a JSON string — parse it again.
			var inner;
			try {
				inner = (typeof awgContainer.last_config === 'string')
					? JSON.parse(awgContainer.last_config)
					: awgContainer.last_config;
			} catch (e) { return null; }

			var conf = inner && inner.config;
			if (typeof conf !== 'string' || !conf.trim()) return null;
			return conf.trim();
		});
	}).catch(function() { return null; });
}

// ── autolearn helpers ────────────────────────────────────────────────────────

function parseAutolearnStatus(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseAutolearnList(text) {
	if (!text) return [];
	try {
		var arr = JSON.parse(text);
		return Array.isArray(arr) ? arr : [];
	} catch (e) { return []; }
}

// Paint the autolearn status dot + toggle button. Reconciles optimistic toggle
// against polled state via btn.dataset.busy: the handler sets busy=1 and owns
// the button during flight; paintAutolearnStatus skips the button when busy is set.
function paintAutolearnStatus(st, errMsg) {
	var dot = document.getElementById('autolearn-dot');
	var label = document.getElementById('autolearn-state-label');
	var btn = document.getElementById('autolearn-toggle-btn');
	var countEl = document.getElementById('autolearn-count');

	if (errMsg || !st) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = errMsg || _('unavailable');
		if (btn && !btn.dataset.busy) { btn.disabled = true; btn.textContent = _('N/A'); }
		return;
	}

	var enabled = (st.enabled === 1 || st.enabled === '1');
	if (dot) dot.style.background = enabled ? '#3c763d' : '#888';
	if (label) label.textContent = enabled ? _('ON') : _('OFF');
	if (countEl) countEl.textContent = st.count ? (st.count + ' ' + _('entries')) : '';
	// Reconcile: sync button text/class from live state only when not mid-flight
	// (dataset.busy is set by the handler for the duration of the RPC call).
	if (btn && !btn.dataset.busy) {
		btn.textContent = enabled ? _('Disable') : _('Enable');
		btn.className = 'btn ' + (enabled ? 'cbi-button-negative' : 'cbi-button-positive');
		btn.disabled = false;
	}
}

function paintAutolearnTable(entries, self) {
	var container = document.getElementById('autolearn-table');
	if (!container) return;
	container.innerHTML = '';
	if (!entries || entries.length === 0) {
		container.appendChild(E('div', { 'style': 'color:#888;font-style:italic;' },
			_('No auto-learned entries yet.')));
		return;
	}
	var table = E('table', {
		'style': 'border-collapse:collapse;font-size:12px;width:100%;table-layout:fixed;'
	});
	var head = E('tr', {}, [
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:40%;' }, _('Domain')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:20%;' }, _('Reason')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:20%;' }, _('Added')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:10%;' }, _('Remove')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:10%;' }, _('Promote'))
	]);
	table.appendChild(head);
	for (var i = 0; i < entries.length; i++) {
		(function(entry) {
			var row = E('tr', {}, [
				E('td', { 'style': 'padding:4px 6px;border-bottom:1px solid #eee;font-family:monospace;word-break:break-all;' }, entry.domain || ''),
				E('td', { 'style': 'padding:4px 6px;border-bottom:1px solid #eee;color:#666;' }, entry.reason || ''),
				E('td', { 'style': 'padding:4px 6px;border-bottom:1px solid #eee;color:#666;font-size:11px;' }, entry.added || ''),
				E('td', { 'style': 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
					self ? E('button', {
						'class': 'btn btn-sm cbi-button-negative',
						'style': 'padding:2px 8px;font-size:11px;',
						'title': _('Removes this domain and its subdomains from auto-routing (suffix-aware), and suppresses it across subscribed sources too.'),
						'click': ui.createHandlerFn(self, 'handleAutolearnVeto', entry.domain)
					}, _('Remove')) : ''),
				E('td', { 'style': 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
					self ? E('button', {
						'class': 'btn btn-sm cbi-button-positive',
						'style': 'padding:2px 8px;font-size:11px;',
						'click': ui.createHandlerFn(self, 'handleAutolearnPromote', entry.domain)
					}, _('Promote')) : '')
			]);
			table.appendChild(row);
		})(entries[i]);
	}
	container.appendChild(table);
}


return view.extend(Object.assign({}, routing.handlers, zapret.handlers, {

	// ── handleAutolearnToggle ────────────────────────────────────────────────
	// Master ON/OFF toggle for auto-learning. Optimistic UI: the button text
	// flips immediately; the next status poll reconciles via paintAutolearnStatus.
	handleAutolearnToggle: function(ev) {
		if (autolearnToggleInFlight) return Promise.resolve();
		var btn = document.getElementById('autolearn-toggle-btn');
		// Infer desired new state from current button class (negative = currently ON).
		var currentlyOn = btn && btn.className.indexOf('cbi-button-negative') !== -1;
		var newVal = currentlyOn ? '0' : '1';
		autolearnToggleInFlight = true;
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Working...'); }
		return fs.exec('/usr/bin/amnezia-autolearn-ctl', ['set-enabled', newVal]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			autolearnToggleInFlight = false;
			if (btn) delete btn.dataset.busy;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('autolearn set-enabled failed: ') + err), 'danger');
			autolearnToggleInFlight = false;
			var b = document.getElementById('autolearn-toggle-btn');
			if (b) { delete b.dataset.busy; b.disabled = false; }
		});
	},

	// ── handleAutolearnVeto ──────────────────────────────────────────────────
	// Per-row Remove: adds domain to deny.list and removes from auto.list.
	handleAutolearnVeto: function(ev, domain) {
		if (autolearnVetoInFlight) return Promise.resolve();
		autolearnVetoInFlight = true;
		return fs.exec('/usr/bin/amnezia-autolearn-ctl', ['veto', domain]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			autolearnVetoInFlight = false;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('autolearn veto failed: ') + err), 'danger');
			autolearnVetoInFlight = false;
		});
	},

	// ── handleAutolearnPromote ───────────────────────────────────────────────
	// Per-row Promote: moves domain to the permanent force-tunnel.list.
	handleAutolearnPromote: function(ev, domain) {
		if (autolearnPromoteInFlight) return Promise.resolve();
		autolearnPromoteInFlight = true;
		return fs.exec('/usr/bin/amnezia-autolearn-ctl', ['promote', domain]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			autolearnPromoteInFlight = false;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('autolearn promote failed: ') + err), 'danger');
			autolearnPromoteInFlight = false;
		});
	},

	// ── handleAutolearnPurge ─────────────────────────────────────────────────
	// Purge-all: empties auto.list and candidates.tsv.
	handleAutolearnPurge: function(ev) {
		if (autolearnPurgeInFlight) {
			ui.addNotification(null, E('p', {}, _('A purge is already in progress')), 'info');
			return Promise.resolve();
		}
		return util.uiConfirm(_('Purge all auto-learned entries?\n\nThis empties the auto.list and clears the candidate store. The deny.list is NOT cleared — vetoed domains remain denied.')).then(L.bind(function(ok) {
			if (!ok) return null;
			autolearnPurgeInFlight = true;
			var btn = document.getElementById('autolearn-purge-btn');
			if (btn) { btn.disabled = true; btn.textContent = _('Purging...'); }
			return fs.exec('/usr/bin/amnezia-autolearn-ctl', ['purge']).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				autolearnPurgeInFlight = false;
				if (btn) { btn.disabled = false; btn.textContent = _('Purge all'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('autolearn purge failed: ') + err), 'danger');
				autolearnPurgeInFlight = false;
				var b = document.getElementById('autolearn-purge-btn');
				if (b) { b.disabled = false; b.textContent = _('Purge all'); }
			});
		}, this));
	},
	handleRefresh: function(ev) {
		var btn = document.getElementById('manual-refresh-btn');
		if (btn) { btn.disabled = true; }
		return this.refresh().then(function() {
			if (btn) btn.disabled = false;
		}, function() {
			if (btn) btn.disabled = false;
		});
	},

	handleTunnelToggle: function(ev, tunnelName) {
		var btnId = 'awg-toggle-' + tunnelName;
		var btn = document.getElementById(btnId);
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Working...'); }
		return fs.exec('/usr/bin/amnezia-failover-ctl', ['toggle', tunnelName]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			if (btn) delete btn.dataset.busy;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Toggle failed: ') + err), 'danger');
			var b = document.getElementById(btnId);
			if (b) { delete b.dataset.busy; b.disabled = false; }
		});
	},

	// ── handleTunnelRemove ───────────────────────────────────────────────────
	// Remove button per tunnel row.  Guards: sticky-target, last-member.
	// Confirm shows tunnel name + exit-IP so the user knows what they're removing.
	handleTunnelRemove: function(ev, tunnelName, exitIp) {
		if (removeTunnelInFlight) {
			ui.addNotification(null, E('p', {}, _('A remove is already in progress')), 'info');
			return Promise.resolve();
		}
		var msg = _('Remove tunnel ') + tunnelName;
		if (exitIp) msg += _(' (endpoint: ') + exitIp + ')';
		msg += _('?\n\nThis stops the monitor, tears down the interface, and removes all UCI state. The monitor will restart with the remaining tunnels.');
		removeTunnelInFlight = true;
		var btnId = 'awg-remove-' + tunnelName;
		var btn = document.getElementById(btnId);
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Removing...'); }
		return util.uiConfirm(msg).then(L.bind(function(ok) {
			if (!ok) {
				removeTunnelInFlight = false;
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Remove'); }
				return null;
			}
			return fs.exec('/usr/bin/amnezia-tunnel-ctl', ['remove', tunnelName]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				removeTunnelInFlight = false;
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Remove'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Remove failed: ') + err), 'danger');
				removeTunnelInFlight = false;
				var b = document.getElementById(btnId);
				if (b) { delete b.dataset.busy; b.disabled = false; b.textContent = _('Remove'); }
			});
		}, this));
	},

	// ── handleAddTunnel ──────────────────────────────────────────────────────
	// Submits a new .conf or vpn:// link.  vpn:// is decoded client-side first;
	// on success the user sees the decoded preview and confirms before exec.
	handleAddTunnel: function(ev) {
		if (addTunnelInFlight) {
			ui.addNotification(null, E('p', {}, _('An add is already in progress')), 'info');
			return Promise.resolve();
		}
		var taEl = document.getElementById('add-tunnel-conf');
		var labelEl = document.getElementById('add-tunnel-label');
		var raw = (taEl && taEl.value || '').trim();
		if (!raw) {
			ui.addNotification(null, E('p', {}, _('Paste a .conf or vpn:// link first')), 'warning');
			return Promise.resolve();
		}
		var label = (labelEl && labelEl.value || '').trim();

		// Find the free slot.
		return fs.exec('/usr/bin/amnezia-tunnel-ctl', ['list-free']).then(L.bind(function(res) {
			if (!res || res.code === 3) {
				ui.addNotification(null, E('p', {}, _('All tunnel slots are full (max 5). Remove one first.')), 'warning');
				return null;
			}
			var slotName = ((res && res.stdout) || '').trim();
			if (!slotName) {
				ui.addNotification(null, E('p', {}, _('Could not determine free tunnel slot')), 'warning');
				return null;
			}

			// If the input looks like a vpn:// link, decode it first.
			if (raw.indexOf('vpn://') === 0) {
				return decodeVpnLink(raw).then(L.bind(function(decoded) {
					if (!decoded) {
						ui.addNotification(null, E('p', {}, _("Couldn't decode this vpn:// link — paste the .conf text directly instead")), 'warning');
						return null;
					}
					// Show the decoded preview and ask the user to confirm.
					var previewMsg = _('Decoded vpn:// for slot ') + slotName + _(':\n\n') + decoded + _('\n\nProceed?');
					addTunnelInFlight = true;
					return util.uiConfirm(previewMsg).then(L.bind(function(ok) {
						if (!ok) { addTunnelInFlight = false; return null; }
						return this._doAddTunnel(slotName, decoded, label);
					}, this));
				}, this));
			}

			// Plain .conf — confirm and submit.
			var confirmMsg = _('Add tunnel ') + slotName + _(' with the pasted .conf?');
			if (label) confirmMsg += _('\nLabel: ') + label;
			addTunnelInFlight = true;
			return util.uiConfirm(confirmMsg).then(L.bind(function(ok) {
				if (!ok) { addTunnelInFlight = false; return null; }
				return this._doAddTunnel(slotName, raw, label);
			}, this));
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Add tunnel failed: ') + err), 'danger');
			addTunnelInFlight = false;
		});
	},

	_doAddTunnel: function(slotName, confBody, label) {
		var btn = document.getElementById('add-tunnel-btn');
		if (btn) { btn.disabled = true; btn.textContent = _('Adding...'); }
		var args = ['add', slotName, confBody];
		if (label) { args.push('--label'); args.push(label); }
		return fs.exec('/usr/bin/amnezia-tunnel-ctl', args).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'danger');
			addTunnelInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Add tunnel'); }
			// Clear form on success.
			if (res.code === 0) {
				var ta = document.getElementById('add-tunnel-conf');
				var li = document.getElementById('add-tunnel-label');
				if (ta) ta.value = '';
				if (li) li.value = '';
			}
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Add tunnel exec failed: ') + err), 'danger');
			addTunnelInFlight = false;
			var b = document.getElementById('add-tunnel-btn');
			if (b) { b.disabled = false; b.textContent = _('Add tunnel'); }
		});
	},

	refresh: function() {
		// Anchor absent: either the rendered DOM is not inserted yet (first
		// synchronous poll step fired by poll.add() before render() returns) or
		// the user navigated away. Self-unregister only in the latter case --
		// i.e. once the anchor has been seen at least once -- so the poller does
		// not kill itself on initial load (which would leave refresh-only fields
		// such as the force-update stamp stuck on "never updated").
		if (!document.getElementById('failover-tunnel-table')) {
			if (domSeen && pollFn) { poll.remove(pollFn); pollFn = null; }
			return Promise.resolve();
		}
		domSeen = true;
		var self = this;
		var pZapret = zapret.refresh(self);
		var p5 = L.resolveDefault(fs.read('/var/run/amnezia-failover.json'), '').then(function(text) {
			var st = parseFailoverState(text);
			paintFailoverSummary(st);
			var tableEl = document.getElementById('failover-tunnel-table');
			if (tableEl) {
				tableEl.innerHTML = '';
				tableEl.appendChild(renderTunnelTable(st, self));
			}
			routing.applyFailoverState(st);
		});
		var p6 = routing.refresh(self);
		var p7 = Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/amnezia-autolearn-ctl', ['status']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/amnezia-autolearn-ctl', ['list']), { stdout: '' })
		]).then(L.bind(function(res) {
			var st = parseAutolearnStatus((res[0] && res[0].stdout) || '');
			var entries = parseAutolearnList((res[1] && res[1].stdout) || '');
			if (!st) {
				paintAutolearnStatus(null, (res[0] && res[0].code !== 0) ? _('ctl error') : null);
			} else {
				paintAutolearnStatus(st);
			}
			paintAutolearnTable(entries, self);
		}, this));
		var p8 = dns.refresh(this);
		return Promise.all([pZapret, p5, p6, p7, p8]);
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read('/etc/amnezia/ru-update.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/amnezia/blockcheck.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-blockcheck', ['log']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['state']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['parse']), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/amnezia/seed-must-tunnel.list'), ''),
			L.resolveDefault(fs.read('/var/run/amnezia-failover.json'), ''),
			L.resolveDefault(fs.read('/etc/amnezia/force-tunnel.list'), ''),
			// force-update.json is read at load so the stamp paints on the very
			// first render (not only on the first poll tick). refresh()'s p6 keeps
			// it live afterwards.
			L.resolveDefault(fs.read('/etc/amnezia/force-update.json'), '')
		]);
	},

	render: function(data) {
		// load() returns 10 entries:
		// [0] ru-update.json, [1-6] zapret/blockcheck/apply/seed (parsed in zapret.render),
		// [7] amnezia-failover.json, [8] force-tunnel.list, [9] force-update.json
		var failoverState = parseFailoverState((data && data[7]) || '');

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('AmneziaWG')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Multi-tunnel AmneziaWG failover stack. RU traffic goes direct; foreign traffic routes through active tunnel(s). Status refreshes every 5 seconds.')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Failover tunnels')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Per-tunnel status driven by /var/run/amnezia-failover.json. Mode and sticky target are applied via amnezia-failover-ctl.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Active tunnel')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'failover-active-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:' +
									(failoverState && !failoverState.all_down ? '#3c763d' : '#a94442') +
									';margin-right:8px;vertical-align:middle;'
							}),
							E('strong', { 'id': 'failover-active-label' },
								failoverState
									? (failoverState.all_down
										? _('ALL DOWN')
										: (failoverState.active_pool || _('unknown')))
									: _('no data')),
							E('span', { 'id': 'failover-mode-label', 'style': 'margin-left:12px;color:#666;font-size:11px;' },
								failoverState ? ('mode: ' + (failoverState.mode || '?')) : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Mode')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('select', {
								'id': 'failover-mode-select',
								'class': 'cbi-input-select',
								'style': 'width:160px;margin-right:8px;',
								'change': ui.createHandlerFn(this, function(ev) {
									var sel = document.getElementById('failover-mode-select');
									if (!sel) return Promise.resolve();
									return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-mode', sel.value]).then(L.bind(function(res) {
										ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
											(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
											res.code === 0 ? 'info' : 'warning');
									}, this)).catch(function(err) {
										ui.addNotification(null, E('p', {}, _('set-mode failed: ') + err), 'danger');
									});
								})
							}, [
								E('option', { 'value': 'failover', 'selected': (!failoverState || failoverState.mode !== 'balance') ? '' : null }, _('failover (strict priority)')),
								E('option', { 'value': 'balance', 'selected': (failoverState && failoverState.mode === 'balance') ? '' : null }, _('balance (weighted)'))
							])
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Sticky target')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'failover-sticky-input',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:120px;margin-right:8px;',
								'value': (failoverState && failoverState.active_sticky) || '',
								'placeholder': 'awg1'
							}),
							E('button', {
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, function(ev) {
									var inp = document.getElementById('failover-sticky-input');
									var val = inp ? inp.value.trim() : '';
									if (!val) {
										ui.addNotification(null, E('p', {}, _('Enter a tunnel name (e.g. awg1)')), 'warning');
										return Promise.resolve();
									}
									return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-sticky', val]).then(function(res) {
										ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
											(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
											res.code === 0 ? 'info' : 'warning');
									}).catch(function(err) {
										ui.addNotification(null, E('p', {}, _('set-sticky failed: ') + err), 'danger');
									});
								})
							}, _('Set sticky'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Tunnels')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'failover-tunnel-table' }, renderTunnelTable(failoverState, this))
						])
					])
				])
			]),

			// ── Add tunnel section ────────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Add tunnel')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Paste an AmneziaWG .conf file or an Amnezia vpn:// share link. vpn:// links are decoded in the browser — only the resulting .conf is sent to the router.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('.conf / vpn:// link')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('textarea', {
								'id': 'add-tunnel-conf',
								'class': 'cbi-input-text',
								'style': 'width:100%;height:160px;font-family:monospace;font-size:11px;box-sizing:border-box;',
								'placeholder': '[Interface]\nPrivateKey = ...\nAddress = 10.8.0.x/32\n...\n[Peer]\nPublicKey = ...\nEndpoint = host:port\n\nOR paste a vpn:// link here'
							})
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Label (optional)')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'add-tunnel-label',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:200px;margin-right:8px;',
								'placeholder': _('e.g. Backup VPN')
							}),
							E('button', {
								'id': 'add-tunnel-btn',
								'class': 'btn cbi-button-positive',
								'click': ui.createHandlerFn(this, 'handleAddTunnel')
							}, _('Add tunnel'))
						])
					])
				])
			]),

			dns.render(this, data),

			routing.render(this, data),

			zapret.render(this, data),

			// ── Auto-learning section ─────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Auto-learning')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Cron-driven discovery of blocked domains in direct-default mode. Harvests dnsmasq query log, probes candidates via zapret-probe (pinned), and adds confirmed blocked domains to auto.list after repeated sightings from multiple clients. Opt-in, default OFF. Only active in direct-default routing mode.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('State')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'autolearn-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:#888;margin-right:8px;vertical-align:middle;'
							}),
							E('strong', { 'id': 'autolearn-state-label' }, _('loading...')),
							E('span', { 'id': 'autolearn-count', 'style': 'margin-left:12px;color:#666;font-size:11px;' }, '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Toggle')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'autolearn-toggle-btn',
								'class': 'btn cbi-button-positive',
								'disabled': '',
								'click': ui.createHandlerFn(this, 'handleAutolearnToggle')
							}, _('loading...'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Auto-learned entries')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'autolearn-table', 'style': 'margin-bottom:8px;' },
								E('div', { 'style': 'color:#888;font-style:italic;' }, _('Loading...'))),
							E('button', {
								'id': 'autolearn-purge-btn',
								'class': 'btn cbi-button-negative',
								'click': ui.createHandlerFn(this, 'handleAutolearnPurge')
							}, _('Purge all'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'margin:0;' }, _('Refresh')),
					E('button', {
						'id': 'manual-refresh-btn',
						'class': 'btn cbi-button-action',
						'style': 'margin-left:12px;',
						'title': _('Force an immediate poll instead of waiting for the 5s tick'),
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, _('Refresh status'))
				])
			])
		]);

		if (pollFn) {
			poll.remove(pollFn);
			pollFn = null;
		}
		pollFn = L.bind(this.refresh, this);
		poll.add(pollFn, 5);

		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
}));
