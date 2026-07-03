'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require uci';
'require amnezia.util as util';
'require amnezia.section.failover as failover';
'require amnezia.section.routing as routing';
'require amnezia.section.zapret as zapret';
'require amnezia.section.dns as dns';

// Module-level handle for the poll callback. LuCI has no teardown hook for
// views, so the poller self-unregisters when its DOM anchor disappears
// (i.e. the user navigated to another page). On return, render() registers
// a fresh poller. Steady state during navigation: 0 active pollers.
var pollFn = null;
// True once refresh() has seen the view's DOM anchor at least once. LuCI's
// poll.add() fires one synchronous step() *before* render() returns (and thus
// before LuCI inserts the rendered DOM), so the very first poll runs with the
// anchor absent. We must NOT treat that as "navigated away" -- otherwise the
// poller kills itself on initial load and refresh-only fields (the force-update
// stamp) are never painted. Only self-unregister once the anchor has appeared.
var domSeen = false;

// Build the populated master-switch strip content. `view` is the LuCI view
// instance (handler context). Used BOTH synchronously in render() (so the strip
// is painted in the returned tree — never via a microtask+getElementById, which
// races LuCI's own DOM insertion and silently no-ops) AND by paintMasterStrip()
// for the post-toggle repaint (where the element is already in the DOM).
function masterStripContent(view, masterEnabled) {
	var on = masterEnabled !== false && masterEnabled !== '0' && masterEnabled !== 0;
	return E('div', {
		'style': 'display:flex;align-items:center;background:' + (on ? '#dff0d8' : '#fcf8e3') +
			';border:1px solid ' + (on ? '#d6e9c6' : '#faebcc') + ';border-radius:4px;padding:6px 12px;margin-bottom:8px;'
	}, [
		E('strong', { 'style': 'margin-right:12px;color:' + (on ? '#3c763d' : '#8a6d3b') + ';' },
			_('Master switch: ') + (on ? _('ON') : _('OFF'))),
		E('span', { 'style': 'flex:1;color:#666;font-size:12px;' },
			on ? _('All routing active.') : _('Policy routing disabled — LAN goes direct to WAN.')),
		E('button', {
			'class': 'btn ' + (on ? 'cbi-button-negative' : 'cbi-button-positive'),
			'style': 'margin-left:12px;',
			'click': ui.createHandlerFn(view, 'handleMasterToggle', on ? '1' : '0')
		}, on ? _('Turn OFF') : _('Turn ON'))
	]);
}

// Repaint the strip after a master toggle (element is in the DOM by then).
function paintMasterStrip(view, masterEnabled) {
	var strip = document.getElementById('amz-master-strip');
	var accordion = document.getElementById('amz-accordion');
	var on = masterEnabled !== false && masterEnabled !== '0' && masterEnabled !== 0;
	if (strip) { strip.innerHTML = ''; strip.appendChild(masterStripContent(view, masterEnabled)); }
	if (accordion) {
		if (on) accordion.classList.remove('amnezia-master-off');
		else accordion.classList.add('amnezia-master-off');
	}
}

