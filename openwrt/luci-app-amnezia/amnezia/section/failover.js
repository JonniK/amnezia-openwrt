'use strict';
'require baseclass';
'require fs';
'require ui';
'require amnezia.util as util';
'require amnezia.section.routing as routing';

// ---- file-scope private state (moved verbatim from main.js) ----
var addTunnelInFlight = false;
var removeTunnelInFlight = false;

function parseFailoverState(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

// Standard handler helper: exec a ctl command then repaint the section.
// Returns a Promise that always resolves (catches errors and shows a notification).
function ctlThenRefresh(view, argv, sectionRefresh) {
	return fs.exec(argv[0], argv.slice(1)).then(function(res) {
		ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
			(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
			res.code === 0 ? 'info' : 'warning');
		return sectionRefresh(view);
	}).catch(function(err) {
		ui.addNotification(null, E('p', {}, _('Action failed: ') + err), 'danger');
	});
}

// Format an age-in-seconds value (same vocabulary as handshake_age rendering).
function fmtSec(age) {
	if (age === undefined || age === null || age < 0) return _('?');
	if (age < 60) return age + 's ago';
	if (age < 3600) return Math.floor(age / 60) + 'm ago';
	if (age < 86400) return Math.floor(age / 3600) + 'h ago';
	return Math.floor(age / 86400) + 'd ago';
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
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:10%;' }, _('Tunnel')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:8%;' }, _('State')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:9%;' }, _('Role')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:6%;' }, _('Metric')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:6%;' }, _('Weight')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:13%;' }, _('Handshake')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:15%;' }, _('Exit IP')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Toggle')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:6%;' }, _('Remove')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:20%;' }, _('Actions'))
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

		// Exit-IP cell: show IP + age when available.
		var exitIpText = t.exit_ip
			? (t.exit_ip + ' (' + fmtSec(t.exit_ip_age) + ')')
			: '—';

		// "Make default" — hidden when this tunnel IS the active pool, or when
		// force_pool is set (metric is moot while pinned). Do NOT use t.carrying
		// (carrying is also true for the sticky tunnel).
		var showMakeDefault = self
			&& t.name !== state.active_pool
			&& !state.force_pool;
		var makeDefaultBtn = showMakeDefault
			? E('button', {
				'class': 'btn btn-sm cbi-button-action',
				'style': 'padding:2px 6px;font-size:11px;margin-right:4px;',
				'click': ui.createHandlerFn(self, 'handleMakeDefault', t.name)
			  }, _('Make default'))
			: E('span', {}, '');

		// "Restart" — confirms before acting.
		var restartBtn = self
			? E('button', {
				'class': 'btn btn-sm cbi-button-action',
				'style': 'padding:2px 6px;font-size:11px;',
				'click': ui.createHandlerFn(self, 'handleTunnelRestart', t.name)
			  }, _('Restart'))
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
				exitIpText),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				toggleBtn),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				removeBtn),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;' }, [
				makeDefaultBtn,
				restartBtn
			])
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
	var bannerEl = document.getElementById('failover-force-pool-banner');
	var forceSel = document.getElementById('failover-force-pool-select');

	if (!state) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = _('no data');
		if (modeEl) modeEl.textContent = '';
		if (bannerEl) bannerEl.style.display = 'none';
		return;
	}

	var allDown = !!state.all_down;
	if (dot) dot.style.background = allDown ? '#a94442' : '#3c763d';
	if (label) label.textContent = allDown ? _('ALL DOWN') : (state.active_pool || _('unknown'));
	if (modeEl) modeEl.textContent = 'mode: ' + (state.mode || '?');

	// Show/hide the force-pool banner.
	if (bannerEl) {
		if (state.force_pool) {
			bannerEl.style.display = '';
			bannerEl.textContent = _('Failover suspended — pool pinned to ') + state.force_pool +
				_('. If it drops, pool traffic stops until you unpin.');
		} else {
			bannerEl.style.display = 'none';
		}
	}

	// Sync the force-pool select to current state (don't touch while user is interacting).
	if (forceSel && !forceSel.contains(document.activeElement)) {
		forceSel.value = state.force_pool || '';
	}
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

