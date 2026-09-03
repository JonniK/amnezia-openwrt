'use strict';
'require baseclass';
'require fs';
'require ui';
'require amnezia.util as util';

// Covert-transport (VK headless creator) control panel. Rendered OUTSIDE
// #amz-accordion by main.js — master_enabled does not gate this feature at
// all (it never touches the tunnel/DNS plane), and the accordion's
// .amnezia-master-off { pointer-events:none } must not make this toggle
// unclickable when master is OFF.

var COVERT_CTL = '/usr/bin/amnezia-covert-ctl';
var COOKIE_PATH = '/etc/amnezia/covert/vk-cookies.json';

function parseCovertStatus(raw) {
	if (!raw) return {};
	try { return JSON.parse(raw); } catch (e) { return {}; }
}

// ── covertRowMarkup ──────────────────────────────────────────────────────────
// Builds the toggle + status + join-link row. Used by render() (synchronous
// first paint from load() data) AND renderCovertRow() (poll repaint).
function covertRowMarkup(view, st) {
	var enabled = !!st.enabled;
	var state = st.state || 'unknown';
	var color = util.covertStateColor(state);

	function hf(name, arg) {
		return view ? ui.createHandlerFn(view, name, arg) : function(){ return Promise.resolve(); };
	}

	// Enable/Disable button. Desired target state is passed as the extra arg
	// FIRST (createHandlerFn appends the event LAST -> handler is fn(targetState, ev)).
	var toggleBtn = E('button', {
		'class': 'btn ' + (enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
		'click': hf('handleCovertToggle', enabled ? '0' : '1')
	}, enabled ? _('Disable') : _('Enable'));

	var statusTxt = E('span', { 'style': 'margin-left:8px;color:' + color + ';font-weight:bold;' },
		enabled ? (_('state: ') + state) : _('off'));

	var children = [
		E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:4px;' }, [
			toggleBtn, statusTxt
		])
	];

	// Join-link row: shown ONLY when the creator has actually joined a call.
	if (state === 'connected' && st.link) {
		var ageTxt = (st.link_age_s !== undefined && st.link_age_s !== null)
			? (_('age: ') + st.link_age_s + 's')
			: '';
		children.push(E('div', { 'id': 'amz-covert-link-row', 'style': 'margin-top:6px;display:flex;align-items:center;gap:6px;flex-wrap:wrap;' }, [
			E('span', {}, _('Join link:')),
			E('code', { 'id': 'amz-covert-link', 'style': 'word-break:break-all;' }, st.link),
			E('button', {
				'class': 'btn cbi-button-neutral',
				'style': 'font-size:11px;padding:2px 8px;',
				'click': function() {
					var el = document.getElementById('amz-covert-link');
					var text = (el && el.textContent) || st.link;
					if (typeof navigator !== 'undefined' && navigator.clipboard && navigator.clipboard.writeText)
						navigator.clipboard.writeText(text);
					ui.addNotification(null, E('p', {}, _('Join link copied')), 'info');
				}
			}, _('Copy')),
			E('span', { 'style': 'color:#666;font-size:11px;' }, ageTxt)
		]));
	}

	return E('div', {}, children);
}

function renderCovertRow(view, st) {
	var box = document.getElementById('amz-covert-row');
	// Skip repaint while the user is interacting with the covert controls.
	if (box && box.contains(document.activeElement)) return;
	if (box) { box.innerHTML = ''; box.appendChild(covertRowMarkup(view, st)); }
}

function refreshCovertStatus(view) {
	return fs.exec(COVERT_CTL, [ 'status' ]).then(function(res) {
		var st = parseCovertStatus(res && res.stdout);
		renderCovertRow(view, st);
		return st;
	});
}

return baseclass.extend({
	handlers: {
		// Enable/disable the covert creator. targetState '1'=enable, '0'=disable.
		// Extra arg FIRST per LuCI's createHandlerFn convention (event appended
		// last -> fn(targetState, ev)).
		handleCovertToggle: function(targetState, ev) {
			var self = this;
			return fs.exec(COVERT_CTL, [ targetState === '1' ? 'enable' : 'disable' ]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshCovertStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Covert toggle failed: ') + err), 'danger');
			});
		},

		// Save the pasted cookie JSON via fs.write (never as an argv element --
		// the cookie is a real personal-account credential), then re-apply so the
		// CLI's structural validation runs against what was just saved. The
		// textarea is write-only: cleared on success, never pre-filled.
		handleCovertSaveCookies: function(ev) {
			var self = this;
			var ta = document.getElementById('amz-covert-cookies-ta');
			var val = ta ? ta.value : '';
			return fs.write(COOKIE_PATH, val, 0o640).then(function() {
				if (ta) ta.value = '';
				return fs.exec(COVERT_CTL, [ 'apply' ]).then(function(res) {
					ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
						(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
						res.code === 0 ? 'info' : 'warning');
					return L.resolveDefault(refreshCovertStatus(self), null);
				});
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Cookie save failed: ') + err), 'danger');
			});
		},

		// Re-apply without rewriting the cookie (e.g. after a preflight failure
		// was fixed some other way, or to retry after a transient error).
		handleCovertApply: function(ev) {
			var self = this;
			return fs.exec(COVERT_CTL, [ 'apply' ]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				return L.resolveDefault(refreshCovertStatus(self), null);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Apply failed: ') + err), 'danger');
			});
		}
	},

	render: function(view, data) {
		// data[14] is the covert status exec result (appended by main.load()).
		// Parse synchronously so the toggle/status/link are populated on first paint.
		var st = {};
		try { var raw14 = data && data[14] && data[14].stdout; if (raw14) st = JSON.parse(raw14); } catch (e) {}

		return E('div', {
			'id': 'amz-covert-block',
			'class': 'cbi-section',
			'style': 'border:1px solid var(--border-color-medium,#ccc);border-radius:4px;margin:6px 0;padding:8px 10px;'
		}, [
			E('h3', { 'style': 'margin:0 0 6px 0;' }, _('Covert transport (VK creator)')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Opt-in, default-OFF. Creates a fresh VK call on start; paste the join link into the phone/Mac joiner app by hand. Does not participate in tunnel/DNS routing.')),
			E('div', { 'id': 'amz-covert-row' }, [ covertRowMarkup(view, st) ]),

			E('details', { 'class': 'amnezia-action' }, [
				E('summary', {}, _('Cookies & manual apply')),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-node' }, [
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, _('VK cookies (JSON)')),
							E('div', { 'class': 'cbi-value-field' }, [
								E('textarea', {
									'id': 'amz-covert-cookies-ta',
									'class': 'cbi-input-text',
									'style': 'width:100%;height:100px;font-family:monospace;font-size:11px;box-sizing:border-box;',
									'placeholder': _('Paste VK cookie JSON here -- write-only, never pre-filled or echoed back')
								})
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('div', { 'class': 'cbi-value-field' }, [
								E('button', {
									'id': 'amz-covert-save-btn',
									'class': 'btn cbi-button-positive',
									'click': ui.createHandlerFn(view, 'handleCovertSaveCookies')
								}, _('Save cookies')),
								' ',
								E('button', {
									'id': 'amz-covert-apply-btn',
									'class': 'btn cbi-button-action',
									'click': ui.createHandlerFn(view, 'handleCovertApply')
								}, _('Re-apply'))
							])
						])
					])
				])
			])
		]);
	},

	refresh: function(view) {
		return L.resolveDefault(refreshCovertStatus(view), null);
	}
});
