'use strict';
'require baseclass';
'require fs';
'require ui';
'require amnezia.util as util';

// ---- file-scope private state (moved verbatim from main.js) ----
var routingModeInFlight = false;
var forceUpdateInFlight = false;
var saveManualInFlight = false;
var appAddInFlight = false;
var autotunnelToggleInFlight = false;
var ppActiveFile = null;      // '/tmp/amnezia-fo/probe-page.json' or '/tmp/amnezia-fo/watch.json'
var _ppLastResult = null;     // last parsed probe-page/watch JSON; used by handleProbePageAddAll

function parseRuStamp(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function paintRuStamp(stamp) {
	var when = document.getElementById('awg-ru-when');
	var count = document.getElementById('awg-ru-count');
	var src = document.getElementById('awg-ru-source');
	var status = document.getElementById('awg-ru-status');

	if (!stamp) {
		if (when) when.textContent = _('never updated');
		if (count) count.textContent = '';
		if (src) src.textContent = '';
		if (status) { status.textContent = ''; status.style.color = ''; }
		return;
	}
	if (when) when.textContent = util.fmtAge(stamp.ts) + (stamp.iso ? ' (' + stamp.iso + ')' : '');
	if (count) count.textContent = stamp.count ? (stamp.count + ' CIDRs') : '';
	if (src) src.textContent = stamp.source ? ('source: ' + stamp.source) : '';
	if (status) {
		status.textContent = stamp.status || '';
		status.style.color = (stamp.status === 'failed') ? '#a94442'
			: (stamp.status === 'updated' ? '#3c763d' : '#666');
	}
}

// ── Force-update stamp painter ───────────────────────────────────────────────
// Mirrors paintRuStamp but reads force-update.json which has per-source entries.
function paintForceStamp(stamp) {
	var whenEl  = document.getElementById('force-when');
	var countEl = document.getElementById('force-count');
	var statusEl = document.getElementById('force-status');

	if (!stamp) {
		if (whenEl)  whenEl.textContent  = _('never updated');
		if (countEl) countEl.textContent = '';
		if (statusEl) { statusEl.textContent = ''; statusEl.style.color = ''; }
		return;
	}

	if (whenEl) whenEl.textContent = util.fmtAge(stamp.ts);

	// Aggregate per-source counts and detect any failures.
	var totalCount = 0;
	var anyFailed = false;
	var sources = stamp.sources || {};
	var names = Object.keys(sources);
	for (var i = 0; i < names.length; i++) {
		var s = sources[names[i]];
		if (s && s.count) totalCount += (s.count || 0);
		if (s && s.status === 'failed') anyFailed = true;
	}

	if (countEl) countEl.textContent = totalCount ? (totalCount + ' entries') : '';
	if (statusEl) {
		statusEl.textContent = anyFailed ? _('some sources failed') : _('ok');
		statusEl.style.color = anyFailed ? '#a94442' : '#3c763d';
	}
}

// ── Tunnel apps helpers ───────────────────────────────────────────────────────

function parseApps(stdout) {
	if (!stdout) return [];
	try { return JSON.parse(stdout) || []; } catch (e) { return []; }
}

// Repaint the apps table from a live app list (called from refresh).
function paintAppsTable(view, apps) {
	var tbody = document.getElementById('tunnel-apps-tbody');
	if (!tbody) return;
	// Rebuild the tbody children.
	tbody.innerHTML = '';
	if (!apps || apps.length === 0) {
		var row = E('tr', {}, [
			E('td', { 'colspan': '5', 'style': 'color:#888;font-style:italic;' }, _('No apps configured.'))
		]);
		tbody.appendChild(row);
		return;
	}
	for (var i = 0; i < apps.length; i++) {
		(function(app) {
			var row = E('tr', {}, [
				E('td', {}, app.title || app.name),
				E('td', {}, app.kind),
				E('td', {}, String(app.count || 0)),
				E('td', {}, [
					E('input', {
						'type': 'checkbox',
						'id': 'app-cb-' + app.name,
						'checked': app.enabled === 1 || app.enabled === '1' ? '' : null,
						'change': ui.createHandlerFn(view, 'handleAppToggle', app.name)
					})
				]),
				E('td', {}, [
					E('button', {
						'class': 'btn cbi-button-negative',
						'style': 'padding:2px 8px;',
						'click': ui.createHandlerFn(view, 'handleAppRemove', app.name)
					}, _('Remove'))
				])
			]);
			tbody.appendChild(row);
		})(apps[i]);
	}
}

// ── Autotunnel worker helpers ─────────────────────────────────────────────────

function parseAutotunnelStatus(stdout) {
	if (!stdout) return null;
	try { return JSON.parse(stdout); } catch (e) { return null; }
}

// Repaint the autotunnel worker sub-panel from live status JSON.
// Called from refresh (safe to use getElementById).
function paintAutotunnelPanel(view, st) {
	var enabledEl   = document.getElementById('amz-at-enabled');
	var countEl     = document.getElementById('amz-at-count');
	var hcEl        = document.getElementById('amz-at-hourcount');
	var modeEl      = document.getElementById('amz-at-mode');
	var btnEl       = document.getElementById('amz-at-toggle-btn');
	var tbodyEl     = document.getElementById('amz-at-domains-tbody');

	if (!st) return;

	var on = st.enabled === 1 || st.enabled === '1';
	if (enabledEl) {
		enabledEl.textContent = on ? _('Enabled') : _('Disabled');
		if (enabledEl.dataset) enabledEl.dataset.enabled = on ? '1' : '0';
	}
	if (btnEl) btnEl.textContent = on ? _('Disable') : _('Enable');
	if (modeEl) modeEl.textContent = st.routing_mode || '';
	if (countEl) countEl.textContent = String(st.added_count || 0);
	if (hcEl) hcEl.textContent = String(st.hour_count || 0);

	if (!tbodyEl) return;
	tbodyEl.innerHTML = '';
	var domains = st.added || [];
	if (!domains || domains.length === 0) {
		tbodyEl.appendChild(E('tr', {}, [
			E('td', { 'colspan': '2', 'style': 'color:#888;font-style:italic;' }, _('No auto-added domains.'))
		]));
		return;
	}
	for (var i = 0; i < domains.length; i++) {
		(function(d) {
			tbodyEl.appendChild(E('tr', {}, [
				E('td', {}, d),
				E('td', {}, [
					E('button', {
						'class': 'btn cbi-button-negative',
						'style': 'padding:2px 8px;',
						'click': ui.createHandlerFn(view, 'handleAutotunnelRemove', d)
					}, _('Remove'))
				])
			]));
		})(domains[i]);
	}
}

// ── Probe-page / watch results painter ───────────────────────────────────────
// Called from refresh() after reading probe-page.json or watch.json.
// Safe to use getElementById (we're in refresh/handler context, DOM exists).
// No innerHTML with string interpolation — uses E() and text nodes only.
function paintProbePageResults(view, data) {
	var container = document.getElementById('amz-pp-results');
	if (!container) return;
	container.innerHTML = '';
	if (!data || !Array.isArray(data.hosts) || data.hosts.length === 0) return;
	_ppLastResult = data;

	// Progress line while running.
	if (data.running) {
		container.appendChild(E('p', { 'style': 'color:#666;margin:4px 0;' },
			_('probing… ') + String(data.done || 0) + '/' + String(data.total || 0)));
	}

	var tbody = E('tbody', {});
	for (var i = 0; i < data.hosts.length; i++) {
		(function(h) {
			// Color convention: throttled=red, ok=green, forced/ru=gray, other=gray.
			var statusColor = '#666';
			if (h.verdict === 'ok') statusColor = '#3c763d';
			else if (h.status === 'throttled') statusColor = '#c0392b';

			var verdictText = h.status || '';
			if (h.verdict && h.verdict !== h.status) verdictText += ' / ' + h.verdict;

			var dText = h.d_ms != null
				? String(h.d_ms) + 'ms' + (h.d_speed ? ' ' + String(h.d_speed) + 'KB/s' : '')
				: '';
			var tText = h.t_ms != null
				? String(h.t_ms) + 'ms' + (h.t_speed ? ' ' + String(h.t_speed) + 'KB/s' : '')
				: '';

			// "Add" button only for throttled and not yet added rows.
			var actionCell;
			if (h.status === 'throttled' && !h.added) {
				actionCell = E('td', { 'style': 'padding:2px 4px;' }, [
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'padding:2px 8px;',
						'click': ui.createHandlerFn(view, 'handleProbePageAdd', h.host)
					}, _('Add'))
				]);
			} else {
				actionCell = E('td', {
					'style': 'padding:2px 4px;color:#888;font-style:italic;'
				}, h.added ? _('added') : '');
			}

			tbody.appendChild(E('tr', {}, [
				E('td', { 'style': 'padding:2px 6px;' }, String(h.host || '')),
				E('td', { 'style': 'padding:2px 6px;color:' + statusColor + ';' }, verdictText),
				E('td', { 'style': 'padding:2px 6px;color:#666;font-size:11px;' }, dText),
				E('td', { 'style': 'padding:2px 6px;color:#666;font-size:11px;' }, tText),
				actionCell
			]));
		})(data.hosts[i]);
	}

	container.appendChild(E('table', { 'style': 'width:100%;border-collapse:collapse;margin-top:6px;' }, [
		E('thead', {}, [
			E('tr', {}, [
				E('th', { 'style': 'text-align:left;padding:2px 6px;border-bottom:1px solid #ccc;' }, _('Host')),
				E('th', { 'style': 'text-align:left;padding:2px 6px;border-bottom:1px solid #ccc;' }, _('Status / Verdict')),
				E('th', { 'style': 'text-align:left;padding:2px 6px;border-bottom:1px solid #ccc;' }, _('Direct')),
				E('th', { 'style': 'text-align:left;padding:2px 6px;border-bottom:1px solid #ccc;' }, _('Tunnel')),
				E('th', { 'style': 'text-align:left;padding:2px 6px;border-bottom:1px solid #ccc;' }, _('Action'))
			])
		]),
		tbody
	]));

	// "Add all throttled" button when run is complete and ≥1 throttled non-added row.
	if (!data.running) {
		var throttledCount = 0;
		for (var j = 0; j < data.hosts.length; j++) {
			if (data.hosts[j].status === 'throttled' && !data.hosts[j].added) throttledCount++;
		}
		if (throttledCount > 0) {
			container.appendChild(E('div', { 'style': 'margin-top:6px;' }, [
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(view, 'handleProbePageAddAll')
				}, _('Add all throttled (') + String(throttledCount) + ')')
			]));
		}
	}
}

