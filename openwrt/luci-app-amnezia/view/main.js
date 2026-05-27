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
		return Promise.all([p1, p2]);
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/awg-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/awg/ru-update.json'), '')
		]);
	},

	render: function(data) {
		var initial = parseStatus((data && data[0] && data[0].stdout) || '');
		var stamp = parseRuStamp(data && data[1]);

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
