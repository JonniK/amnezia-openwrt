'use strict';
'require baseclass';
'require fs';
'require ui';

// 'custom' omitted: backend supports dot_resolver/doh_resolver/doh_bootstrap via direct UCI,
// but there are no UI inputs for those — selecting custom guarantees a failed set-provider call.
var DNS_PROVIDERS = ['quad9','adguard','dns0','mullvad','google'];

// ── dnsRowMarkup ──────────────────────────────────────────────────────────────
// Builds the DoT control row. Used by render() (synchronous first paint from load()
// data) AND renderDnsRow() (poll repaint). `view` is threaded so the controls wire to
// named view handlers. A clear labeled Enable/Disable button (not a bare checkbox) +
// provider dropdown + status + a Test button.
function dnsRowMarkup(view, st) {
	var enabled = !!st.enabled;
	function hf(name, arg) {
		return view ? ui.createHandlerFn(view, name, arg) : function(){ return Promise.resolve(); };
	}

	// Enable/Disable button. The desired target state is passed as the extra arg FIRST
	// (LuCI's createHandlerFn appends the event LAST → handler is fn(targetState, ev)).
	var toggleBtn = E('button', {
		'class': 'btn ' + (enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
		'click': hf('handleDotSetEnabled', enabled ? '0' : '1')
	}, enabled ? _('Disable DoT') : _('Enable DoT'));

	var sel = E('select', {
		'class': 'cbi-input-select', 'style': 'margin:0 6px;',
		'change': view ? ui.createHandlerFn(view, 'handleDotProvider') : function(){ return Promise.resolve(); }
	}, DNS_PROVIDERS.map(function(p) {
		return E('option', Object.assign({ 'value': p }, p === st.provider ? { 'selected':'selected' } : {}),
			p === 'google' ? 'google (large US provider)' : p);
	}));

	var testBtn = E('button', {
		'id': 'amz-dns-test-btn', 'class': 'btn cbi-button-action', 'style': 'margin-left:6px;',
		'click': view ? ui.createHandlerFn(view, 'handleDotTest') : function(){ return Promise.resolve(); }
	}, _('Test'));

	var statusTxt = enabled
		? (_('on · tier: ') + (st.active_tier || '—') + ' · ' + (st.healthy ? _('answering ✓') : _('NOT answering ✗')))
		: _('off (plaintext provider DNS)');

	var ruBypassLabel = enabled ? E('label', {
		'style': 'margin-left:8px;font-size:12px;cursor:pointer;',
		'title': _('Resolve .ru/.su/.рф and RU CDNs via Yandex DNS directly — fixes CDN locality for RU sites')
	}, [
		E('input', {
			'type': 'checkbox',
			'style': 'margin-right:4px;',
			'checked': st.ru_bypass ? 'checked' : null,
			'change': view ? ui.createHandlerFn(view, 'handleRuBypass') : function(){ return Promise.resolve(); }
		}),
		_('RU DNS bypass')
	]) : null;

	var children = [
		E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:4px;' }, [
			E('strong', { 'style': 'margin-right:6px;' }, _('Encrypted DNS (DoT)')),
			toggleBtn,
			E('span', { 'style': 'margin-left:6px;' }, _('Provider:')), sel,
			testBtn,
			E('span', { 'style': 'margin-left:8px;color:#666;font-size:12px;' }, statusTxt),
			ruBypassLabel
		].filter(function(x){ return x != null; }))
	];
	if (st.active_tier === 'plaintext')
		children.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:6px;' },
			_('Encrypted DNS unavailable — currently on plaintext fallback')));
	return E('div', {}, children);
}

function renderDnsRow(view, st) {
	var box = document.getElementById('amz-dns-row');
	// Skip repaint while the user is interacting with the DoT controls.
	if (box && box.contains(document.activeElement)) return;
	if (box) { box.innerHTML = ''; box.appendChild(dnsRowMarkup(view, st)); }
}

function refreshDnsStatus(view) {
	return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
		var st = {}; try { st = JSON.parse(res.stdout || '{}'); } catch (e) {}
		renderDnsRow(view, st);
		return st;
	});
}

return baseclass.extend({
	handlers: {
		// Enable/disable DoT. targetState '1'=enable, '0'=disable. Extra arg FIRST per
		// LuCI's createHandlerFn convention (event appended last → fn(targetState, ev)).
		handleDotSetEnabled: function(targetState, ev) {
			var self = this;
			return fs.exec('/usr/bin/amnezia-dns-ctl', [ targetState === '1' ? 'enable' : 'disable' ]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshDnsStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('DoT change failed: ') + err), 'danger');
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
				ui.addNotification(null, E('p', {}, _('Provider change failed: ') + err), 'danger');
			});
		},

		handleRuBypass: function(ev) {
			var self = this;
			var on = ev && ev.target && ev.target.checked ? 'on' : 'off';
			return fs.exec('/usr/bin/amnezia-dns-ctl', ['ru-bypass', on]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshDnsStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('RU DNS bypass change failed: ') + err), 'danger');
			});
		},

		// Probe the resolver via `status` (which verifies the encrypted listeners) and report
		// a clear verdict in the persistent result line (sibling of #amz-dns-row, poll-safe).
		handleDotTest: function(ev) {
			var self = this;
			var out = document.getElementById('amz-dns-test-result');
			var btn = document.getElementById('amz-dns-test-btn');
			if (out) { out.style.color = '#666'; out.textContent = _('Testing…'); }
			if (btn) btn.disabled = true;
			return fs.exec('/usr/bin/amnezia-dns-ctl', [ 'status' ]).then(function(res) {
				if (btn) btn.disabled = false;
				var st = {}; try { st = JSON.parse(res.stdout || '{}'); } catch (e) {}
				var ok = !!st.enabled && !!st.encrypted && !!st.healthy;
				var msg, color;
				if (!st.enabled) { msg = _('DoT is OFF — using plaintext provider DNS.'); color = '#666'; }
				else if (ok) { msg = _('✓ Encrypted DNS answering — tier ') + (st.active_tier || '?') + ', provider ' + (st.provider || '?') + '.'; color = '#3c763d'; }
				else { msg = _('✗ DoT enabled but NOT answering (tier ') + (st.active_tier || '?') + ', healthy=' + st.healthy + ') — check stubby/https-dns-proxy.'; color = '#a94442'; }
				if (out) { out.style.color = color; out.textContent = msg; }
				return L.resolveDefault(refreshDnsStatus(self), null);
			}).catch(function(err) {
				if (btn) btn.disabled = false;
				if (out) { out.style.color = '#a94442'; out.textContent = _('Test failed: ') + err; }
			});
		}
	},

	render: function(view, data) {
		// data[10] is the DoT status exec result (appended by main.load()).
		// Parse synchronously so the controls are populated on first paint.
		var dotSt = {};
		try { var raw10 = data && data[10] && data[10].stdout; if (raw10) dotSt = JSON.parse(raw10); } catch (e) {}

		return E('details', { 'class': 'amnezia-panel', 'open': '' }, [
			E('summary', {}, _('Encrypted DNS')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Encrypted DNS (DoT)')),
				E('div', { 'id': 'amz-dns-row' }, [ dnsRowMarkup(view, dotSt) ]),
				// Persistent test-result line (sibling of the row, so the 5s poll repaint
				// of #amz-dns-row does not wipe it).
				E('div', { 'id': 'amz-dns-test-result', 'style': 'margin-top:6px;font-size:12px;color:#666;' }, '')
			])
		]);
	},

	refresh: function(view) {
		return L.resolveDefault(refreshDnsStatus(view), null);
	}
});
