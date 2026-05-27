'use strict';
'require view';
'require fs';
'require ui';
'require poll';

// Module-level handle for the poll callback. LuCI has no teardown hook for
// views, so the poller self-unregisters when its DOM anchor disappears
// (i.e. the user navigated to another page). On return, render() registers
// a fresh poller. Steady state during navigation: 0 active pollers.
var pollFn = null;

function parseStatus(text) {
	text = text || '';
	var up = /"up"\s*:\s*true/.test(text);
	var uptimeMatch = text.match(/"uptime"\s*:\s*(\d+)/);
	var uptime = uptimeMatch ? parseInt(uptimeMatch[1], 10) : null;
	return { up: up, uptime: uptime, raw: text };
}

function parseRuStamp(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseZapret(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseBlockcheck(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function fmtDur(sec) {
	if (!sec || sec < 0) return '0s';
	var m = Math.floor(sec / 60);
	var s = sec % 60;
	if (m >= 60) {
		var h = Math.floor(m / 60); m = m % 60;
		return h + 'h ' + m + 'm';
	}
	if (m > 0) return m + 'm ' + s + 's';
	return s + 's';
}

function fmtUptime(sec) {
	if (sec === null || sec === undefined) return '';
	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	if (d > 0) return d + 'd ' + h + 'h';
	if (h > 0) return h + 'h ' + m + 'm';
	return m + 'm';
}

function fmtAge(ts) {
	if (!ts) return 'never';
	var now = Math.floor(Date.now() / 1000);
	var age = now - ts;
	if (age < 60) return age + 's ago';
	if (age < 3600) return Math.floor(age / 60) + 'm ago';
	if (age < 86400) return Math.floor(age / 3600) + 'h ago';
	return Math.floor(age / 86400) + 'd ago';
}

function paintTunnel(s) {
	var dot = document.getElementById('awg-dot');
	var label = document.getElementById('awg-state-label');
	var uptimeEl = document.getElementById('awg-uptime');
	var btn = document.getElementById('awg-toggle-btn');
	var raw = document.getElementById('awg-status-raw');

	if (dot) dot.style.background = s.up ? '#3c763d' : '#a94442';
	if (label) label.textContent = s.up ? 'UP' : 'DOWN';
	if (uptimeEl) uptimeEl.textContent = s.up && s.uptime !== null ? '(uptime: ' + fmtUptime(s.uptime) + ')' : '';
	if (btn && !btn.dataset.busy) {
		btn.textContent = s.up ? _('Turn OFF') : _('Turn ON');
		btn.className = 'btn ' + (s.up ? 'cbi-button-negative' : 'cbi-button-positive');
		btn.disabled = false;
	}
	if (raw) raw.textContent = s.raw;
}

function paintZapret(s, errMsg) {
	var dot = document.getElementById('zapret-dot');
	var label = document.getElementById('zapret-state-label');
	var ver = document.getElementById('zapret-version');
	var mode = document.getElementById('zapret-mode');
	var strat = document.getElementById('zapret-strategy');
	var btn = document.getElementById('zapret-toggle-btn');

	// errMsg means we couldn't read status (script error / unparseable output) --
	// distinct from "package not installed". Leave previous fields alone where
	// possible, just mark dot red and show the error in the label.
	if (errMsg) {
		if (dot) dot.style.background = '#a94442';
		if (label) label.textContent = _('status error');
		if (strat) strat.textContent = errMsg;
		if (btn && !btn.dataset.busy) {
			btn.disabled = true;
			btn.textContent = _('N/A');
			btn.className = 'btn';
		}
		return;
	}

	if (!s || !s.installed) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = _('not installed');
		if (ver) ver.textContent = '';
		if (mode) mode.textContent = '';
		if (strat) strat.textContent = '';
		if (btn && !btn.dataset.busy) { btn.disabled = true; btn.textContent = _('N/A'); }
		return;
	}

	// Healthy = enabled AND running. Yellow = enabled but no process (broken
	// config or just-started). Gray = clean off. Red = running while disabled.
	var colour;
	if (s.enabled && s.running)        colour = '#3c763d';
	else if (s.enabled && !s.running)  colour = '#f0ad4e';
	else if (!s.enabled && s.running)  colour = '#a94442';
	else                                colour = '#888';

	if (dot) dot.style.background = colour;
	if (label) label.textContent = (s.enabled ? _('ON') : _('OFF')) + (s.running ? ' ' + _('(running)') : '');
	if (ver) ver.textContent = s.version ? ('v' + s.version) : '';
	if (mode) mode.textContent = (s.mode || '') + (s.filter ? (' / ' + s.filter) : '');
	if (strat) strat.textContent = s.strategy || '';
	if (btn && !btn.dataset.busy) {
		btn.textContent = s.enabled ? _('Turn OFF') : _('Turn ON');
		btn.className = 'btn ' + (s.enabled ? 'cbi-button-negative' : 'cbi-button-positive');
		btn.disabled = false;
	}
}

function paintBlockcheck(s) {
	var stateEl = document.getElementById('bc-state');
	var elapsedEl = document.getElementById('bc-elapsed');
	var runBtn = document.getElementById('bc-run-btn');
	var cancelBtn = document.getElementById('bc-cancel-btn');
	var input = document.getElementById('bc-domain');

	if (!s || s.status === 'never_run') {
		if (stateEl) stateEl.textContent = _('never run');
		if (elapsedEl) elapsedEl.textContent = '';
		if (runBtn) { runBtn.disabled = false; runBtn.textContent = _('Run'); }
		if (cancelBtn) cancelBtn.style.display = 'none';
		if (input) input.disabled = false;
		return;
	}

	var running = (s.status === 'running');
	var now = Math.floor(Date.now() / 1000);
	var elapsed = running
		? (now - (s.started_ts || now))
		: ((s.finished_ts || 0) - (s.started_ts || 0));

	if (stateEl) {
		var colour = running ? '#3c763d'
			: s.status === 'finished'  ? '#3c763d'
			: s.status === 'cancelled' ? '#666'
			: '#a94442';
		stateEl.textContent = s.status + (s.domain ? ' [' + s.domain + ']' : '');
		stateEl.style.color = colour;
	}
	if (elapsedEl) {
		if (running) elapsedEl.textContent = _('elapsed: ') + fmtDur(elapsed);
		else if (s.finished_ts) elapsedEl.textContent = _('took: ') + fmtDur(elapsed);
		else elapsedEl.textContent = '';
	}
	if (runBtn) {
		runBtn.disabled = running;
		runBtn.textContent = running ? _('Running...') : _('Run');
	}
	if (cancelBtn) cancelBtn.style.display = running ? '' : 'none';
	if (input) input.disabled = running;
}

function paintBlockcheckLog(text) {
	var pre = document.getElementById('bc-log');
	if (!pre) return;
	if (!text) { pre.textContent = '(no log yet)'; return; }
	pre.textContent = text;
	// Autoscroll to bottom while a run is in progress; cheap heuristic.
	pre.scrollTop = pre.scrollHeight;
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
	if (when) when.textContent = fmtAge(stamp.ts) + (stamp.iso ? ' (' + stamp.iso + ')' : '');
	if (count) count.textContent = stamp.count ? (stamp.count + ' CIDRs') : '';
	if (src) src.textContent = stamp.source ? ('source: ' + stamp.source) : '';
	if (status) {
		status.textContent = stamp.status || '';
		status.style.color = (stamp.status === 'failed') ? '#a94442'
			: (stamp.status === 'updated' ? '#3c763d' : '#666');
	}
}

return view.extend({
	handleToggle: function(ev) {
		var btn = document.getElementById('awg-toggle-btn');
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Working...'); }
		return fs.exec('/usr/bin/awg-toggle').then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')), 'info');
			if (btn) delete btn.dataset.busy;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Toggle failed: ') + err), 'danger');
			var b = document.getElementById('awg-toggle-btn');
			if (b) { delete b.dataset.busy; b.disabled = false; }
		});
	},

	handleBlockcheckRun: function(ev) {
		var input = document.getElementById('bc-domain');
		var domain = (input && input.value || '').trim() || 'youtube.com';
		// Domain validation: hostname chars only, no shell metachars (defensive --
		// fs.exec passes argv array so injection isn't possible, but reject
		// obvious garbage to avoid hour-long runs on bad input).
		if (!/^[A-Za-z0-9.\-_]{2,253}$/.test(domain)) {
			ui.addNotification(null, E('p', {}, _('Invalid domain: ') + domain), 'warning');
			return Promise.resolve();
		}
		var btn = document.getElementById('bc-run-btn');
		if (btn) { btn.disabled = true; btn.textContent = _('Starting...'); }
		return fs.exec('/usr/bin/zapret-blockcheck', ['start', domain]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				(res.code === 0) ? 'info' : 'warning');
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Blockcheck start failed: ') + err), 'danger');
			var b = document.getElementById('bc-run-btn');
			if (b) { b.disabled = false; b.textContent = _('Run'); }
		});
	},

	handleBlockcheckCancel: function(ev) {
		var btn = document.getElementById('bc-cancel-btn');
		if (btn) { btn.disabled = true; }
		return fs.exec('/usr/bin/zapret-blockcheck', ['cancel']).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')), 'info');
			if (btn) btn.disabled = false;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Blockcheck cancel failed: ') + err), 'danger');
			if (btn) btn.disabled = false;
		});
	},

	handleZapretToggle: function(ev) {
		var btn = document.getElementById('zapret-toggle-btn');
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Working...'); }
		return fs.exec('/usr/bin/zapret-toggle').then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				(res.code === 0) ? 'info' : 'warning');
			if (btn) delete btn.dataset.busy;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Zapret toggle failed: ') + err), 'danger');
			var b = document.getElementById('zapret-toggle-btn');
			if (b) { delete b.dataset.busy; b.disabled = false; }
		});
	},

	handleRuUpdate: function(ev) {
		var btn = document.getElementById('awg-ru-btn');
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Updating...'); }
		return fs.exec('/usr/bin/awg-ru-update').then(L.bind(function(res) {
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

	refresh: function() {
		// Self-unregister when the view's DOM is gone (user navigated away).
		if (!document.getElementById('awg-dot')) {
			if (pollFn) { poll.remove(pollFn); pollFn = null; }
			return Promise.resolve();
		}
		var p1 = fs.exec('/usr/bin/awg-status').then(function(res) {
			paintTunnel(parseStatus(res.stdout || res.stderr || ''));
		}).catch(function(err) {
			var raw = document.getElementById('awg-status-raw');
			if (raw) raw.textContent = 'status read failed: ' + err;
		});
		var p2 = L.resolveDefault(fs.read('/etc/awg/ru-update.json'), '').then(function(text) {
			paintRuStamp(parseRuStamp(text));
		});
		var p3 = L.resolveDefault(fs.exec('/usr/bin/zapret-status'), null).then(function(res) {
			if (!res) { paintZapret(null, _('cannot run zapret-status')); return; }
			var parsed = parseZapret(res.stdout || '');
			if (parsed) {
				paintZapret(parsed);
			} else if (res.code !== 0) {
				paintZapret(null, _('zapret-status exit ') + res.code);
			} else if ((res.stdout || '').length === 0) {
				paintZapret(null, _('zapret-status returned empty output'));
			} else {
				paintZapret(null, _('unparseable status output'));
			}
		});
		var p4 = L.resolveDefault(fs.read('/etc/awg/blockcheck.json'), '').then(L.bind(function(text) {
			var bc = parseBlockcheck(text);
			paintBlockcheck(bc);
			// Fetch log when there's anything to show. Skipped on never_run to
			// avoid an exec round-trip for users who never touched blockcheck.
			if (bc && bc.status && bc.status !== 'never_run' && bc.log_size > 0) {
				return fs.exec('/usr/bin/zapret-blockcheck', ['log']).then(function(r) {
					paintBlockcheckLog((r && r.stdout) || '');
				}).catch(function() { /* silent: status panel already shows state */ });
			}
		}, this));
		return Promise.all([p1, p2, p3, p4]);
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/awg-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/awg/ru-update.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/awg/blockcheck.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-blockcheck', ['log']), { stdout: '' })
		]);
	},

	render: function(data) {
		var initial = parseStatus((data && data[0] && data[0].stdout) || '');
		var stamp = parseRuStamp(data && data[1]);
		var zap = parseZapret((data && data[2] && data[2].stdout) || '');
		var bc = parseBlockcheck(data && data[3]);
		var bcLog = (data && data[4] && data[4].stdout) || '';

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('AmneziaWG')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Toggle the AmneziaWG tunnel and policy-based routing together. Status refreshes every 5 seconds.')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Tunnel')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('State')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'awg-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:' +
									(initial.up ? '#3c763d' : '#a94442') + ';margin-right:8px;vertical-align:middle;'
							}),
							E('strong', { 'id': 'awg-state-label' }, initial.up ? 'UP' : 'DOWN'),
							E('span', { 'id': 'awg-uptime', 'style': 'margin-left:8px;color:#666;' },
								initial.up && initial.uptime !== null ? '(uptime: ' + fmtUptime(initial.uptime) + ')' : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'awg-toggle-btn',
								'class': 'btn ' + (initial.up ? 'cbi-button-negative' : 'cbi-button-positive'),
								'click': ui.createHandlerFn(this, 'handleToggle')
							}, initial.up ? _('Turn OFF') : _('Turn ON'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('RU IP list')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Russian IPv4 ranges used to bypass the tunnel. Auto-refreshes weekly via cron.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Last update')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('strong', { 'id': 'awg-ru-when' }, stamp ? fmtAge(stamp.ts) : _('never updated')),
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
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'awg-ru-btn',
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleRuUpdate')
							}, _('Update now'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('DPI desync (zapret)')),
				E('div', { 'class': 'cbi-map-descr' },
					_('TCP/UDP packet desync for WAN-direct traffic. Does not affect AmneziaWG-tunneled traffic. Start disabled — enable only after running blockcheck on the router.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('State')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'zapret-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:#888;margin-right:8px;vertical-align:middle;'
							}),
							E('strong', { 'id': 'zapret-state-label' }, zap ? ((zap.enabled ? _('ON') : _('OFF')) + (zap.running ? ' ' + _('(running)') : '')) : _('unknown')),
							E('span', { 'id': 'zapret-version', 'style': 'margin-left:8px;color:#666;' },
								zap && zap.version ? ('v' + zap.version) : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Mode / filter')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', { 'id': 'zapret-mode' },
								zap ? ((zap.mode || '') + (zap.filter ? (' / ' + zap.filter) : '')) : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Strategy')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('code', {
								'id': 'zapret-strategy',
								'style': 'font-size:11px;word-break:break-all;'
							}, zap && zap.strategy ? zap.strategy : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'zapret-toggle-btn',
								'class': 'btn ' + (zap && zap.enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
								'disabled': (zap && zap.installed) ? null : '',
								'click': ui.createHandlerFn(this, 'handleZapretToggle')
							}, zap && zap.installed ? (zap.enabled ? _('Turn OFF') : _('Turn ON')) : _('N/A'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Blockcheck (zapret strategy tuner)')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Runs /opt/zapret/blockcheck.sh against a test domain to find a DPI desync strategy that works on this ISP. Takes 5-30 minutes. For best results turn zapret OFF before starting. The run continues in the background if you close this page.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Test domain')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'bc-domain',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:220px;margin-right:8px;',
								'value': (bc && bc.domain) || 'youtube.com',
								'placeholder': 'youtube.com',
								'disabled': (bc && bc.status === 'running') ? '' : null
							}),
							E('button', {
								'id': 'bc-run-btn',
								'class': 'btn cbi-button-action',
								'style': 'margin-right:8px;',
								'disabled': (bc && bc.status === 'running') ? '' : null,
								'click': ui.createHandlerFn(this, 'handleBlockcheckRun')
							}, (bc && bc.status === 'running') ? _('Running...') : _('Run')),
							E('button', {
								'id': 'bc-cancel-btn',
								'class': 'btn cbi-button-negative',
								'style': (bc && bc.status === 'running') ? '' : 'display:none;',
								'click': ui.createHandlerFn(this, 'handleBlockcheckCancel')
							}, _('Cancel'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('State')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('strong', { 'id': 'bc-state' },
								bc && bc.status ? (bc.status + (bc.domain ? ' [' + bc.domain + ']' : '')) : _('never run')),
							E('span', { 'id': 'bc-elapsed', 'style': 'margin-left:12px;color:#666;' }, '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Log')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('pre', {
								'id': 'bc-log',
								'style': 'background:#1e1e1e;color:#d4d4d4;padding:8px;margin:0;max-height:320px;overflow:auto;font-size:11px;white-space:pre;'
							}, bcLog || _('(no log yet)'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Live status')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('pre', {
						'id': 'awg-status-raw',
						'style': 'background:#f5f5f5;padding:8px;margin:0;max-height:240px;overflow:auto;font-size:12px;'
					}, initial.raw)
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
});
