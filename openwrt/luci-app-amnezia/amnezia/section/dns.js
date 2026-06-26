'use strict';
'require baseclass';
'require fs';
'require ui';

// ── Encrypted-DNS (DoT) UI helpers ───────────────────────────────────────────
// 'custom' omitted: backend supports dot_resolver/doh_resolver/doh_bootstrap via direct UCI,
// but there are no UI inputs for those fields — selecting custom guarantees a failed set-provider
// call with no recovery path. A dedicated custom-input UI is a deferred follow-up (M7).
var DNS_PROVIDERS = ['quad9','adguard','dns0','mullvad','google'];

// ── dnsRowMarkup ──────────────────────────────────────────────────────────────
// Shared markup builder used by BOTH render() (synchronous first-paint from
// load() data) and renderDnsRow() (poll-path repaint). Threading 'view' so
// handlers wire to named view methods (handleDotToggle / handleDotProvider).
function dnsRowMarkup(view, st) {
	var sel = E('select', {
		'class': 'cbi-input-select',
		'change': view
			? ui.createHandlerFn(view, 'handleDotProvider')
			: function(ev) { return Promise.resolve(); }
	}, DNS_PROVIDERS.map(function(p) {
		return E('option', Object.assign({ 'value': p }, p === st.provider ? { 'selected': 'selected' } : {}),
			p === 'google' ? 'google (large US provider)' : p);
	}));
	var toggle = E('input', {
		'type': 'checkbox',
		'click': view
			? ui.createHandlerFn(view, 'handleDotToggle')
			: function(ev) { return Promise.resolve(); }
	});
	if (st.enabled) toggle.setAttribute('checked', 'checked');
	var warn = (st.active_tier === 'plaintext')
		? E('div', { 'class': 'alert-message warning' }, _('Encrypted DNS unavailable — on plaintext fallback'))
		: E('span', { 'class': 'label' }, _('tier: ') + (st.active_tier || '—'));
	return E('div', {}, [ E('strong', {}, _('Encrypted DNS (DoT) ')), toggle, ' ', sel, ' ', warn ]);
}

function renderDnsRow(view, st) {
	// M8: skip repaint while user is interacting with DoT controls (mirrors routing-mode guard).
	var box = document.getElementById('amz-dns-row');
	if (box && box.contains(document.activeElement)) return;
	if (box) { box.innerHTML = ''; box.appendChild(dnsRowMarkup(view, st)); }
}

function refreshDnsStatus(view) {
	return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
		var st = {}; try { st = JSON.parse(res.stdout || '{}'); } catch (e) {}
		renderDnsRow(view, st);
	});
}

return baseclass.extend({
	handlers: {
		handleDotToggle: function(ev) {
			var checked = ev && ev.target ? ev.target.checked : false;
			var self = this;
			return fs.exec('/usr/bin/amnezia-dns-ctl', [ checked ? 'enable' : 'disable' ]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshDnsStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Action failed: ') + err), 'danger');
			});
		},

		handleDotProvider: function(ev) {
			var name = ev && ev.target ? ev.target.value : '';
			if (!name) return Promise.resolve();
			var self = this;
			return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'set-provider', name ]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshDnsStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Action failed: ') + err), 'danger');
			});
		}
	},

	render: function(view, data) {
		// data[10] is the DoT status exec result (appended by main.load()).
		// Parse it synchronously so the toggle is already populated on first paint.
		var dotSt = {};
		try {
			var raw10 = data && data[10] && data[10].stdout;
			if (raw10) dotSt = JSON.parse(raw10);
		} catch (e) {}

		var initialRow = dnsRowMarkup(view, dotSt);

		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Encrypted DNS')),
			// ── Encrypted DNS (DoT) section ───────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Encrypted DNS (DoT)')),
				E('div', { 'id': 'amz-dns-row' }, [ initialRow ])
			])
		]);
	},

	refresh: function(view) {
		return L.resolveDefault(refreshDnsStatus(view), null);
	}
});
