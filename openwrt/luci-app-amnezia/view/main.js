'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require amnezia.util';
'require amnezia.section.failover';
'require amnezia.section.routing';
'require amnezia.section.zapret';
'require amnezia.section.dns';
'require amnezia.section.autolearn';

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

return view.extend(Object.assign({}, failover.handlers, routing.handlers, zapret.handlers, dns.handlers, autolearn.handlers, {

	handleRefresh: function(ev) {
		var btn = document.getElementById('manual-refresh-btn');
		if (btn) { btn.disabled = true; }
		return this.refresh().then(function() {
			if (btn) btn.disabled = false;
		}, function() {
			if (btn) btn.disabled = false;
		});
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
			L.resolveDefault(fs.read('/etc/amnezia/force-update.json'), '')
		]);
	},

	render: function(data) {
		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('AmneziaWG')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Multi-tunnel AmneziaWG failover stack. RU traffic goes direct; foreign traffic routes through active tunnel(s). Status refreshes every 5 seconds.')),

			E('div', { 'class': 'amnezia-accordion' }, [
				failover.render(this, data),
				routing.render(this, data),
				zapret.render(this, data),
				dns.render(this, data),
				autolearn.render(this, data)
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
			dns.refresh(self),
			autolearn.refresh(self)
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
}));
