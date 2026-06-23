'use strict';
'require baseclass';
'require fs';
'require ui';

// ── Encrypted-DNS (DoT) UI helpers ───────────────────────────────────────────
// 'custom' omitted: backend supports dot_resolver/doh_resolver/doh_bootstrap via direct UCI,
// but there are no UI inputs for those fields — selecting custom guarantees a failed set-provider
// call with no recovery path. A dedicated custom-input UI is a deferred follow-up (M7).
var DNS_PROVIDERS = ['quad9','adguard','dns0','mullvad','google'];

function dnsExec(args) {
	return fs.exec('/usr/bin/amnezia-dns-ctl', args).then(function(res) {
		if (res.code !== 0)
			ui.addNotification(null, E('p', {}, _('DNS change failed: ') + (res.stderr || res.stdout || '')), 'danger');
		return refreshDnsStatus();
	});
}
function setDot(on)            { return dnsExec([ on ? 'enable' : 'disable' ]); }
function setDnsProvider(name)  { return dnsExec([ 'set-provider', name ]); }

function renderDnsRow(st) {
	// M8: skip repaint while user is interacting with DoT controls (mirrors routing-mode guard).
	var box = document.getElementById('amz-dns-row');
	if (box && box.contains(document.activeElement)) return;
	var sel = E('select', { 'class': 'cbi-input-select', 'change': function(ev){ setDnsProvider(ev.target.value); } },
		DNS_PROVIDERS.map(function(p){
			return E('option', Object.assign({ 'value': p }, p === st.provider ? { 'selected': 'selected' } : {}),
				p === 'google' ? 'google (large US provider)' : p);
		}));
	var toggle = E('input', { 'type': 'checkbox', 'click': function(ev){ setDot(ev.target.checked); } });
	if (st.enabled) toggle.setAttribute('checked', 'checked');
	var warn = (st.active_tier === 'plaintext')
		? E('div', { 'class': 'alert-message warning' }, _('Encrypted DNS unavailable — on plaintext fallback'))
		: E('span', { 'class': 'label' }, _('tier: ') + (st.active_tier || '—'));
	if (box) { box.innerHTML = ''; box.appendChild(E('div', {}, [ E('strong', {}, _('Encrypted DNS (DoT) ')), toggle, ' ', sel, ' ', warn ])); }
}
function refreshDnsStatus() {
	return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
		var st = {}; try { st = JSON.parse(res.stdout || '{}'); } catch (e) {}
		renderDnsRow(st);
	});
}

return baseclass.extend({
	render: function(view, data) {
		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Encrypted DNS')),
			// ── Encrypted DNS (DoT) section ───────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Encrypted DNS (DoT)')),
				E('div', { 'id': 'amz-dns-row' })
			])
		]);
	},

	refresh: function(view) {
		return refreshDnsStatus();
	}
});