return baseclass.extend({
	handlers: {
		// ── Mode / Sticky — NAMED so harness can reach them (Item 3 fix) ────────

		handleSetMode: function(ev) {
			var sel = document.getElementById('failover-mode-select');
			if (!sel) return Promise.resolve();
			var failover = this.__failoverModule;
			return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'set-mode', sel.value],
				failover ? failover.refresh : function() { return Promise.resolve(); });
		},

		handleSetSticky: function(ev, tunnelName) {
			var inp = document.getElementById('failover-sticky-input');
			var val = (inp ? inp.value.trim() : '') || tunnelName || '';
			if (!val) {
				ui.addNotification(null, E('p', {}, _('Enter a tunnel name (e.g. awg1)')), 'warning');
				return Promise.resolve();
			}
			var failover = this.__failoverModule;
			return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'set-sticky', val],
				failover ? failover.refresh : function() { return Promise.resolve(); });
		},

		// ── Tunnel controls (Items 4, 5) ─────────────────────────────────────────

		handleMakeDefault: function(tunnelName, ev) {
			var failover = this.__failoverModule;
			return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'make-default', tunnelName || 'awg1'],
				failover ? failover.refresh : function() { return Promise.resolve(); });
		},

		handleTunnelRestart: function(tunnelName, ev) {
			var name = tunnelName || 'awg1';
			var failover = this.__failoverModule;
			var sectionRefresh = failover ? failover.refresh : function() { return Promise.resolve(); };
			return util.uiConfirm(_('Restart tunnel ') + name + _('?\n\nThis will briefly interrupt traffic on this tunnel.')).then(L.bind(function(ok) {
				if (!ok) return Promise.resolve();
				return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'restart', name], sectionRefresh);
			}, this));
		},

		handleForcePin: function(ev, tunnelName) {
			var sel = document.getElementById('failover-force-pool-select');
			var name = (sel ? sel.value : '') || tunnelName || 'awg1';
			if (!name) {
				ui.addNotification(null, E('p', {}, _('Select a tunnel to pin')), 'warning');
				return Promise.resolve();
			}
			var failover = this.__failoverModule;
			return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'force-pin', name],
				failover ? failover.refresh : function() { return Promise.resolve(); });
		},

		handleForceUnpin: function(ev) {
			var failover = this.__failoverModule;
			return ctlThenRefresh(this, ['/usr/bin/amnezia-failover-ctl', 'force-unpin'],
				failover ? failover.refresh : function() { return Promise.resolve(); });
		},

		handleTunnelToggle: function(tunnelName, ev) {
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
		handleTunnelRemove: function(tunnelName, exitIp, ev) {
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
		}
	},

	render: function(view, data) {
		var failoverState = parseFailoverState((data && data[7]) || '');

		// Build tunnel list for the force-pool select.
		var tunnelNames = [];
		if (failoverState && failoverState.tunnels) {
			for (var ti = 0; ti < failoverState.tunnels.length; ti++) {
				tunnelNames.push(failoverState.tunnels[ti].name);
			}
		}

		// Store a back-reference so named handlers can call failover.refresh.
		view.__failoverModule = this;

		var forcePoolBannerDisplay = (failoverState && failoverState.force_pool) ? '' : 'none';
		var forcePoolBannerText = failoverState && failoverState.force_pool
			? (_('Failover suspended — pool pinned to ') + failoverState.force_pool +
			   _('. If it drops, pool traffic stops until you unpin.'))
			: '';

		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Tunnels & Failover')),

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
								'change': ui.createHandlerFn(view, 'handleSetMode')
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
								'click': ui.createHandlerFn(view, 'handleSetSticky')
							}, _('Set sticky'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Force pool through')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('select', {
								'id': 'failover-force-pool-select',
								'class': 'cbi-input-select',
								'style': 'width:120px;margin-right:8px;'
							}, [E('option', { 'value': '' }, _('— select —'))].concat(
								tunnelNames.map(function(n) {
									return E('option', {
										'value': n,
										'selected': (failoverState && failoverState.force_pool === n) ? '' : null
									}, n);
								})
							)),
							E('button', {
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(view, 'handleForcePin')
							}, _('Pin')),
							' ',
							E('button', {
								'class': 'btn cbi-button-neutral',
								'click': ui.createHandlerFn(view, 'handleForceUnpin')
							}, _('Unpin')),
							E('div', {
								'id': 'failover-force-pool-banner',
								'class': 'alert-message warning',
								'style': 'display:' + forcePoolBannerDisplay + ';margin-top:6px;'
							}, forcePoolBannerText)
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Tunnels')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'failover-tunnel-table' }, renderTunnelTable(failoverState, view))
						])
					])
				])
			]),

			// ── Add tunnel sub-panel (collapsed) ─────────────────────────────────
			E('details', { 'class': 'amnezia-action' }, [
				E('summary', {}, _('Add tunnel')),
				E('div', { 'class': 'cbi-section' }, [
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
									'click': ui.createHandlerFn(view, 'handleAddTunnel')
								}, _('Add tunnel'))
							])
						])
					])
				])
			])
		]);
	},

	refresh: function(view) {
		return L.resolveDefault(fs.read('/var/run/amnezia-failover.json'), '').then(function(text) {
			var st = parseFailoverState(text);
			paintFailoverSummary(st);
			var tableEl = document.getElementById('failover-tunnel-table');
			if (tableEl) {
				tableEl.innerHTML = '';
				tableEl.appendChild(renderTunnelTable(st, view));
			}
			routing.applyFailoverState(st);
		});
	}
});
