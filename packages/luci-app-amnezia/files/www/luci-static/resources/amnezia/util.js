'use strict';
'require baseclass';
'require ui';

return baseclass.extend({
	// Promise-returning confirm modal. confirm() is synchronous and would freeze
	// the 5s poll loop until the user clicks; this drops the user back into the
	// event loop while waiting. The Promise is guaranteed to settle even if the
	// modal is dismissed via Escape/backdrop -- otherwise ui.createHandlerFn
	// would keep the triggering button disabled forever.
	uiConfirm: function(message) {
		return new Promise(function(resolve) {
			var done = false;
			var finish = function(v) {
				if (done) return;
				done = true;
				document.removeEventListener('keydown', onKey);
				clearTimeout(safetyTimer);
				try { ui.hideModal(); } catch (e) { /* already hidden */ }
				resolve(v);
			};
			var onKey = function(e) {
				if (e.key === 'Escape' || e.keyCode === 27) finish(false);
			};
			// Last-resort fallback: if the modal vanishes via a path we don't
			// observe (e.g. user navigates and re-renders), give up after 60s.
			var safetyTimer = setTimeout(function() { finish(false); }, 60000);
			document.addEventListener('keydown', onKey);

			ui.showModal(_('Confirm'), [
				E('p', { 'style': 'white-space:pre-wrap;' }, message),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { finish(false); } }, _('Cancel')),
					' ',
					E('button', { 'class': 'btn cbi-button-positive', 'click': function() { finish(true); } }, _('Confirm'))
				])
			]);
		});
	},

	// Same vocabulary as the inline switch in handleProbe -- kept as a function so
	// the multi-domain verify table doesn't drift from the single-probe colouring.
	verdictColor: function(v) {
		switch (v) {
			case 'direct_ok':           return '#3c763d';
			case 'direct_geoblocked':   return '#a94442';
			case 'direct_dpi_blocked':  return '#f0ad4e';
			case 'direct_blocked':      return '#a94442';
			case 'direct_unreachable':  return '#888';
			case 'error':               return '#a94442';
			default:                    return '#666';
		}
	},

	// Status colour for the covert-creator panel. A NEW helper, deliberately
	// NOT a new arm on verdictColor (whose only two callers are in zapret.js
	// and whose arm set must not move -- "adding a caller to a shared
	// classifier makes a dead default arm live").
	covertStateColor: function(state) {
		switch (state) {
			case 'connected':   return '#3c763d';
			case 'starting':    return '#f0ad4e';
			case 'idle':        return '#666';
			case 'auth-failed': return '#a94442';
			case 'crashed':     return '#a94442';
			case 'not-started': return '#888';
			default:            return '#666'; // unknown
		}
	},

	fmtDur: function(sec) {
		if (!sec || sec < 0) return '0s';
		var m = Math.floor(sec / 60);
		var s = sec % 60;
		if (m >= 60) {
			var h = Math.floor(m / 60); m = m % 60;
			return h + 'h ' + m + 'm';
		}
		if (m > 0) return m + 'm ' + s + 's';
		return s + 's';
	},

	fmtAge: function(ts) {
		if (!ts) return 'never';
		var now = Math.floor(Date.now() / 1000);
		var age = now - ts;
		if (age < 60) return age + 's ago';
		if (age < 3600) return Math.floor(age / 60) + 'm ago';
		if (age < 86400) return Math.floor(age / 3600) + 'h ago';
		return Math.floor(age / 86400) + 'd ago';
	},
});
