'use strict';
'require baseclass';
'require fs';
'require ui';
'require amnezia.util as util';

// ---- file-scope private state (moved verbatim from main.js) ----
var routingModeInFlight = false;
var forceUpdateInFlight = false;
var saveManualInFlight = false;

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

	render: function(view, data) {
		// data[0] → parseRuStamp (RU stamp)
		// data[8] → forceTunnelList prefill
		// data[9] → parseRuStamp + forceStamp/forceWhen/forceTotal/forceFailed block
		var stamp = parseRuStamp(data && data[0]);
		var forceTunnelList = (data && data[8]) || '';
		var forceStamp = parseRuStamp(data && data[9]);
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
		return Promise.all([p1, p6]);
	}
});