// Build autotunnel domains table rows synchronously for first-paint.
function renderAutotunnelRows(view, st) {
	var domains = (st && st.added) || [];
	if (!domains || domains.length === 0) {
		return [E('tr', {}, [
			E('td', { 'colspan': '2', 'style': 'color:#888;font-style:italic;' }, _('No auto-added domains.'))
		])];
	}
	var rows = [];
	for (var i = 0; i < domains.length; i++) {
		(function(d) {
			rows.push(E('tr', {}, [
				E('td', {}, d),
				E('td', {}, [
					E('button', {
						'class': 'btn cbi-button-negative',
						'style': 'padding:2px 8px;',
						'click': ui.createHandlerFn(view, 'handleAutotunnelRemove', d)
					}, _('Remove'))
				])
			]));
		})(domains[i]);
	}
	return rows;
}

return baseclass.extend({
	handlers: {
		// ── handleRoutingMode ────────────────────────────────────────────────────
		// Routing-mode radio: tunnel-default vs direct-default.
		// Guarded by uiConfirm (changes routing for the whole LAN).
		handleRoutingMode: function(ev) {
			if (routingModeInFlight) return Promise.resolve();
			var sel = document.getElementById('routing-mode-select');
			if (!sel) return Promise.resolve();
			var newMode = sel.value;
			var msg = newMode === 'direct-default'
				? _('Switch to DIRECT-DEFAULT (allowlist) mode?\n\nOnly addresses in the force-tunnel list will use the tunnel. Everything else goes direct via WAN + zapret. Change takes effect immediately for new connections.')
				: _('Switch to TUNNEL-DEFAULT mode?\n\nAll foreign traffic routes through the tunnel; RU addresses go direct. Change takes effect immediately for new connections.');
			routingModeInFlight = true;
			return util.uiConfirm(msg).then(L.bind(function(ok) {
				if (!ok) { routingModeInFlight = false; return null; }
				if (sel) sel.disabled = true;
				return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-routing-mode', newMode]).then(L.bind(function(res) {
					ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
						(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
						res.code === 0 ? 'info' : 'warning');
					routingModeInFlight = false;
					if (sel) sel.disabled = false;
					return this.refresh();
				}, this)).catch(function(err) {
					ui.addNotification(null, E('p', {}, _('set-routing-mode failed: ') + err), 'danger');
					routingModeInFlight = false;
					var s = document.getElementById('routing-mode-select');
					if (s) s.disabled = false;
				});
			}, this));
		},

		// ── handleSourceToggle ───────────────────────────────────────────────────
		// Checkbox toggle for a force_source enabled state.
		handleSourceToggle: function(sourceName, ev) {
			var cb = document.getElementById('force-src-' + sourceName);
			if (!cb) return Promise.resolve();
			var enabled = cb.checked ? '1' : '0';
			cb.disabled = true;
			return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-source', sourceName, enabled]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				if (cb) cb.disabled = false;
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('set-source failed: ') + err), 'danger');
				if (cb) { cb.disabled = false; cb.checked = !cb.checked; }
			});
		},

		// ── handleForceUpdate ────────────────────────────────────────────────────
		// "Update now" button — runs amnezia-force-update synchronously.
		handleForceUpdate: function(ev) {
			if (forceUpdateInFlight) {
				ui.addNotification(null, E('p', {}, _('An update is already running')), 'info');
				return Promise.resolve();
			}
			forceUpdateInFlight = true;
			var btn = document.getElementById('force-update-btn');
			if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Updating...'); }
			return fs.exec('/usr/bin/amnezia-force-update').then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				forceUpdateInFlight = false;
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Update now'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Force update failed: ') + err), 'danger');
				forceUpdateInFlight = false;
				var b = document.getElementById('force-update-btn');
				if (b) { delete b.dataset.busy; b.disabled = false; b.textContent = _('Update now'); }
			});
		},

		// ── handleSaveManual ─────────────────────────────────────────────────────
		// Saves the manual force-tunnel list via amnezia-force-load save-manual.
		// Content goes as an argv element (no fs.write — the proven channel).
		handleSaveManual: function(ev) {
			if (saveManualInFlight) {
				ui.addNotification(null, E('p', {}, _('A save is already in progress')), 'info');
				return Promise.resolve();
			}
			var ta = document.getElementById('manual-list-ta');
			var content = (ta && ta.value) || '';
			// Validate: each non-blank, non-comment line must be a domain or IPv4/CIDR.
			var lines = content.split('\n');
			for (var i = 0; i < lines.length; i++) {
				var line = lines[i].replace(/#.*$/, '').trim();
				if (!line) continue;
				// Accept IPv4/CIDR or domain name; reject anything else.
				if (!/^[0-9.\/]+$/.test(line) && !/^[A-Za-z0-9.\-_]+$/.test(line)) {
					ui.addNotification(null, E('p', {}, _('Invalid entry (line ') + (i + 1) + '): ' + line), 'warning');
					return Promise.resolve();
				}
			}
			saveManualInFlight = true;
			var btn = document.getElementById('manual-save-btn');
			if (btn) { btn.disabled = true; btn.textContent = _('Saving...'); }
			return fs.exec('/usr/bin/amnezia-force-load', ['save-manual', content]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				saveManualInFlight = false;
				if (btn) { btn.disabled = false; btn.textContent = _('Save & apply'); }
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Save manual list failed: ') + err), 'danger');
				saveManualInFlight = false;
				var b = document.getElementById('manual-save-btn');
				if (b) { b.disabled = false; b.textContent = _('Save & apply'); }
			});
		},

		handleRuUpdate: function(ev) {
			var btn = document.getElementById('awg-ru-btn');
			if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Updating...'); }
			return fs.exec('/usr/bin/amnezia-ru-cidr').then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					(res.code === 0) ? 'info' : 'warning');
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Update now'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Update failed: ') + err), 'danger');
				var b = document.getElementById('awg-ru-btn');
				if (b) { delete b.dataset.busy; b.disabled = false; b.textContent = _('Update now'); }
			});
		},

		// ── Tunnel-apps handlers ──────────────────────────────────────────────────
		// LuCI createHandlerFn convention: extra args FIRST, event LAST.
		// handleAppToggle(name, ev) — name from createHandlerFn extra arg.
		handleAppToggle: function(name, ev) {
			var cb = document.getElementById('app-cb-' + name);
			var enabled = (cb && cb.checked) ? '1' : '0';
			if (cb) cb.disabled = true;
			return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-source', name, enabled]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				if (cb) cb.disabled = false;
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Toggle failed: ') + err), 'danger');
				var c = document.getElementById('app-cb-' + name);
				if (c) { c.disabled = false; c.checked = !c.checked; }
			});
		},

		// handleAppRemove(name, ev) — name from createHandlerFn extra arg.
		handleAppRemove: function(name, ev) {
			var self = this;
			return util.uiConfirm(_('Remove app "') + name + '"?').then(L.bind(function(ok) {
				if (!ok) return Promise.resolve();
				return fs.exec('/usr/bin/amnezia-app-ctl', ['remove', name]).then(L.bind(function(res) {
					ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
						(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
						res.code === 0 ? 'info' : 'warning');
					return self.refresh();
				}, this)).catch(function(err) {
					ui.addNotification(null, E('p', {}, _('Remove failed: ') + err), 'danger');
				});
			}, this));
		},

		// handleAppPreset(presetId, ev) — presetId from createHandlerFn extra arg.
		handleAppPreset: function(presetId, ev) {
			// Preset title map (kept in sync with amnezia-app-ctl.sh presets).
			var titles = {
				telegram: 'Telegram',
				meta: 'Meta (WhatsApp/Instagram/FB)',
				x: 'X (Twitter)',
				discord: 'Discord',
				tiktok: 'TikTok',
				viber: 'Viber',
				linkedin: 'LinkedIn',
				netflix: 'Netflix',
				google: 'Google (Meet/media, AS15169)'
			};
			var title = titles[presetId] || presetId;
			var self = this;
			return fs.exec('/usr/bin/amnezia-app-ctl', ['add', presetId, title, 'preset', presetId]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Preset failed: ') + err), 'danger');
			});
		},

		// handleAutotunnelAdd(ev) — NO extra arg; reads domain from DOM input.
		// Domain is read inside the handler so no extra arg is needed, avoiding
		// the createHandlerFn event-LAST arg-order trap.
		handleAutotunnelAdd: function(ev) {
			var el = document.getElementById('amz-autotunnel-domain');
			var d = (el && el.value || '').trim();
			if (!d) {
				ui.addNotification(null, E('p', {}, _('Enter a domain')));
				return Promise.resolve();
			}
			var self = this;
			return fs.exec('/usr/bin/amnezia-autotunnel', ['add', d]).then(L.bind(function(res) {
				var out = (res && res.stdout) || '';
				var parsed = null;
				try { parsed = JSON.parse(out); } catch (e) { parsed = null; }
				var msg = '';
				if (parsed && parsed.error) {
					msg = _('Error: ') + parsed.error;
				} else if (parsed && parsed.result) {
					msg = _('Result: ') + parsed.result;
					if (parsed.verdict) msg += ' (verdict: ' + parsed.verdict + ')';
				} else {
					msg = out || (res && res.stderr) || _('done');
				}
				ui.addNotification(null, E('p', {}, msg),
					(res && res.code === 0) ? 'info' : 'warning');
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('autotunnel add failed: ') + err), 'danger');
			});
		},

		// handleAutotunnelToggle(ev) — NO extra arg; reads current state from DOM.
		// Calls `amnezia-autotunnel enable` or `disable` depending on current state.
		handleAutotunnelToggle: function(ev) {
			if (autotunnelToggleInFlight) return Promise.resolve();
			var enabledEl = document.getElementById('amz-at-enabled');
			var currentlyEnabled = enabledEl && enabledEl.dataset && enabledEl.dataset.enabled === '1';
			autotunnelToggleInFlight = true;
			var verb = currentlyEnabled ? 'disable' : 'enable';
			return fs.exec('/usr/bin/amnezia-autotunnel', [verb]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				autotunnelToggleInFlight = false;
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('autotunnel toggle failed: ') + err), 'danger');
				autotunnelToggleInFlight = false;
			});
		},

		// handleAutotunnelRemove(domain, ev) — domain from createHandlerFn extra arg (FIRST).
		// LuCI createHandlerFn convention: extra args FIRST, event LAST.
		// Defined as function(domain, ev) — domain arrives first, event last.
		// Getting the order backwards would send the event object to the backend — silent no-op.
		handleAutotunnelRemove: function(domain, ev) {
			var self = this;
			return util.uiConfirm(_('Remove auto-tunnel entry "') + domain + '"?').then(L.bind(function(ok) {
				if (!ok) return Promise.resolve();
				return fs.exec('/usr/bin/amnezia-autotunnel', ['remove', domain]).then(L.bind(function(res) {
					ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
						(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
						res.code === 0 ? 'info' : 'warning');
					return self.refresh();
				}, this)).catch(function(err) {
					ui.addNotification(null, E('p', {}, _('Remove failed: ') + err), 'danger');
				});
			}, this));
		},

		// ── Probe-page / watch handlers ───────────────────────────────────────────

		// handleProbePage(ev) — NO extra arg; reads URL from the shared domain input.
		handleProbePage: function(ev) {
			var el = document.getElementById('amz-autotunnel-domain');
			var url = (el && el.value || '').trim();
			if (!url) {
				ui.addNotification(null, E('p', {}, _('Enter a URL or domain')));
				return Promise.resolve();
			}
			ppActiveFile = '/tmp/amnezia-fo/probe-page.json';
			var self = this;
			return fs.exec('/usr/bin/amnezia-autotunnel', ['probe-page', url, '--async']).then(L.bind(function(res) {
				ui.addNotification(null, E('p', {}, _('Probe page started')),
					(res && res.code === 0) ? 'info' : 'warning');
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('probe-page failed: ') + err), 'danger');
			});
		},

		// handleWatch(ev) — NO extra arg.
		handleWatch: function(ev) {
			ppActiveFile = '/tmp/amnezia-fo/watch.json';
			var self = this;
			return fs.exec('/usr/bin/amnezia-autotunnel', ['watch', '30', '--async']).then(L.bind(function(res) {
				ui.addNotification(null, E('p', {}, _('Watching 30s — reload the problem site now on your device')),
					(res && res.code === 0) ? 'info' : 'warning');
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('watch failed: ') + err), 'danger');
			});
		},

		// handleProbePageAdd(host, ev) — host from createHandlerFn extra arg (FIRST).
		// LuCI createHandlerFn convention: extra args FIRST, event LAST.
		// Defined as function(host, ev): host arrives first, event last.
		handleProbePageAdd: function(host, ev) {
			var self = this;
			return fs.exec('/usr/bin/amnezia-autotunnel', ['add', host, '--force']).then(L.bind(function(res) {
				ui.addNotification(null, E('p', {}, _('Added: ') + host),
					(res && res.code === 0) ? 'info' : 'warning');
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Add failed: ') + err), 'danger');
			});
		},

		// handleProbePageAddAll(ev) — NO extra arg; reads throttled hosts from _ppLastResult.
		// Chains sequential add calls then notifies and refreshes.
		handleProbePageAddAll: function(ev) {
			if (!_ppLastResult || !Array.isArray(_ppLastResult.hosts)) return Promise.resolve();
			var hosts = [];
			for (var i = 0; i < _ppLastResult.hosts.length; i++) {
				var h = _ppLastResult.hosts[i];
				if (h.status === 'throttled' && !h.added) hosts.push(h.host);
			}
			if (!hosts.length) return Promise.resolve();
			var self = this;
			var chain = Promise.resolve();
			for (var j = 0; j < hosts.length; j++) {
				(function(host) {
					chain = chain.then(function() {
						return fs.exec('/usr/bin/amnezia-autotunnel', ['add', host, '--force']).catch(function(){});
					});
				})(hosts[j]);
			}
			return chain.then(function() {
				ui.addNotification(null, E('p', {}, _('Added all throttled hosts')), 'info');
				return self.refresh();
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Add all failed: ') + err), 'danger');
			});
		},

		// handleAppAdd(ev) — NO extra arg; reads form fields in the handler (DOM exists here).
		handleAppAdd: function(ev) {
			if (appAddInFlight) {
				ui.addNotification(null, E('p', {}, _('An add is already in progress')), 'info');
				return Promise.resolve();
			}
			var nameEl   = document.getElementById('app-add-name');
			var titleEl  = document.getElementById('app-add-title');
			var methEl   = document.querySelector('input[name="app-add-method"]:checked');
			var asEl     = document.getElementById('app-add-asn');
			var cidrEl   = document.getElementById('app-add-cidrs');
			var urlEl    = document.getElementById('app-add-url');

			var name  = nameEl  ? nameEl.value.trim()  : '';
			var title = titleEl ? titleEl.value.trim()  : '';
			var meth  = methEl  ? methEl.value          : 'as';
			var data  = '';
			switch (meth) {
				case 'as':     data = asEl   ? asEl.value.trim()   : ''; break;
				case 'static': data = cidrEl ? cidrEl.value.trim() : ''; break;
				case 'url':    data = urlEl  ? urlEl.value.trim()  : ''; break;
			}

			if (!name) {
				ui.addNotification(null, E('p', {}, _('App name is required')), 'warning');
				return Promise.resolve();
			}
			if (!/^[a-z0-9_]+$/.test(name)) {
				ui.addNotification(null, E('p', {}, _('Name must match ^[a-z0-9_]+$')), 'warning');
				return Promise.resolve();
			}
			if (!data) {
				ui.addNotification(null, E('p', {}, _('Method data is required')), 'warning');
				return Promise.resolve();
			}

			appAddInFlight = true;
			var btn = document.getElementById('app-add-btn');
			if (btn) { btn.disabled = true; btn.textContent = _('Adding...'); }
			var self = this;
			return fs.exec('/usr/bin/amnezia-app-ctl', ['add', name, title || name, meth, data]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				appAddInFlight = false;
				if (btn) { btn.disabled = false; btn.textContent = _('Add'); }
				// Clear form on success.
				if (res.code === 0) {
					if (nameEl) nameEl.value = '';
					if (titleEl) titleEl.value = '';
					if (asEl) asEl.value = '';
					if (cidrEl) cidrEl.value = '';
					if (urlEl) urlEl.value = '';
				}
				return self.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Add failed: ') + err), 'danger');
				appAddInFlight = false;
				var b = document.getElementById('app-add-btn');
				if (b) { b.disabled = false; b.textContent = _('Add'); }
			});
		},
	},

	// ── applyFailoverState ───────────────────────────────────────────────────
	// Reconciles routing-mode select + source checkboxes from live failover state.
	// Called from refresh (p5) after reading /var/run/amnezia-failover.json.
	// Preserves both activeElement guards (C1 + H1).
	applyFailoverState: function(st) {
		// C1: repaint routing-mode select from live state. Guard: skip when
		// the select is focused (user may be mid-interaction).
		var routingSel = document.getElementById('routing-mode-select');
		if (routingSel && document.activeElement !== routingSel && st && st.routing_mode) {
			routingSel.value = st.routing_mode;
		}
		// H1: repaint source checkboxes from live state. Guard: skip each box
		// when it currently has focus (user may be mid-click).
		if (st && st.sources) {
			var sourceNames = ['itdoginfo_inside', 'itdoginfo_services', 'refilter_domains', 'refilter_ip', 'antifilter'];
			for (var si = 0; si < sourceNames.length; si++) {
				var sn = sourceNames[si];
				if (Object.prototype.hasOwnProperty.call(st.sources, sn)) {
					var cb = document.getElementById('force-src-' + sn);
					if (cb && document.activeElement !== cb) {
						cb.checked = !!st.sources[sn];
					}
				}
			}
		}
	},

	// ── renderAutotunnelRows: build <tr> nodes from autotunnel status (synchronous, no getElementById) ──
	// Delegates to the module-level helper so the same logic is shared
	// between first-paint (render) and refresh (paintAutotunnelPanel).
	renderAutotunnelRows: function(view, st) {
		return renderAutotunnelRows(view, st);
	},

	// ── renderAppsRows: build <tr> nodes from an apps array (synchronous, no getElementById) ──
	renderAppsRows: function(view, apps) {
		if (!apps || apps.length === 0) {
			return [E('tr', {}, [
				E('td', { 'colspan': '5', 'style': 'color:#888;font-style:italic;' }, _('No apps configured.'))
			])];
		}
		var rows = [];
		for (var i = 0; i < apps.length; i++) {
			(function(app) {
				rows.push(E('tr', {}, [
					E('td', {}, app.title || app.name),
					E('td', {}, app.kind),
					E('td', {}, String(app.count || 0)),
					E('td', {}, [
						E('input', {
							'type': 'checkbox',
							'id': 'app-cb-' + app.name,
							'checked': (app.enabled === 1 || app.enabled === '1') ? '' : null,
							'change': ui.createHandlerFn(view, 'handleAppToggle', app.name)
						})
					]),
					E('td', {}, [
						E('button', {
							'class': 'btn cbi-button-negative',
							'style': 'padding:2px 8px;',
							'click': ui.createHandlerFn(view, 'handleAppRemove', app.name)
						}, _('Remove'))
					])
				]));
			})(apps[i]);
		}
		return rows;
	},

	render: function(view, data) {
		// data[0] → parseRuStamp (RU stamp)
		// data[8] → forceTunnelList prefill
		// data[9] → parseRuStamp + forceStamp/forceWhen/forceTotal/forceFailed block
		// data[12] → amnezia-app-ctl list JSON for first-paint tunnel apps table
		// data[13] → amnezia-autotunnel status JSON for first-paint worker panel
		var stamp = parseRuStamp(data && data[0]);
		var forceTunnelList = (data && data[8]) || '';
		var forceStamp = parseRuStamp(data && data[9]);
		// Parse index 12: app list for first-paint (may be result object or raw string).
		var appsData12 = data && data[12];
		var appsStdout = appsData12 && typeof appsData12 === 'object' ? (appsData12.stdout || '[]') : (appsData12 || '[]');
		var initialApps = parseApps(appsStdout);
		// Parse index 13: autotunnel worker status for first-paint.
		var atData13 = data && data[13];
		var atStdout = atData13 && typeof atData13 === 'object' ? (atData13.stdout || '') : (atData13 || '');
		var initialAtStatus = parseAutotunnelStatus(atStdout);
		var atEnabled = initialAtStatus && (initialAtStatus.enabled === 1 || initialAtStatus.enabled === '1');
		var forceWhen = forceStamp ? util.fmtAge(forceStamp.ts) : _('never updated');
		var forceTotal = 0, forceFailed = false;
		if (forceStamp && forceStamp.sources) {
			var _fsn = Object.keys(forceStamp.sources);
			for (var _fi = 0; _fi < _fsn.length; _fi++) {
				var _fs = forceStamp.sources[_fsn[_fi]];
				if (_fs && _fs.count) forceTotal += (_fs.count || 0);
				if (_fs && _fs.status === 'failed') forceFailed = true;
			}
		}
		// failoverState is needed for routing-mode select initial value + source checkbox state.
		// It comes from data[7] but routing.render only reads it for the routing-mode select
		// and source checkboxes — we parse it here for that purpose.
		var failoverState = (function(text) {
			if (!text) return null;
			try { return JSON.parse(text); } catch (e) { return null; }
		})(data && data[7]);

		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Routing & Allowlist')),

			// ── Routing mode section ──────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Routing mode')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Tunnel-default: all foreign traffic routes through the tunnel (RU addresses go direct). Direct-default (allowlist): only addresses in the force-tunnel list use the tunnel; everything else goes via WAN + zapret.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Active mode')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('select', {
								'id': 'routing-mode-select',
								'class': 'cbi-input-select',
								'style': 'width:280px;margin-right:8px;',
								'change': ui.createHandlerFn(view, 'handleRoutingMode')
							}, [
								E('option', {
									'value': 'tunnel-default',
									'selected': (!failoverState || (failoverState.routing_mode || 'tunnel-default') === 'tunnel-default') ? '' : null
								}, _('Tunnel-default (foreign → tunnel)')),
								E('option', {
									'value': 'direct-default',
									'selected': (failoverState && failoverState.routing_mode === 'direct-default') ? '' : null
								}, _('Direct-default (allowlist → tunnel)'))
							])
						])
					])
				])
			]),

			// ── Allowlist sources section ─────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Allowlist sources (force-tunnel list)')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Curated domain/IP lists that feed the force-tunnel set. Checked sources are fetched on update. In direct-default mode, only listed addresses use the tunnel.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Sources')),
						E('div', { 'class': 'cbi-value-field' }, [
							(function(self, fst) {
								// H1: drive checked state from live failover state sources map.
								// Fall back to defaultOn only when the daemon hasn't emitted sources yet.
								var liveSources = (fst && fst.sources) || null;
								var sourceDefs = [
									{ name: 'itdoginfo_inside',   label: 'itdoginfo (RKN-blocked, inside)',   defaultOn: true },
									{ name: 'itdoginfo_services', label: 'itdoginfo (geoblock-RU services)',   defaultOn: true },
									{ name: 'refilter_domains',   label: 'Re-filter (domains, broader)',        defaultOn: false },
									{ name: 'refilter_ip',        label: 'Re-filter (IP/CIDR)',                 defaultOn: false },
									{ name: 'antifilter',         label: 'antifilter.download (supplementary)', defaultOn: false }
								];
								var box = E('div', {});
								for (var si = 0; si < sourceDefs.length; si++) {
									(function(sd) {
										// Use live UCI-backed state when available; fall back to defaultOn.
										var isChecked = liveSources && Object.prototype.hasOwnProperty.call(liveSources, sd.name)
											? !!liveSources[sd.name]
											: sd.defaultOn;
										box.appendChild(E('label', { 'style': 'display:block;margin-bottom:4px;' }, [
											E('input', {
												'id': 'force-src-' + sd.name,
												'type': 'checkbox',
												'style': 'margin-right:6px;',
												'checked': isChecked ? '' : null,
												'change': ui.createHandlerFn(view, 'handleSourceToggle', sd.name)
											}),
											E('span', {}, _(sd.label))
										]));
									})(sourceDefs[si]);
								}
								return box;
							})(view, failoverState)
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Last update')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('strong', { 'id': 'force-when' }, forceWhen),
							E('span', { 'id': 'force-count', 'style': 'margin-left:12px;color:#666;' },
								forceTotal ? (forceTotal + ' entries') : ''),
							E('span', { 'id': 'force-status',
								'style': 'margin-left:8px;color:' + (forceStamp ? (forceFailed ? '#a94442' : '#3c763d') : '') + ';' },
								forceStamp ? (forceFailed ? _('some sources failed') : _('ok')) : '')
						])
					]),

					// Update sources action — nested collapsed sub-panel
					E('details', { 'class': 'amnezia-action' }, [
						E('summary', {}, _('Update sources')),
						E('div', { 'class': 'cbi-section-node' }, [
							E('div', { 'class': 'cbi-value' }, [
								E('label', { 'class': 'cbi-value-title' }, _('Action')),
								E('div', { 'class': 'cbi-value-field' }, [
									E('button', {
										'id': 'force-update-btn',
										'class': 'btn cbi-button-action',
										'click': ui.createHandlerFn(view, 'handleForceUpdate')
									}, _('Update now'))
								])
							])
						])
					])
				])
			]),

			// ── Manual entries section — nested collapsed sub-panel ───────────
			E('details', { 'class': 'amnezia-action' }, [
				E('summary', {}, _('Manual force-tunnel entries')),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-map-descr' },
						_('Domains and IPs/CIDRs that always go through the tunnel, regardless of routing mode. Auto-update never touches this list. One entry per line; # comments allowed.')),
					E('div', { 'class': 'cbi-section-node' }, [
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Entries')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('textarea', {
									'id': 'manual-list-ta',
									'class': 'cbi-input-text',
									'style': 'width:100%;height:120px;font-family:monospace;font-size:11px;box-sizing:border-box;',
									'placeholder': '# one domain or IP/CIDR per line\nchatgpt.com\nspotify.com\n203.0.113.0/24'
								}, forceTunnelList)
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Action')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('button', {
									'id': 'manual-save-btn',
									'class': 'btn cbi-button-positive',
									'click': ui.createHandlerFn(view, 'handleSaveManual')
								}, _('Save & apply'))
							])
						])
					])
				])
			]),

			// ── Autotunnel: probe & add action — collapsed sub-panel ─────────
			E('details', { 'class': 'amnezia-action' }, [
				E('summary', {}, _('Tunnel a site (auto-probe)')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Domain / URL')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'amz-autotunnel-domain',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:320px;',
								'placeholder': 'example.com or https://example.com/page'
							})
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'amz-autotunnel-btn',
								'class': 'btn cbi-button-action',
								'style': 'margin-right:6px;',
								'click': ui.createHandlerFn(view, 'handleAutotunnelAdd')
							}, _('Probe & add')),
							E('button', {
								'id': 'amz-pp-btn',
								'class': 'btn cbi-button-action',
								'style': 'margin-right:6px;',
								'click': ui.createHandlerFn(view, 'handleProbePage')
							}, _('Probe page')),
							E('button', {
								'id': 'amz-watch-btn',
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(view, 'handleWatch')
							}, _('Watch 30s'))
						])
					]),
					// Results container — empty on first paint, populated by refresh()
					// after probe-page or watch completes each poll tick.
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Page results')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'amz-pp-results' })
						])
					])
				])
			]),

			// ── Auto-tunnel worker section — collapsed ───────────────────────
			E('details', { 'class': 'amnezia-action' }, [
				E('summary', {}, _('Auto-tunnel throttled sites (background)')),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-map-descr' },
						_('Background worker that monitors DNS queries and auto-adds throttled sites to the force-tunnel list. Default OFF. Only effective in direct-default mode.')),
					E('div', { 'class': 'cbi-section-node' }, [
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('State')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('strong', {
									'id': 'amz-at-enabled',
									'data-enabled': atEnabled ? '1' : '0'
								}, atEnabled ? _('Enabled') : _('Disabled')),
								E('button', {
									'id': 'amz-at-toggle-btn',
									'class': 'btn ' + (atEnabled ? 'cbi-button-negative' : 'cbi-button-positive'),
									'style': 'margin-left:12px;',
									'click': ui.createHandlerFn(view, 'handleAutotunnelToggle')
								}, atEnabled ? _('Disable') : _('Enable'))
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Routing mode')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('span', { 'id': 'amz-at-mode' }, initialAtStatus ? (initialAtStatus.routing_mode || '') : '')
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Auto-added')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('span', { 'id': 'amz-at-count' }, String((initialAtStatus && initialAtStatus.added_count) || 0)),
								E('span', { 'style': 'margin-left:12px;color:#666;' }, _('added this hour: ')),
								E('span', { 'id': 'amz-at-hourcount' }, String((initialAtStatus && initialAtStatus.hour_count) || 0))
							])
						]),
						// Auto-added domains table — built synchronously on first paint.
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Auto-added domains')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('table', { 'style': 'width:100%;border-collapse:collapse;' }, [
									E('thead', {}, [
										E('tr', {}, [
											E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Domain')),
											E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Actions'))
										])
									]),
									E('tbody', { 'id': 'amz-at-domains-tbody' }, (function(self2, v, st2) {
										return self2.renderAutotunnelRows(v, st2);
									})(this, view, initialAtStatus))
								])
							])
						])
					])
				])
			]),

			// ── Tunnel apps section ───────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Tunnel apps')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Per-app CIDR lists. In direct-default mode these IPs route through the tunnel. Add apps by AS number, pasted CIDRs, or URL, or use a built-in preset.')),

				// Apps table — populated synchronously on first paint from data[12].
				E('div', { 'class': 'cbi-section-node' }, [
					E('table', { 'style': 'width:100%;border-collapse:collapse;' }, [
						E('thead', {}, [
							E('tr', {}, [
								E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Title')),
								E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Kind')),
								E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('#CIDRs')),
								E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Enabled')),
								E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:1px solid #ccc;' }, _('Actions'))
							])
						]),
						// Rows built synchronously from data[12] so no blank-flash on first paint.
						E('tbody', { 'id': 'tunnel-apps-tbody' }, (function(self2, v, apps) {
							return self2.renderAppsRows(v, apps);
						})(this, view, initialApps))
					])
				]),

				// Preset buttons — one-click add for common apps.
				E('div', { 'class': 'cbi-section-node', 'style': 'margin-top:8px;' }, [
					E('strong', { 'style': 'display:block;margin-bottom:6px;' }, _('Quick presets:')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'telegram')
					}, _('Add Telegram')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'meta')
					}, _('Add Meta / WhatsApp')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'x')
					}, _('Add X (Twitter)')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'discord')
					}, _('Add Discord')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'tiktok')
					}, _('Add TikTok')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'viber')
					}, _('Add Viber')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'linkedin')
					}, _('Add LinkedIn')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right:8px;margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'netflix')
					}, _('Add Netflix')),
					E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-bottom:6px;',
						'click': ui.createHandlerFn(view, 'handleAppPreset', 'google')
					}, _('Add Google'))
				]),

				// Add-app form — collapsed action panel.
				E('details', { 'class': 'amnezia-action' }, [
					E('summary', {}, _('Add app')),
					E('div', { 'class': 'cbi-section-node' }, [
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Name')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('input', {
									'id': 'app-add-name',
									'type': 'text',
									'class': 'cbi-input-text',
									'style': 'width:180px;',
									'placeholder': 'e.g. myapp'
								})
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Title')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('input', {
									'id': 'app-add-title',
									'type': 'text',
									'class': 'cbi-input-text',
									'style': 'width:220px;',
									'placeholder': _('Display name (optional)')
								})
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Method')),
							E('div', { 'class': 'cbi-value-field' }, [
								// Method radio buttons + inline data fields.
								E('div', { 'style': 'margin-bottom:6px;' }, [
									E('label', { 'style': 'margin-right:16px;' }, [
										E('input', { 'type': 'radio', 'name': 'app-add-method', 'value': 'as', 'checked': '' }),
										_(' AS number')
									]),
									E('label', { 'style': 'margin-right:16px;' }, [
										E('input', { 'type': 'radio', 'name': 'app-add-method', 'value': 'static' }),
										_(' Paste CIDRs')
									]),
									E('label', {}, [
										E('input', { 'type': 'radio', 'name': 'app-add-method', 'value': 'url' }),
										_(' URL')
									])
								]),
								E('div', { 'style': 'margin-top:4px;' }, [
									E('input', {
										'id': 'app-add-asn',
										'type': 'text',
										'class': 'cbi-input-text',
										'style': 'width:120px;',
										'placeholder': _('e.g. 32934 or AS32934')
									})
								]),
								E('div', { 'style': 'margin-top:4px;' }, [
									E('textarea', {
										'id': 'app-add-cidrs',
										'class': 'cbi-input-text',
										'style': 'width:100%;height:80px;font-family:monospace;font-size:11px;box-sizing:border-box;',
										'placeholder': '91.108.4.0/22\n149.154.160.0/20'
									})
								]),
								E('div', { 'style': 'margin-top:4px;' }, [
									E('input', {
										'id': 'app-add-url',
										'type': 'text',
										'class': 'cbi-input-text',
										'style': 'width:360px;',
										'placeholder': 'https://example.com/cidrs.txt'
									})
								])
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('Action')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('button', {
									'id': 'app-add-btn',
									'class': 'btn cbi-button-positive',
									'click': ui.createHandlerFn(view, 'handleAppAdd')
								}, _('Add'))
							])
						])
					])
				]),

				// Help: how to find an app's AS number.
				E('details', { 'class': 'amnezia-action' }, [
					E('summary', {}, _('How to find an app\'s AS number')),
					E('div', { 'class': 'cbi-map-descr', 'style': 'margin:8px 0;' }, [
						E('ol', { 'style': 'margin:4px 0 4px 20px;padding:0;' }, [
							E('li', {}, _('Find the app\'s server IP — use nslookup <domain> or the app\'s own documentation.')),
							E('li', {}, [
								_('Look up that IP at '),
								E('a', { 'href': 'https://bgp.he.net', 'target': '_blank' }, 'bgp.he.net'),
								_(' or '),
								E('a', { 'href': 'https://ipinfo.io', 'target': '_blank' }, 'ipinfo.io/<ip>'),
								_(' — the AS field (ASxxxxx) is the network operator.')
							]),
							E('li', {}, _('Examples: Meta / WhatsApp / Instagram / Facebook = AS32934; Google = AS15169; X / Twitter = AS13414.')),
							E('li', {}, _('Note: Telegram spans several ASes — use its preset (static CIDR list) instead of a single AS.'))
						])
					])
				])
			]),

			// ── RU IP list section ────────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('RU IP list')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Russian IPv4 ranges used to bypass the tunnel. Auto-refreshes weekly via cron.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Last update')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('strong', { 'id': 'awg-ru-when' }, stamp ? util.fmtAge(stamp.ts) : _('never updated')),
							E('span', { 'id': 'awg-ru-status', 'style': 'margin-left:12px;' }, stamp ? (stamp.status || '') : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Details')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', { 'id': 'awg-ru-count', 'style': 'margin-right:12px;' }, stamp && stamp.count ? (stamp.count + ' CIDRs') : ''),
							E('span', { 'id': 'awg-ru-source', 'style': 'color:#666;' }, stamp && stamp.source ? ('source: ' + stamp.source) : '')
						])
					]),

					// Update RU now action — nested collapsed sub-panel
					E('details', { 'class': 'amnezia-action' }, [
						E('summary', {}, _('Update RU IP list')),
						E('div', { 'class': 'cbi-section-node' }, [
							E('div', { 'class': 'cbi-value' }, [
								E('label', { 'class': 'cbi-value-title' }, _('Action')),
								E('div', { 'class': 'cbi-value-field' }, [
									E('button', {
										'id': 'awg-ru-btn',
										'class': 'btn cbi-button-action',
										'click': ui.createHandlerFn(view, 'handleRuUpdate')
									}, _('Update now'))
								])
							])
						])
					])
				])
			])
		]);
	},

	refresh: function(view) {
		var p1 = L.resolveDefault(fs.read('/etc/amnezia/ru-update.json'), '').then(function(text) {
			paintRuStamp(parseRuStamp(text));
		});
		var p6 = L.resolveDefault(fs.read('/etc/amnezia/force-update.json'), '').then(function(text) {
			paintForceStamp(parseRuStamp(text));
		});
		// Refresh the apps table from the live CLI output.
		var pApps = L.resolveDefault(fs.exec('/usr/bin/amnezia-app-ctl', ['list']), { stdout: '[]' }).then(function(res) {
			var apps = [];
			try { apps = JSON.parse((res && res.stdout) ? res.stdout : (res || '[]')); } catch (e) { apps = []; }
			paintAppsTable(view, apps);
		});
		// Refresh the autotunnel worker status panel.
		var pAt = L.resolveDefault(fs.exec('/usr/bin/amnezia-autotunnel', ['status']), { stdout: '' }).then(function(res) {
			var st = parseAutotunnelStatus((res && res.stdout) || '');
			paintAutotunnelPanel(view, st);
		});
		// Read active probe-page or watch result file (whichever was last started).
		var pPP = ppActiveFile
			? L.resolveDefault(fs.read(ppActiveFile), '').then(function(text) {
				var data = null;
				try { if (text) data = JSON.parse(text); } catch (e) {}
				paintProbePageResults(view, data);
			})
			: Promise.resolve();
		return Promise.all([p1, p6, pApps, pAt, pPP]);
	}
});