return view.extend(Object.assign({}, failover.handlers, routing.handlers, zapret.handlers, dns.handlers, {

	handleRefresh: function(ev) {
		var btn = document.getElementById('manual-refresh-btn');
		if (btn) { btn.disabled = true; }
		return this.refresh().then(function() {
			if (btn) btn.disabled = false;
		}, function() {
			if (btn) btn.disabled = false;
		});
	},

	// ── Master switch handler ─────────────────────────────────────────────────
	// currentState: '1' = currently ON (so toggle = turn OFF), '0' = currently OFF.
	handleMasterToggle: function(currentState, ev) {
		var turningOff = (currentState === '1' || currentState === 1);
		var msg = turningOff
			? _('Turn OFF the master switch?\n\nThis disables all policy routing — LAN traffic goes direct to WAN.\nDoT (if enabled) reverts to plaintext.\nSettings are saved and restored when you turn it back ON.\nThis persists across reboot.')
			: _('Turn ON the master switch?\n\nRestores all saved routing and DoT settings.');
		var self = this;
		return util.uiConfirm(msg).then(L.bind(function(ok) {
			if (!ok) return Promise.resolve();
			var verb = turningOff ? 'off' : 'on';
			return fs.exec('/usr/bin/amnezia-failover-ctl', ['master', verb]).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				// Re-read master state fresh (uci.unload clears the cache) and repaint the strip.
				uci.unload('amnezia');
				return uci.load('amnezia').then(function() {
					return uci.get('amnezia', 'config', 'master_enabled');
				}).then(function(v) {
					var newState = (v != null ? v : '1').trim();
					paintMasterStrip(self, newState !== '0');
				}).then(function() {
					return self.refresh();
				});
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Action failed: ') + err), 'danger');
			});
		}, this));
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read('/etc/amnezia/ru-update.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/amnezia/blockcheck.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-blockcheck', ['log']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['state']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['parse']), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/amnezia/seed-must-tunnel.list'), ''),
			L.resolveDefault(fs.read('/var/run/amnezia-failover.json'), ''),
			L.resolveDefault(fs.read('/etc/amnezia/force-tunnel.list'), ''),
			// force-update.json is read at load so the stamp paints on the very
			// first render (not only on the first poll tick). refresh()'s routing.refresh
			// keeps it live afterwards.
			L.resolveDefault(fs.read('/etc/amnezia/force-update.json'), ''),
			// index 10: DoT status — parsed synchronously in dns.render() for first paint.
			L.resolveDefault(fs.exec('/usr/bin/amnezia-dns-ctl', ['status']), { stdout: '' }),
			// index 11: master_enabled (amnezia.config.master_enabled) via uci module — default '1' if absent/error.
			uci.load('amnezia').then(function() { return uci.get('amnezia', 'config', 'master_enabled'); },
				function() { return '1'; }).then(function(v) { return v != null ? v : '1'; }),
			// index 12: tunnel apps list for first-paint (routing section).
			L.resolveDefault(fs.exec('/usr/bin/amnezia-app-ctl', ['list']), { stdout: '[]' }),
			// index 13: autotunnel worker status for first-paint (routing section).
			L.resolveDefault(fs.exec('/usr/bin/amnezia-autotunnel', ['status']), { stdout: '' })
		]);
	},

	render: function(data) {
		// Parse master flag from index 11 (plain string from uci module); default to enabled.
		var masterRaw = (data && data[11] != null) ? String(data[11]) : '1';
		var masterEnabled = masterRaw.trim() !== '0';

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('AmneziaWG')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Multi-tunnel AmneziaWG failover stack. RU traffic goes direct; foreign traffic routes through active tunnel(s). Status refreshes every 5 seconds.')),

			E('style', {}, [
				'.amnezia-accordion details.amnezia-panel{border:1px solid var(--border-color-medium,#ccc);border-radius:4px;margin:6px 0;padding:4px 8px;}' +
				'.amnezia-accordion summary{cursor:pointer;font-weight:bold;padding:6px 0;list-style:none;}' +
				'.amnezia-accordion summary::-webkit-details-marker{display:none;}' +
				'.amnezia-accordion summary::before{content:"\\25B8 ";}' +
				'.amnezia-accordion details[open]>summary::before{content:"\\25BE ";}' +
				'details.amnezia-action{margin:4px 0 4px 16px;padding:2px 6px;}' +
				'details.amnezia-action summary{font-weight:normal;}' +
				'.amnezia-master-off{opacity:0.55;pointer-events:none;}'
			]),
			// Sticky notifications: stay visible at the top of the viewport when the
			// user has scrolled down. Uses position:sticky (not fixed) so multiple
			// notifications stack naturally in flow and degrade gracefully.
			E('style', { 'id': 'amz-notify-style' }, [
				'#maincontent .alert-message, .alert-message { position: sticky; top: 8px; z-index: 9999; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }'
			]),

			// Master switch strip (above accordion, always interactive).
			// Built populated synchronously so it paints on first render.
			E('div', { 'id': 'amz-master-strip' }, [ masterStripContent(this, masterEnabled) ]),

			E('div', { 'class': 'amnezia-accordion' + (masterEnabled ? '' : ' amnezia-master-off'), 'id': 'amz-accordion' }, [
				failover.render(this, data),
				routing.render(this, data),
				zapret.render(this, data),
				dns.render(this, data)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'margin:0;' }, _('Refresh')),
					E('button', {
						'id': 'manual-refresh-btn',
						'class': 'btn cbi-button-action',
						'style': 'margin-left:12px;',
						'title': _('Force an immediate poll instead of waiting for the 5s tick'),
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, _('Refresh status'))
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

	refresh: function() {
		// Anchor absent: either the rendered DOM is not inserted yet (first
		// synchronous poll step fired by poll.add() before render() returns) or
		// the user navigated away. Self-unregister only in the latter case --
		// i.e. once the anchor has been seen at least once -- so the poller does
		// not kill itself on initial load (which would leave refresh-only fields
		// such as the force-update stamp stuck on "never updated").
		if (!document.getElementById('failover-tunnel-table')) {
			if (domSeen && pollFn) { poll.remove(pollFn); pollFn = null; }
			return Promise.resolve();
		}
		domSeen = true;
		var self = this;
		return Promise.all([
			failover.refresh(self),
			routing.refresh(self),
			zapret.refresh(self),
			dns.refresh(self)
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
}));
