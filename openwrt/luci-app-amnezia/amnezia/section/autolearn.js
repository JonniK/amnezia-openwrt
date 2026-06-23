'use strict';
'require baseclass';
'require fs';
'require ui';
'require amnezia.util as util';

// Guards for autolearn operations.
var autolearnToggleInFlight = false;
var autolearnVetoInFlight = false;
var autolearnPromoteInFlight = false;
var autolearnPurgeInFlight = false;

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

return baseclass.extend({
	handlers: {
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
		}
	},

	render: function(view, data) {
		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Auto-learning')),
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
								'click': ui.createHandlerFn(view, 'handleAutolearnToggle')
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
								'click': ui.createHandlerFn(view, 'handleAutolearnPurge')
							}, _('Purge all'))
						])
					])
				])
			])
		]);
	},

	refresh: function(view) {
		return Promise.all([
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
			paintAutolearnTable(entries, view);
		}, view));
	}
});
