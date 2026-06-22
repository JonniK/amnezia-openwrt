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

// In-flight flag for apply/revert. While true, the 5s poll's paintApply()
// must not touch the apply/revert buttons -- otherwise a poll landing
// mid-uci-commit re-enables the button and a second click stacks restarts.
var applyInFlight = false;

// Block re-entrant probes: the seed-list rows and the standalone Probe
// button both call handleProbe; without this, clicking two rows quickly
// (or row + button) would race two execs both writing to #probe-result.
var probeInFlight = false;

// Same guard for the multi-domain Verify button. Verify can take 30-60s
// (sequential N probes), so a double-click without the guard would queue a
// second run that overwrites the in-progress result mid-render.
var verifyInFlight = false;

// Guards for the new tunnel-management + allowlist operations.
var addTunnelInFlight = false;
var removeTunnelInFlight = false;
var routingModeInFlight = false;
var forceUpdateInFlight = false;
var saveManualInFlight = false;

// Guards for autolearn operations.
var autolearnToggleInFlight = false;
var autolearnVetoInFlight = false;
var autolearnPromoteInFlight = false;
var autolearnPurgeInFlight = false;

// Signature of the most recently rendered candidate list. paintApply() skips
// rebuilding the <select> when the signature is unchanged -- otherwise an
// open dropdown would be closed by the browser on every 5s poll.
var candidatesSig = '';

function candidatesSignature(cands) {
	if (!cands || !cands.length) return '';
	var parts = [];
	for (var i = 0; i < cands.length; i++) parts.push(cands[i].strategy || '');
	return parts.join('\x1e');
}

// Promise-returning confirm modal. confirm() is synchronous and would freeze
// the 5s poll loop until the user clicks; this drops the user back into the
// event loop while waiting. The Promise is guaranteed to settle even if the
// modal is dismissed via Escape/backdrop -- otherwise ui.createHandlerFn
// would keep the triggering button disabled forever.
function uiConfirm(message) {
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
}

function parseRuStamp(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseZapret(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseProbe(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseVerify(text) {
	if (!text) return null;
	try {
		var obj = JSON.parse(text);
		if (obj && obj.results && obj.results.length !== undefined) return obj;
		return null;
	} catch (e) { return null; }
}

// Same vocabulary as the inline switch in handleProbe -- kept as a function so
// the multi-domain verify table doesn't drift from the single-probe colouring.
function verdictColor(v) {
	switch (v) {
		case 'direct_ok':           return '#3c763d';
		case 'direct_geoblocked':   return '#a94442';
		case 'direct_dpi_blocked':  return '#f0ad4e';
		case 'direct_blocked':      return '#a94442';
		case 'direct_unreachable':  return '#888';
		case 'error':               return '#a94442';
		default:                    return '#666';
	}
}

// Split the seed-must-tunnel.list file (one domain per line, # comments) into
// an array of strings.
function parseSeedList(text) {
	if (!text) return [];
	var out = [];
	var lines = text.split('\n');
	for (var i = 0; i < lines.length; i++) {
		var s = lines[i].replace(/#.*$/, '').trim();
		if (s) out.push(s);
	}
	return out;
}

function parseBlockcheck(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parseApplyState(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

// zapret-apply parse emits one JSON object per line (NDJSON-ish). Returns
// an array of candidate objects; silently drops lines that don't parse.
function parseCandidates(text) {
	if (!text) return [];
	var out = [];
	var lines = text.split('\n');
	for (var i = 0; i < lines.length; i++) {
		var s = lines[i].trim();
		if (!s) continue;
		try { out.push(JSON.parse(s)); } catch (e) { /* skip */ }
	}
	return out;
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

// Build a single NFQWS_OPT string from N selected candidates. Each block gets a
// protocol filter inferred from scope so that nfqws applies the right block to
// each connection type (TLS via TCP 443, QUIC via UDP 443, plain HTTP via TCP 80).
// Blocks are joined with --new; nfqws picks the first matching block per flow.
function composeNfqwsOpt(selected) {
	// Detect whether the selected set spans multiple distinct domains. When it
	// does, we need to scope each block to its own domain via
	// --hostlist-domains, otherwise nfqws's first-match logic would let block
	// #1 swallow flows that block #2 was meant to fix (since both share the
	// same --filter-tcp=443). Inline form keeps us free of hostlist files.
	var uniqDomains = {};
	for (var i = 0; i < selected.length; i++) {
		if (selected[i].domain) uniqDomains[selected[i].domain] = true;
	}
	var perDomain = Object.keys(uniqDomains).length > 1;

	// Dedup: blockcheck typically emits the same nfqws strategy for
	// scope=tls12 AND scope=tls13 (and similar https variants), so for one
	// domain the recommended set can contain two rows that compose to the
	// IDENTICAL filter+hostlist+strategy block. Without dedup, nfqws gets a
	// `--new`-joined chain with duplicates; the second one is dead code
	// (first match wins) but it bloats NFQWS_OPT noticeably.
	var blocks = [];
	var seen = {};
	for (var j = 0; j < selected.length; j++) {
		var c = selected[j];
		var prefix;
		var s = (c.scope || '').toLowerCase();
		if (s.indexOf('http3') !== -1 || s.indexOf('quic') !== -1)        prefix = '--filter-udp=443 ';
		else if (s.indexOf('tls') !== -1 || s.indexOf('https') !== -1)    prefix = '--filter-tcp=443 ';
		else if (s.indexOf('http') !== -1)                                 prefix = '--filter-tcp=80 ';
		else                                                                prefix = '--filter-tcp=443 '; // safe default: an unfiltered block under --new would match all flows and silently shadow later blocks.
		var hostlist = (perDomain && c.domain) ? ('--hostlist-domains=' + c.domain + ' ') : '';
		var block = (prefix + hostlist + c.strategy).replace(/\s+/g, ' ').trim();
		if (seen[block]) continue;
		seen[block] = true;
		blocks.push(block);
	}
	return blocks.join(' --new ');
}

// Stable identity for a candidate row: same strategy can come from multiple
// scopes (e.g. one recipe beating both https and http3), and each row owns
// its own checked state. Key on the tuple instead of just .strategy.
function candidateKey(c) {
	return (c.strategy || '') + '|' + (c.scope || '') + '|' + (c.domain || '');
}

function paintApply(state, candidates) {
	var list = document.getElementById('apply-list');
	var currentEl = document.getElementById('apply-current');
	var applyBtn = document.getElementById('apply-btn');
	var revertBtn = document.getElementById('apply-revert-btn');
	var summary = document.getElementById('apply-summary');

	// Rebuild the checkbox list only when the candidate set actually changed,
	// preserving any boxes the user already ticked.
	if (list) {
		var newSig = candidatesSignature(candidates);
		if (newSig !== candidatesSig) {
			candidatesSig = newSig;
			var prevChecked = {};
			var existing = list.querySelectorAll('input[type=checkbox]');
			for (var k = 0; k < existing.length; k++) {
				if (existing[k].checked) {
					var row = existing[k].parentNode;
					var key = (existing[k].value || '') + '|' +
						(row.getAttribute('data-scope') || '') + '|' +
						(row.getAttribute('data-domain') || '');
					prevChecked[key] = true;
				}
			}
			list.innerHTML = '';
			if (!candidates || candidates.length === 0) {
				list.appendChild(E('div', { 'style': 'color:#888;font-style:italic;' },
					_('(no working strategies in log yet)')));
			} else {
				for (var i = 0; i < candidates.length; i++) {
					var c = candidates[i];
					var isRec = (c.recommended === true);
					var row = E('label', {
						'class': 'apply-row' + (isRec ? ' apply-row-recommended' : ''),
						'data-scope': c.scope || '',
						'data-domain': c.domain || '',
						'data-recommended': isRec ? 'true' : 'false',
						'title': isRec ? _('blockcheck\'s first working strategy in this class') : '',
						'style': 'display:flex;align-items:flex-start;gap:8px;padding:3px 4px;font-family:monospace;font-size:11px;border-bottom:1px solid #eee;cursor:pointer;word-break:break-all;' +
							(isRec ? 'background:#fffbe6;border-left:3px solid #f0ad4e;' : '')
					}, [
						(function(c, was) {
							var attrs = { 'type': 'checkbox', 'value': c.strategy, 'style': 'margin-top:3px;flex-shrink:0;' };
							if (was) attrs.checked = 'checked';
							return E('input', attrs);
						})(c, prevChecked[candidateKey(c)]),
						E('span', {}, [
							isRec ? E('span', { 'style': 'color:#f0ad4e;font-weight:bold;margin-right:4px;' }, '★') : '',
							E('span', { 'style': 'color:#666;' },
								'[ipv' + c.ipv + ' ' + c.scope + (c.domain ? ' ' + c.domain : '') + '] '),
							E('span', {}, c.strategy)
						])
					]);
					list.appendChild(row);
				}
			}
		}
	}

	if (summary) {
		var count = (candidates && candidates.length) || 0;
		summary.textContent = count
			? (count + ' ' + _('working strategy(ies) found in current log -- check the ones to combine'))
			: _('Run blockcheck on a blocked domain to populate this list');
	}

	if (currentEl) {
		currentEl.textContent = (state && state.current)
			? state.current
			: _('(NFQWS_OPT empty)');
	}

	// Never touch button enabled-state while a click is mid-flight -- the
	// handler owns those bits until its promise resolves.
	if (!applyInFlight) {
		if (applyBtn) {
			applyBtn.disabled = !(candidates && candidates.length);
		}
		var recBtn = document.getElementById('apply-select-recommended-btn');
		if (recBtn) {
			var hasRec = !!(candidates && candidates.some(function(c){ return c.recommended === true; }));
			recBtn.disabled = !hasRec;
		}
		if (revertBtn) {
			revertBtn.style.display = (state && state.has_backup) ? '' : 'none';
			revertBtn.title = (state && state.backup_ts) ? (_('Backup from ') + state.backup_ts) : '';
		}
	}
}

function paintBlockcheckLog(text) {
	var pre = document.getElementById('bc-log');
	if (!pre) return;
	if (!text) { pre.textContent = '(no log yet)'; return; }
	pre.textContent = text;
	// Autoscroll to bottom while a run is in progress; cheap heuristic.
	pre.scrollTop = pre.scrollHeight;
}

function parseFailoverState(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

// self is the view instance; pass it so toggle/remove buttons can call handlers.
// self may be null when called without toggle support (e.g. in tests).
function renderTunnelTable(state, self) {
	if (!state || !state.tunnels || !state.tunnels.length) {
		return E('div', { 'style': 'color:#888;font-style:italic;' },
			_('No tunnel state available. Start the amnezia-failover service.'));
	}
	var table = E('table', {
		'style': 'border-collapse:collapse;font-size:12px;width:100%;table-layout:fixed;'
	});
	var head = E('tr', {}, [
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:11%;' }, _('Tunnel')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:9%;' }, _('State')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:10%;' }, _('Role')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Metric')),
		E('th', { 'style': 'text-align:right;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Weight')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:14%;' }, _('Handshake')),
		E('th', { 'style': 'text-align:left;padding:4px 6px;border-bottom:2px solid #ddd;width:12%;' }, _('Exit IP')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:8%;' }, _('Toggle')),
		E('th', { 'style': 'text-align:center;padding:4px 6px;border-bottom:2px solid #ddd;width:7%;' }, _('Remove'))
	]);
	table.appendChild(head);
	for (var i = 0; i < state.tunnels.length; i++) {
		var t = state.tunnels[i];
		var upColor = t.up ? '#3c763d' : '#a94442';
		var upText = t.up ? _('UP') : _('DOWN');
		var role = t.carrying ? _('active') : (t.enabled ? _('standby') : _('disabled'));
		var roleColor = t.carrying ? '#3c763d' : (t.enabled ? '#666' : '#888');
		// Visually distinguish DOWN tunnels with a dim background.
		var rowBg = t.up ? '' : 'background:#fdf2f2;';
		var toggleBtn = self
			? E('button', {
				'id': 'awg-toggle-' + t.name,
				'class': 'btn btn-sm ' + (t.enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
				'style': 'padding:2px 8px;font-size:11px;',
				'click': ui.createHandlerFn(self, 'handleTunnelToggle', t.name)
			  }, t.enabled ? _('Disable') : _('Enable'))
			: E('span', {}, '');
		var removeBtn = self
			? E('button', {
				'id': 'awg-remove-' + t.name,
				'class': 'btn btn-sm cbi-button-negative',
				'style': 'padding:2px 8px;font-size:11px;',
				'click': ui.createHandlerFn(self, 'handleTunnelRemove', t.name, t.exit_ip || '')
			  }, _('Remove'))
			: E('span', {}, '');
		var row = E('tr', {}, [
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;font-weight:bold;' },
				t.label ? (t.name + ' (' + t.label + ')') : t.name),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;color:' + upColor + ';font-weight:bold;' },
				upText),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;color:' + roleColor + ';' },
				role),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:right;color:#555;' },
				t.metric !== undefined ? t.metric : ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:right;color:#555;' },
				t.weight !== undefined ? t.weight : ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;color:#666;font-family:monospace;font-size:11px;' },
				(function(age) {
					// age is seconds-since-handshake from the daemon (-1 = never).
					// Do NOT convert via Date.now() — the value is already an age, not an epoch.
					if (age === undefined || age === null) return _('never');
					if (age < 0) return _('never');
					if (age < 60) return age + 's ago';
					if (age < 3600) return Math.floor(age / 60) + 'm ago';
					if (age < 86400) return Math.floor(age / 3600) + 'h ago';
					return Math.floor(age / 86400) + 'd ago';
				})(t.handshake_age)),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;color:#444;font-family:monospace;font-size:11px;' },
				t.exit_ip || ''),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				toggleBtn),
			E('td', { 'style': rowBg + 'padding:4px 6px;border-bottom:1px solid #eee;text-align:center;' },
				removeBtn)
		]);
		table.appendChild(row);
	}
	return table;
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

// Update the prominent "Active tunnel" banner on each poll.
function paintFailoverSummary(state) {
	var dot = document.getElementById('failover-active-dot');
	var label = document.getElementById('failover-active-label');
	var modeEl = document.getElementById('failover-mode-label');

	if (!state) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = _('no data');
		if (modeEl) modeEl.textContent = '';
		return;
	}

	var allDown = !!state.all_down;
	if (dot) dot.style.background = allDown ? '#a94442' : '#3c763d';
	if (label) label.textContent = allDown ? _('ALL DOWN') : (state.active_pool || _('unknown'));
	if (modeEl) modeEl.textContent = 'mode: ' + (state.mode || '?');
}

// ── vpn:// decoder ──────────────────────────────────────────────────────────
// Decodes an Amnezia vpn:// share link and returns the embedded WireGuard
// .conf text (Promise<string|null>).  Returns null on any failure so the
// caller can fall back to manual paste.
//
// Schema (design §Feature 1 – vpn:// decoding):
//   vpn:// + base64url( <4-byte BE uncompressed-length> + <zlib/RFC1950> )
// Decompressed JSON: { containers: [{ containerCode: 9|"clAmneziaWg",
//   last_config: "<JSON string: {config: '<wg conf>'}>" }] }
//
// NOTE: Validated against a self-consistent round-trip fixture in
// test/js/decode-vpn.test.mjs.  Real Amnezia-app link validation is deferred
// to the VM/manual stage (Phase G).
function decodeVpnLink(text) {
	if (!text || typeof text !== 'string') return Promise.resolve(null);
	var t = text.trim();
	if (t.indexOf('vpn://') !== 0) return Promise.resolve(null);

	return Promise.resolve().then(function() {
		// 1. Strip scheme and base64url-decode to Uint8Array.
		var b64 = t.slice(6)
			.replace(/-/g, '+')
			.replace(/_/g, '/');
		// Re-add base64 padding.
		var pad = (4 - b64.length % 4) % 4;
		for (var p = 0; p < pad; p++) b64 += '=';

		var binStr = atob(b64);
		var raw = new Uint8Array(binStr.length);
		for (var i = 0; i < binStr.length; i++) raw[i] = binStr.charCodeAt(i);

		if (raw.length < 4) return null;

		// 2. Drop the 4-byte big-endian qCompress length prefix.
		var compressed = raw.slice(4);

		// 3. Inflate via DecompressionStream('deflate') = zlib/RFC1950.
		//    Pump both sides concurrently so errors surface on the reader.
		var ds = new DecompressionStream('deflate');
		var writer = ds.writable.getWriter();
		var reader = ds.readable.getReader();

		var writeP = writer.write(compressed).then(function() {
			return writer.close();
		}).catch(function() { /* errors surface via reader side */ });

		var chunks = [];
		var totalLen = 0;
		var readErr = null;

		function readAll() {
			return reader.read().then(function(chunk) {
				if (chunk.done) return;
				chunks.push(chunk.value);
				totalLen += chunk.value.length;
				return readAll();
			}).catch(function(e) { readErr = e; });
		}

		return readAll().then(function() {
			return writeP.catch(function() {});
		}).then(function() {
			if (readErr) return null;

			// 4. Assemble chunks and UTF-8 decode.
			var decompressed = new Uint8Array(totalLen);
			var off = 0;
			for (var j = 0; j < chunks.length; j++) {
				decompressed.set(chunks[j], off);
				off += chunks[j].length;
			}
			var jsonStr = new TextDecoder().decode(decompressed);

			// 5. Parse outer document and find AmneziaWG container.
			var doc;
			try { doc = JSON.parse(jsonStr); } catch (e) { return null; }

			var containers = doc && doc.containers;
			if (!Array.isArray(containers)) return null;

			var awgContainer = null;
			for (var k = 0; k < containers.length; k++) {
				var c = containers[k];
				if (c && (c.containerCode === 9 || c.containerCode === 'clAmneziaWg' ||
				          c.containerName === 'AmneziaWG')) {
					awgContainer = c;
					break;
				}
			}
			if (!awgContainer || !awgContainer.last_config) return null;

			// 6. last_config is itself a JSON string — parse it again.
			var inner;
			try {
				inner = (typeof awgContainer.last_config === 'string')
					? JSON.parse(awgContainer.last_config)
					: awgContainer.last_config;
			} catch (e) { return null; }

			var conf = inner && inner.config;
			if (typeof conf !== 'string' || !conf.trim()) return null;
			return conf.trim();
		});
	}).catch(function() { return null; });
}

// ── Force-update stamp painter ───────────────────────────────────────────────
// Mirrors paintRuStamp but reads force-update.json which has per-source entries.
function paintForceStamp(stamp) {
	var whenEl  = document.getElementById('force-when');
	var countEl = document.getElementById('force-count');
	var statusEl = document.getElementById('force-status');

	if (!stamp) {
		if (whenEl)  whenEl.textContent  = _('never updated');
		if (countEl) countEl.textContent = '';
		if (statusEl) { statusEl.textContent = ''; statusEl.style.color = ''; }
		return;
	}

	if (whenEl) whenEl.textContent = fmtAge(stamp.ts);

	// Aggregate per-source counts and detect any failures.
	var totalCount = 0;
	var anyFailed = false;
	var sources = stamp.sources || {};
	var names = Object.keys(sources);
	for (var i = 0; i < names.length; i++) {
		var s = sources[names[i]];
		if (s && s.count) totalCount += (s.count || 0);
		if (s && s.status === 'failed') anyFailed = true;
	}

	if (countEl) countEl.textContent = totalCount ? (totalCount + ' entries') : '';
	if (statusEl) {
		statusEl.textContent = anyFailed ? _('some sources failed') : _('ok');
		statusEl.style.color = anyFailed ? '#a94442' : '#3c763d';
	}
}

// ── autolearn helpers ────────────────────────────────────────────────────────

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

return view.extend({

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
		return uiConfirm(_('Purge all auto-learned entries?\n\nThis empties the auto.list and clears the candidate store. The deny.list is NOT cleared — vetoed domains remain denied.')).then(L.bind(function(ok) {
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
	},
	handleRefresh: function(ev) {
		var btn = document.getElementById('manual-refresh-btn');
		if (btn) { btn.disabled = true; }
		return this.refresh().then(function() {
			if (btn) btn.disabled = false;
		}, function() {
			if (btn) btn.disabled = false;
		});
	},

	handleTunnelToggle: function(ev, tunnelName) {
		var btnId = 'awg-toggle-' + tunnelName;
		var btn = document.getElementById(btnId);
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Working...'); }
		return fs.exec('/usr/bin/amnezia-failover-ctl', ['toggle', tunnelName]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			if (btn) delete btn.dataset.busy;
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Toggle failed: ') + err), 'danger');
			var b = document.getElementById(btnId);
			if (b) { delete b.dataset.busy; b.disabled = false; }
		});
	},

	// ── handleTunnelRemove ───────────────────────────────────────────────────
	// Remove button per tunnel row.  Guards: sticky-target, last-member.
	// Confirm shows tunnel name + exit-IP so the user knows what they're removing.
	handleTunnelRemove: function(ev, tunnelName, exitIp) {
		if (removeTunnelInFlight) {
			ui.addNotification(null, E('p', {}, _('A remove is already in progress')), 'info');
			return Promise.resolve();
		}
		var msg = _('Remove tunnel ') + tunnelName;
		if (exitIp) msg += _(' (endpoint: ') + exitIp + ')';
		msg += _('?\n\nThis stops the monitor, tears down the interface, and removes all UCI state. The monitor will restart with the remaining tunnels.');
		removeTunnelInFlight = true;
		var btnId = 'awg-remove-' + tunnelName;
		var btn = document.getElementById(btnId);
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Removing...'); }
		return uiConfirm(msg).then(L.bind(function(ok) {
			if (!ok) {
				removeTunnelInFlight = false;
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Remove'); }
				return null;
			}
			return fs.exec('/usr/bin/amnezia-tunnel-ctl', ['remove', tunnelName]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				removeTunnelInFlight = false;
				if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Remove'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Remove failed: ') + err), 'danger');
				removeTunnelInFlight = false;
				var b = document.getElementById(btnId);
				if (b) { delete b.dataset.busy; b.disabled = false; b.textContent = _('Remove'); }
			});
		}, this));
	},

	// ── handleAddTunnel ──────────────────────────────────────────────────────
	// Submits a new .conf or vpn:// link.  vpn:// is decoded client-side first;
	// on success the user sees the decoded preview and confirms before exec.
	handleAddTunnel: function(ev) {
		if (addTunnelInFlight) {
			ui.addNotification(null, E('p', {}, _('An add is already in progress')), 'info');
			return Promise.resolve();
		}
		var taEl = document.getElementById('add-tunnel-conf');
		var labelEl = document.getElementById('add-tunnel-label');
		var raw = (taEl && taEl.value || '').trim();
		if (!raw) {
			ui.addNotification(null, E('p', {}, _('Paste a .conf or vpn:// link first')), 'warning');
			return Promise.resolve();
		}
		var label = (labelEl && labelEl.value || '').trim();

		// Find the free slot.
		return fs.exec('/usr/bin/amnezia-tunnel-ctl', ['list-free']).then(L.bind(function(res) {
			if (!res || res.code === 3) {
				ui.addNotification(null, E('p', {}, _('All tunnel slots are full (max 5). Remove one first.')), 'warning');
				return null;
			}
			var slotName = ((res && res.stdout) || '').trim();
			if (!slotName) {
				ui.addNotification(null, E('p', {}, _('Could not determine free tunnel slot')), 'warning');
				return null;
			}

			// If the input looks like a vpn:// link, decode it first.
			if (raw.indexOf('vpn://') === 0) {
				return decodeVpnLink(raw).then(L.bind(function(decoded) {
					if (!decoded) {
						ui.addNotification(null, E('p', {}, _("Couldn't decode this vpn:// link — paste the .conf text directly instead")), 'warning');
						return null;
					}
					// Show the decoded preview and ask the user to confirm.
					var previewMsg = _('Decoded vpn:// for slot ') + slotName + _(':\n\n') + decoded + _('\n\nProceed?');
					addTunnelInFlight = true;
					return uiConfirm(previewMsg).then(L.bind(function(ok) {
						if (!ok) { addTunnelInFlight = false; return null; }
						return this._doAddTunnel(slotName, decoded, label);
					}, this));
				}, this));
			}

			// Plain .conf — confirm and submit.
			var confirmMsg = _('Add tunnel ') + slotName + _(' with the pasted .conf?');
			if (label) confirmMsg += _('\nLabel: ') + label;
			addTunnelInFlight = true;
			return uiConfirm(confirmMsg).then(L.bind(function(ok) {
				if (!ok) { addTunnelInFlight = false; return null; }
				return this._doAddTunnel(slotName, raw, label);
			}, this));
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Add tunnel failed: ') + err), 'danger');
			addTunnelInFlight = false;
		});
	},

	_doAddTunnel: function(slotName, confBody, label) {
		var btn = document.getElementById('add-tunnel-btn');
		if (btn) { btn.disabled = true; btn.textContent = _('Adding...'); }
		var args = ['add', slotName, confBody];
		if (label) { args.push('--label'); args.push(label); }
		return fs.exec('/usr/bin/amnezia-tunnel-ctl', args).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'danger');
			addTunnelInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Add tunnel'); }
			// Clear form on success.
			if (res.code === 0) {
				var ta = document.getElementById('add-tunnel-conf');
				var li = document.getElementById('add-tunnel-label');
				if (ta) ta.value = '';
				if (li) li.value = '';
			}
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Add tunnel exec failed: ') + err), 'danger');
			addTunnelInFlight = false;
			var b = document.getElementById('add-tunnel-btn');
			if (b) { b.disabled = false; b.textContent = _('Add tunnel'); }
		});
	},

	// ── handleRoutingMode ────────────────────────────────────────────────────
	// Routing-mode radio: tunnel-default vs direct-default.
	// Guarded by uiConfirm (changes routing for the whole LAN).
	handleRoutingMode: function(ev) {
		if (routingModeInFlight) return Promise.resolve();
		var sel = document.getElementById('routing-mode-select');
		if (!sel) return Promise.resolve();
		var newMode = sel.value;
		var msg = newMode === 'direct-default'
			? _('Switch to DIRECT-DEFAULT (allowlist) mode?\n\nOnly addresses in the force-tunnel list will use the tunnel. Everything else goes direct via WAN + zapret. Change takes effect immediately for new connections.')
			: _('Switch to TUNNEL-DEFAULT mode?\n\nAll foreign traffic routes through the tunnel; RU addresses go direct. Change takes effect immediately for new connections.');
		routingModeInFlight = true;
		return uiConfirm(msg).then(L.bind(function(ok) {
			if (!ok) { routingModeInFlight = false; return null; }
			if (sel) sel.disabled = true;
			return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-routing-mode', newMode]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					res.code === 0 ? 'info' : 'warning');
				routingModeInFlight = false;
				if (sel) sel.disabled = false;
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('set-routing-mode failed: ') + err), 'danger');
				routingModeInFlight = false;
				var s = document.getElementById('routing-mode-select');
				if (s) s.disabled = false;
			});
		}, this));
	},

	// ── handleSourceToggle ───────────────────────────────────────────────────
	// Checkbox toggle for a force_source enabled state.
	handleSourceToggle: function(ev, sourceName) {
		var cb = document.getElementById('force-src-' + sourceName);
		if (!cb) return Promise.resolve();
		var enabled = cb.checked ? '1' : '0';
		cb.disabled = true;
		return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-source', sourceName, enabled]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			if (cb) cb.disabled = false;
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('set-source failed: ') + err), 'danger');
			if (cb) { cb.disabled = false; cb.checked = !cb.checked; }
		});
	},

	// ── handleForceUpdate ────────────────────────────────────────────────────
	// "Update now" button — runs amnezia-force-update synchronously.
	handleForceUpdate: function(ev) {
		if (forceUpdateInFlight) {
			ui.addNotification(null, E('p', {}, _('An update is already running')), 'info');
			return Promise.resolve();
		}
		forceUpdateInFlight = true;
		var btn = document.getElementById('force-update-btn');
		if (btn) { btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = _('Updating...'); }
		return fs.exec('/usr/bin/amnezia-force-update').then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			forceUpdateInFlight = false;
			if (btn) { delete btn.dataset.busy; btn.disabled = false; btn.textContent = _('Update now'); }
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Force update failed: ') + err), 'danger');
			forceUpdateInFlight = false;
			var b = document.getElementById('force-update-btn');
			if (b) { delete b.dataset.busy; b.disabled = false; b.textContent = _('Update now'); }
		});
	},

	// ── handleSaveManual ─────────────────────────────────────────────────────
	// Saves the manual force-tunnel list via amnezia-force-load save-manual.
	// Content goes as an argv element (no fs.write — the proven channel).
	handleSaveManual: function(ev) {
		if (saveManualInFlight) {
			ui.addNotification(null, E('p', {}, _('A save is already in progress')), 'info');
			return Promise.resolve();
		}
		var ta = document.getElementById('manual-list-ta');
		var content = (ta && ta.value) || '';
		// Validate: each non-blank, non-comment line must be a domain or IPv4/CIDR.
		var lines = content.split('\n');
		for (var i = 0; i < lines.length; i++) {
			var line = lines[i].replace(/#.*$/, '').trim();
			if (!line) continue;
			// Accept IPv4/CIDR or domain name; reject anything else.
			if (!/^[0-9.\/]+$/.test(line) && !/^[A-Za-z0-9.\-_]+$/.test(line)) {
				ui.addNotification(null, E('p', {}, _('Invalid entry (line ') + (i + 1) + '): ' + line), 'warning');
				return Promise.resolve();
			}
		}
		saveManualInFlight = true;
		var btn = document.getElementById('manual-save-btn');
		if (btn) { btn.disabled = true; btn.textContent = _('Saving...'); }
		return fs.exec('/usr/bin/amnezia-force-load', ['save-manual', content]).then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				res.code === 0 ? 'info' : 'warning');
			saveManualInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Save & apply'); }
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Save manual list failed: ') + err), 'danger');
			saveManualInFlight = false;
			var b = document.getElementById('manual-save-btn');
			if (b) { b.disabled = false; b.textContent = _('Save & apply'); }
		});
	},

	handleProbe: function(ev, domainOverride) {
		if (probeInFlight) {
			ui.addNotification(null, E('p', {}, _('A probe is already running -- wait for it to finish')), 'info');
			return Promise.resolve();
		}
		var input = document.getElementById('probe-domain');
		var domain = domainOverride || (input && input.value || '').trim();
		if (!domain) {
			ui.addNotification(null, E('p', {}, _('Enter a domain first')), 'warning');
			return Promise.resolve();
		}
		if (!/^[A-Za-z0-9.\-_]{2,253}$/.test(domain)) {
			ui.addNotification(null, E('p', {}, _('Invalid domain: ') + domain), 'warning');
			return Promise.resolve();
		}
		probeInFlight = true;
		var btn = document.getElementById('probe-btn');
		var resultEl = document.getElementById('probe-result');
		if (btn) { btn.disabled = true; btn.textContent = _('Probing...'); }
		if (resultEl) {
			resultEl.style.color = '#666';
			resultEl.textContent = _('Probing ') + domain + '...';
		}
		return fs.exec('/usr/bin/zapret-probe', [domain]).then(function(res) {
			probeInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Probe'); }
			var parsed = parseProbe(res && res.stdout);
			if (!parsed) {
				if (resultEl) {
					resultEl.style.color = '#a94442';
					resultEl.textContent = _('Probe failed: ') + ((res && res.stderr) || _('no output'));
				}
				return;
			}
			if (resultEl) {
				resultEl.style.color = verdictColor(parsed.verdict);
				resultEl.innerHTML = '';
				resultEl.appendChild(E('strong', {}, parsed.verdict));
				resultEl.appendChild(document.createTextNode(' — ' + parsed.reason));
				resultEl.appendChild(E('br'));
				resultEl.appendChild(E('span', { 'style': 'color:#444;font-size:11px;' }, parsed.recommendation));
				resultEl.appendChild(E('br'));
				resultEl.appendChild(E('span', { 'style': 'color:#888;font-size:11px;font-family:monospace;' },
					'status=' + parsed.status + ' time=' + parsed.time_total + 's' +
					(parsed.redirects ? ' redirects=' + parsed.redirects : '')));
			}
		}).catch(function(err) {
			probeInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Probe'); }
			if (resultEl) {
				resultEl.style.color = '#a94442';
				resultEl.textContent = _('Probe failed: ') + err;
			}
		});
	},

	handleVerify: function(ev) {
		if (verifyInFlight) {
			ui.addNotification(null, E('p', {}, _('Verify is already running -- wait for it to finish')), 'info');
			return Promise.resolve();
		}
		var input = document.getElementById('verify-domains');
		var raw = (input && input.value || '').trim();
		if (!raw) {
			ui.addNotification(null, E('p', {}, _('Enter at least one domain (comma-separated)')), 'warning');
			return Promise.resolve();
		}
		var parts = raw.split(',').map(function(s){ return s.trim(); }).filter(Boolean);
		if (parts.length === 0) {
			ui.addNotification(null, E('p', {}, _('No domains given')), 'warning');
			return Promise.resolve();
		}
		// Validate client-side so a typo doesn't blow ~5s of probe budget per
		// bad token before zapret-verify rejects it.
		for (var i = 0; i < parts.length; i++) {
			if (!/^[A-Za-z0-9.\-_]{2,253}$/.test(parts[i])) {
				ui.addNotification(null, E('p', {}, _('Invalid domain: ') + parts[i]), 'warning');
				return Promise.resolve();
			}
		}
		verifyInFlight = true;
		var btn = document.getElementById('verify-btn');
		var box = document.getElementById('verify-result');
		if (btn) { btn.disabled = true; btn.textContent = _('Verifying...'); }
		if (box) {
			box.innerHTML = '';
			box.appendChild(E('span', { 'style': 'color:#666;' },
				_('Probing ') + parts.length + _(' domains (~') + (parts.length * 8) + _('s)...')));
		}
		return fs.exec('/usr/bin/zapret-verify', [parts.join(',')]).then(function(res) {
			verifyInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Verify'); }
			var parsed = parseVerify(res && res.stdout);
			if (!parsed) {
				if (box) {
					box.innerHTML = '';
					box.appendChild(E('span', { 'style': 'color:#a94442;' },
						_('Verify failed: ') + ((res && res.stderr) || _('no output'))));
				}
				return;
			}
			if (box) {
				box.innerHTML = '';
				var table = E('table', {
					'style': 'border-collapse:collapse;font-size:11px;width:100%;max-width:100%;table-layout:fixed;'
				});
				var head = E('tr', {}, [
					E('th', { 'style': 'text-align:left;padding:3px 6px;border-bottom:1px solid #ddd;width:30%;' }, _('Domain')),
					E('th', { 'style': 'text-align:left;padding:3px 6px;border-bottom:1px solid #ddd;width:22%;' }, _('Verdict')),
					E('th', { 'style': 'text-align:left;padding:3px 6px;border-bottom:1px solid #ddd;' }, _('Reason')),
					E('th', { 'style': 'text-align:right;padding:3px 6px;border-bottom:1px solid #ddd;width:12%;' }, _('Status / time'))
				]);
				table.appendChild(head);
				// Tally for the summary line.
				var counts = { direct_ok: 0, direct_geoblocked: 0, direct_dpi_blocked: 0,
					direct_blocked: 0, direct_unreachable: 0, error: 0 };
				for (var j = 0; j < parsed.results.length; j++) {
					var r = parsed.results[j] || {};
					var v = r.verdict || 'error';
					if (counts[v] === undefined) counts[v] = 0;
					counts[v]++;
					var row = E('tr', {}, [
						E('td', { 'style': 'padding:3px 6px;border-bottom:1px solid #eee;font-family:monospace;word-break:break-all;' },
							r.domain || ''),
						E('td', { 'style': 'padding:3px 6px;border-bottom:1px solid #eee;color:' + verdictColor(v) + ';font-weight:bold;' },
							v),
						E('td', { 'style': 'padding:3px 6px;border-bottom:1px solid #eee;color:#444;word-break:break-word;' },
							r.reason || ''),
						E('td', { 'style': 'padding:3px 6px;border-bottom:1px solid #eee;text-align:right;color:#888;font-family:monospace;' },
							(r.status !== undefined ? r.status : '') +
							(r.time_total !== undefined ? (' / ' + r.time_total + 's') : ''))
					]);
					table.appendChild(row);
				}
				var summary = E('div', { 'style': 'margin-bottom:6px;color:#444;' }, [
					E('strong', {}, _('Summary: ')),
					counts.direct_ok       ? E('span', { 'style': 'color:#3c763d;margin-right:10px;' }, counts.direct_ok + ' ok')                  : '',
					counts.direct_geoblocked? E('span', { 'style': 'color:#a94442;margin-right:10px;' }, counts.direct_geoblocked + ' geoblocked') : '',
					counts.direct_dpi_blocked? E('span', { 'style': 'color:#f0ad4e;margin-right:10px;' }, counts.direct_dpi_blocked + ' dpi')      : '',
					counts.direct_blocked  ? E('span', { 'style': 'color:#a94442;margin-right:10px;' }, counts.direct_blocked + ' blocked')        : '',
					counts.direct_unreachable? E('span', { 'style': 'color:#888;margin-right:10px;' }, counts.direct_unreachable + ' unreachable'): '',
					counts.error           ? E('span', { 'style': 'color:#a94442;margin-right:10px;' }, counts.error + ' error')                   : ''
				]);
				box.appendChild(summary);
				box.appendChild(table);
				// Action hint: tell the user what to do with the verdicts.
				var hint = '';
				if (counts.direct_dpi_blocked) {
					hint = _('Some domains failed via DPI. Re-run blockcheck with those domains as input to find a stronger nfqws strategy.');
				} else if (counts.direct_geoblocked) {
					hint = _('Some domains refused us by country / anti-VPN. Those are must-tunnel candidates -- DPI tuning will not help.');
				} else if (counts.direct_ok > 0 && counts.direct_blocked === 0) {
					// No DPI/geoblock failures means the current strategy isn't the
					// bottleneck for this set, even if a domain timed out transiently.
					hint = _('No DPI or geoblock failures. Current strategy covers this set; any unreachable entries look like transient outages.');
				}
				if (hint) {
					box.appendChild(E('div', { 'style': 'margin-top:6px;color:#555;font-style:italic;' }, hint));
				}
			}
		}).catch(function(err) {
			verifyInFlight = false;
			if (btn) { btn.disabled = false; btn.textContent = _('Verify'); }
			if (box) {
				box.innerHTML = '';
				box.appendChild(E('span', { 'style': 'color:#a94442;' }, _('Verify failed: ') + err));
			}
		});
	},

	handleBlockcheckRun: function(ev) {
		var input = document.getElementById('bc-domain');
		var raw = (input && input.value || '').trim() || 'youtube.com';
		// Accept comma-separated list. Validate each token defensively --
		// fs.exec passes argv array (no injection possible) but reject garbage
		// so a typo doesn't waste 30 min on a non-existent domain.
		var parts = raw.split(',').map(function(s){ return s.trim(); }).filter(Boolean);
		if (parts.length === 0) {
			ui.addNotification(null, E('p', {}, _('No domains given')), 'warning');
			return Promise.resolve();
		}
		for (var i = 0; i < parts.length; i++) {
			if (!/^[A-Za-z0-9.\-_]{2,253}$/.test(parts[i])) {
				ui.addNotification(null, E('p', {}, _('Invalid domain: ') + parts[i]), 'warning');
				return Promise.resolve();
			}
		}
		var domain = parts.join(',');
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

	handleSelectRecommended: function(ev) {
		var list = document.getElementById('apply-list');
		if (!list) return Promise.resolve();
		var rows = list.querySelectorAll('label.apply-row');
		var toggled = 0;
		for (var i = 0; i < rows.length; i++) {
			if (rows[i].getAttribute('data-recommended') === 'true') {
				var cb = rows[i].querySelector('input[type=checkbox]');
				if (cb && !cb.checked) { cb.checked = true; toggled++; }
			}
		}
		if (toggled === 0) {
			// Button is disabled by paintApply when no row is recommended, so
			// reaching here means everything recommended was already checked.
			ui.addNotification(null, E('p', {},
				_('All recommended strategies are already checked')), 'info');
		}
		return Promise.resolve();
	},

	handleApply: function(ev) {
		var list = document.getElementById('apply-list');
		var selected = [];
		if (list) {
			var inputs = list.querySelectorAll('input[type=checkbox]:checked');
			for (var i = 0; i < inputs.length; i++) {
				var row = inputs[i].parentNode;
				selected.push({
					strategy: inputs[i].value,
					scope: row.getAttribute('data-scope') || '',
					domain: row.getAttribute('data-domain') || ''
				});
			}
		}
		if (selected.length === 0) {
			ui.addNotification(null, E('p', {}, _('Check at least one strategy first')), 'warning');
			return Promise.resolve();
		}
		var composed = composeNfqwsOpt(selected);
		var msg = (selected.length === 1)
			? _('Apply this nfqws strategy and restart zapret?')
			: _('Combine ') + selected.length + _(' strategies (joined with --new) and restart zapret?\nnfqws picks the first matching block per connection.');

		// Lock the buttons BEFORE the confirm modal: a 5s poll firing while the
		// user reads the dialog must not re-enable Apply for a second click.
		applyInFlight = true;
		return uiConfirm(msg + '\n\n' + composed).then(L.bind(function(ok) {
			if (!ok) { applyInFlight = false; return null; }
			var btn = document.getElementById('apply-btn');
			if (btn) { btn.disabled = true; btn.textContent = _('Applying...'); }
			return fs.exec('/usr/bin/zapret-apply', ['apply', composed]).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					(res.code === 0) ? 'info' : 'danger');
				applyInFlight = false;
				if (btn) { btn.disabled = false; btn.textContent = _('Apply selected'); }
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Apply failed: ') + err), 'danger');
				applyInFlight = false;
				if (btn) { btn.disabled = false; btn.textContent = _('Apply selected'); }
			});
		}, this));
	},

	handleRevert: function(ev) {
		applyInFlight = true;
		return uiConfirm(_('Revert NFQWS_OPT to the previous backup and restart zapret?')).then(L.bind(function(ok) {
			if (!ok) { applyInFlight = false; return null; }
			var btn = document.getElementById('apply-revert-btn');
			if (btn) { btn.disabled = true; }
			return fs.exec('/usr/bin/zapret-apply', ['revert']).then(L.bind(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
					(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
					(res.code === 0) ? 'info' : 'danger');
				applyInFlight = false;
				if (btn) btn.disabled = false;
				return this.refresh();
			}, this)).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Revert failed: ') + err), 'danger');
				applyInFlight = false;
				if (btn) btn.disabled = false;
			});
		}, this));
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
		return fs.exec('/usr/bin/amnezia-ru-cidr').then(L.bind(function(res) {
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
		if (!document.getElementById('failover-tunnel-table')) {
			if (pollFn) { poll.remove(pollFn); pollFn = null; }
			return Promise.resolve();
		}
		var self = this;
		var p1 = L.resolveDefault(fs.read('/etc/amnezia/ru-update.json'), '').then(function(text) {
			paintRuStamp(parseRuStamp(text));
		});
		var p2 = L.resolveDefault(fs.exec('/usr/bin/zapret-status'), null).then(function(res) {
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
		var p3 = L.resolveDefault(fs.read('/etc/amnezia/blockcheck.json'), '').then(L.bind(function(text) {
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
		var p4 = Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['state']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['parse']), { stdout: '' })
		]).then(function(res) {
			var st = parseApplyState((res[0] && res[0].stdout) || '');
			var cand = parseCandidates((res[1] && res[1].stdout) || '');
			paintApply(st, cand);
		});
		var p5 = L.resolveDefault(fs.read('/var/run/amnezia-failover.json'), '').then(function(text) {
			var st = parseFailoverState(text);
			paintFailoverSummary(st);
			var tableEl = document.getElementById('failover-tunnel-table');
			if (tableEl) {
				tableEl.innerHTML = '';
				tableEl.appendChild(renderTunnelTable(st, self));
			}
			// C1: repaint routing-mode select from live state. Guard: skip when
			// the select is focused (user may be mid-interaction).
			var routingSel = document.getElementById('routing-mode-select');
			if (routingSel && document.activeElement !== routingSel && st && st.routing_mode) {
				routingSel.value = st.routing_mode;
			}
			// H1: repaint source checkboxes from live state. Guard: skip each box
			// when it currently has focus (user may be mid-click).
			if (st && st.sources) {
				var sourceNames = ['itdoginfo_inside', 'itdoginfo_services', 'refilter_domains', 'refilter_ip', 'antifilter'];
				for (var si = 0; si < sourceNames.length; si++) {
					var sn = sourceNames[si];
					if (Object.prototype.hasOwnProperty.call(st.sources, sn)) {
						var cb = document.getElementById('force-src-' + sn);
						if (cb && document.activeElement !== cb) {
							cb.checked = !!st.sources[sn];
						}
					}
				}
			}
		});
		var p6 = L.resolveDefault(fs.read('/etc/amnezia/force-update.json'), '').then(function(text) {
			paintForceStamp(parseRuStamp(text));
		});
		var p7 = Promise.all([
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
			paintAutolearnTable(entries, self);
		}, this));
		return Promise.all([p1, p2, p3, p4, p5, p6, p7]);
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
			L.resolveDefault(fs.read('/etc/amnezia/force-tunnel.list'), '')
			// M3: force-update.json dropped from load() — refresh()'s p6 reads it
			// on every poll, so the initial paint comes from the first refresh() call.
		]);
	},

	render: function(data) {
		// load() returns 9 entries:
		// [0] ru-update.json, [1] zapret-status, [2] blockcheck.json,
		// [3] blockcheck log, [4] zapret-apply state, [5] zapret-apply parse,
		// [6] seed-must-tunnel.list, [7] amnezia-failover.json,
		// [8] force-tunnel.list
		// (force-update.json is no longer in load() — refresh()'s p6 reads it)
		var stamp = parseRuStamp(data && data[0]);
		var zap = parseZapret((data && data[1] && data[1].stdout) || '');
		var bc = parseBlockcheck(data && data[2]);
		var bcLog = (data && data[3] && data[3].stdout) || '';
		var applySt = parseApplyState((data && data[4] && data[4].stdout) || '');
		var applyCands = parseCandidates((data && data[5] && data[5].stdout) || '');
		var seedList = parseSeedList((data && data[6]) || '');
		var failoverState = parseFailoverState((data && data[7]) || '');
		var forceTunnelList = (data && data[8]) || '';
		// forceUpdateStamp is not available at render time (M3: dropped from load).
		// The force-update panel starts empty and is filled on first refresh() call.
		// Seed the rebuild-guard so the first poll doesn't tear down our select.
		candidatesSig = candidatesSignature(applyCands);

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('AmneziaWG')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Multi-tunnel AmneziaWG failover stack. RU traffic goes direct; foreign traffic routes through active tunnel(s). Status refreshes every 5 seconds.')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Failover tunnels')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Per-tunnel status driven by /var/run/amnezia-failover.json. Mode and sticky target are applied via amnezia-failover-ctl.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Active tunnel')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'failover-active-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:' +
									(failoverState && !failoverState.all_down ? '#3c763d' : '#a94442') +
									';margin-right:8px;vertical-align:middle;'
							}),
							E('strong', { 'id': 'failover-active-label' },
								failoverState
									? (failoverState.all_down
										? _('ALL DOWN')
										: (failoverState.active_pool || _('unknown')))
									: _('no data')),
							E('span', { 'id': 'failover-mode-label', 'style': 'margin-left:12px;color:#666;font-size:11px;' },
								failoverState ? ('mode: ' + (failoverState.mode || '?')) : '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Mode')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('select', {
								'id': 'failover-mode-select',
								'class': 'cbi-input-select',
								'style': 'width:160px;margin-right:8px;',
								'change': ui.createHandlerFn(this, function(ev) {
									var sel = document.getElementById('failover-mode-select');
									if (!sel) return Promise.resolve();
									return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-mode', sel.value]).then(L.bind(function(res) {
										ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
											(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
											res.code === 0 ? 'info' : 'warning');
									}, this)).catch(function(err) {
										ui.addNotification(null, E('p', {}, _('set-mode failed: ') + err), 'danger');
									});
								})
							}, [
								E('option', { 'value': 'failover', 'selected': (!failoverState || failoverState.mode !== 'balance') ? '' : null }, _('failover (strict priority)')),
								E('option', { 'value': 'balance', 'selected': (failoverState && failoverState.mode === 'balance') ? '' : null }, _('balance (weighted)'))
							])
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Sticky target')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'failover-sticky-input',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:120px;margin-right:8px;',
								'value': (failoverState && failoverState.active_sticky) || '',
								'placeholder': 'awg1'
							}),
							E('button', {
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, function(ev) {
									var inp = document.getElementById('failover-sticky-input');
									var val = inp ? inp.value.trim() : '';
									if (!val) {
										ui.addNotification(null, E('p', {}, _('Enter a tunnel name (e.g. awg1)')), 'warning');
										return Promise.resolve();
									}
									return fs.exec('/usr/bin/amnezia-failover-ctl', ['set-sticky', val]).then(function(res) {
										ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
											(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
											res.code === 0 ? 'info' : 'warning');
									}).catch(function(err) {
										ui.addNotification(null, E('p', {}, _('set-sticky failed: ') + err), 'danger');
									});
								})
							}, _('Set sticky'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Tunnels')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'failover-tunnel-table' }, renderTunnelTable(failoverState, this))
						])
					])
				])
			]),

			// ── Add tunnel section ────────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Add tunnel')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Paste an AmneziaWG .conf file or an Amnezia vpn:// share link. vpn:// links are decoded in the browser — only the resulting .conf is sent to the router.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('.conf / vpn:// link')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('textarea', {
								'id': 'add-tunnel-conf',
								'class': 'cbi-input-text',
								'style': 'width:100%;height:160px;font-family:monospace;font-size:11px;box-sizing:border-box;',
								'placeholder': '[Interface]\nPrivateKey = ...\nAddress = 10.8.0.x/32\n...\n[Peer]\nPublicKey = ...\nEndpoint = host:port\n\nOR paste a vpn:// link here'
							})
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Label (optional)')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'add-tunnel-label',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:200px;margin-right:8px;',
								'placeholder': _('e.g. Backup VPN')
							}),
							E('button', {
								'id': 'add-tunnel-btn',
								'class': 'btn cbi-button-positive',
								'click': ui.createHandlerFn(this, 'handleAddTunnel')
							}, _('Add tunnel'))
						])
					])
				])
			]),

			// ── Routing mode section ──────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Routing mode')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Tunnel-default: all foreign traffic routes through the tunnel (RU addresses go direct). Direct-default (allowlist): only addresses in the force-tunnel list use the tunnel; everything else goes via WAN + zapret.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Active mode')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('select', {
								'id': 'routing-mode-select',
								'class': 'cbi-input-select',
								'style': 'width:280px;margin-right:8px;',
								'change': ui.createHandlerFn(this, 'handleRoutingMode')
							}, [
								E('option', {
									'value': 'tunnel-default',
									'selected': (!failoverState || (failoverState.routing_mode || 'tunnel-default') === 'tunnel-default') ? '' : null
								}, _('Tunnel-default (foreign → tunnel)')),
								E('option', {
									'value': 'direct-default',
									'selected': (failoverState && failoverState.routing_mode === 'direct-default') ? '' : null
								}, _('Direct-default (allowlist → tunnel)'))
							])
						])
					])
				])
			]),

			// ── Allowlist sources section ─────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Allowlist sources (force-tunnel list)')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Curated domain/IP lists that feed the force-tunnel set. Checked sources are fetched on update. In direct-default mode, only listed addresses use the tunnel.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Sources')),
						E('div', { 'class': 'cbi-value-field' }, [
							(function(self, fst) {
								// H1: drive checked state from live failover state sources map.
								// Fall back to defaultOn only when the daemon hasn't emitted sources yet.
								var liveSources = (fst && fst.sources) || null;
								var sourceDefs = [
									{ name: 'itdoginfo_inside',   label: 'itdoginfo (RKN-blocked, inside)',   defaultOn: true },
									{ name: 'itdoginfo_services', label: 'itdoginfo (geoblock-RU services)',   defaultOn: true },
									{ name: 'refilter_domains',   label: 'Re-filter (domains, broader)',        defaultOn: false },
									{ name: 'refilter_ip',        label: 'Re-filter (IP/CIDR)',                 defaultOn: false },
									{ name: 'antifilter',         label: 'antifilter.download (supplementary)', defaultOn: false }
								];
								var box = E('div', {});
								for (var si = 0; si < sourceDefs.length; si++) {
									(function(sd) {
										// Use live UCI-backed state when available; fall back to defaultOn.
										var isChecked = liveSources && Object.prototype.hasOwnProperty.call(liveSources, sd.name)
											? !!liveSources[sd.name]
											: sd.defaultOn;
										box.appendChild(E('label', { 'style': 'display:block;margin-bottom:4px;' }, [
											E('input', {
												'id': 'force-src-' + sd.name,
												'type': 'checkbox',
												'style': 'margin-right:6px;',
												'checked': isChecked ? '' : null,
												'change': ui.createHandlerFn(self, 'handleSourceToggle', sd.name)
											}),
											E('span', {}, _(sd.label))
										]));
									})(sourceDefs[si]);
								}
								return box;
							})(this, failoverState)
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Last update')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('strong', { 'id': 'force-when' },
								_('never updated')),  // M3: filled by first refresh() poll
							E('span', { 'id': 'force-count', 'style': 'margin-left:12px;color:#666;' },
								''),
							E('span', { 'id': 'force-status', 'style': 'margin-left:8px;' }, '')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'force-update-btn',
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleForceUpdate')
							}, _('Update now'))
						])
					])
				])
			]),

			// ── Manual entries section ────────────────────────────────────────
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Manual force-tunnel entries')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Domains and IPs/CIDRs that always go through the tunnel, regardless of routing mode. Auto-update never touches this list. One entry per line; # comments allowed.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Entries')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('textarea', {
								'id': 'manual-list-ta',
								'class': 'cbi-input-text',
								'style': 'width:100%;height:120px;font-family:monospace;font-size:11px;box-sizing:border-box;',
								'placeholder': '# one domain or IP/CIDR per line\nchatgpt.com\nspotify.com\n203.0.113.0/24'
							}, forceTunnelList)
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Action')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'id': 'manual-save-btn',
								'class': 'btn cbi-button-positive',
								'click': ui.createHandlerFn(this, 'handleSaveManual')
							}, _('Save & apply'))
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
								'style': 'display:block;font-size:11px;white-space:pre-wrap;word-break:break-all;box-sizing:border-box;max-width:100%;'
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
				E('h3', {}, _('Domain probe')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Tests how a domain behaves on direct WAN (no tunnel) and returns a verdict: direct works, geo/anti-VPN blocked, DPI blocked, or unreachable. Use it to decide whether a domain needs the AWG tunnel.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Domain')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'probe-domain',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:340px;margin-right:8px;',
								'placeholder': 'chatgpt.com'
							}),
							E('button', {
								'id': 'probe-btn',
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleProbe')
							}, _('Probe'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Result')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'probe-result', 'style': 'min-height:1.5em;color:#666;' },
								_('No probe run yet'))
						])
					]),
					seedList.length ? E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Reference list')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'style': 'font-size:11px;color:#666;margin-bottom:6px;' },
								_('Known geo-block / anti-VPN sites. Click a row to probe it.')),
							(function(self) {
								var box = E('div', {
									'style': 'max-height:200px;overflow-y:auto;border:1px solid #ddd;padding:6px;background:#fafafa;'
								});
								for (var i = 0; i < seedList.length; i++) {
									(function(dom) {
										box.appendChild(E('div', {
											'style': 'font-family:monospace;font-size:11px;padding:2px 4px;cursor:pointer;color:#08c;',
											'title': _('Probe ') + dom,
											'click': ui.createHandlerFn(self, 'handleProbe', dom)
										}, dom));
									})(seedList[i]);
								}
								return box;
							})(this)
						])
					]) : ''
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Verify list')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Probe a list of domains in one go. Use after Apply to confirm the current zapret strategy actually covers your common targets. Sequential probes, ~5-10s per domain.')),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Domains')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'id': 'verify-domains',
								'type': 'text',
								'class': 'cbi-input-text',
								'style': 'width:340px;margin-right:8px;',
								'placeholder': 'youtube.com, instagram.com, github.com'
							}),
							E('button', {
								'id': 'verify-btn',
								'class': 'btn cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleVerify')
							}, _('Verify'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Result')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', {
								'id': 'verify-result',
								'style': 'min-height:1.5em;color:#666;font-size:12px;box-sizing:border-box;max-width:100%;overflow-x:auto;'
							}, _('No verify run yet'))
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
								'style': 'width:340px;margin-right:8px;',
								'value': (bc && bc.domain) || 'youtube.com',
								'placeholder': _('youtube.com, instagram.com, ...'),
								'title': _('One or more domains separated by commas'),
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
								'style': 'background:#1e1e1e;color:#d4d4d4;padding:8px;margin:0;max-height:320px;overflow-y:auto;overflow-x:hidden;font-size:11px;white-space:pre-wrap;word-break:break-all;box-sizing:border-box;width:100%;'
							}, bcLog || _('(no log yet)'))
						])
					]),
					E('hr', { 'style': 'margin:12px 0;' }),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Recommendations')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'apply-summary', 'style': 'margin-bottom:6px;color:#666;font-size:12px;' },
								(applyCands.length
									? (applyCands.length + ' ' + _('working strategy(ies) found in current log -- check the ones to combine'))
									: _('Run blockcheck on a blocked domain to populate this list'))),
							(function(self) {
								var listEl = E('div', {
									'id': 'apply-list',
									'style': 'max-height:280px;overflow-y:auto;overflow-x:hidden;border:1px solid #ddd;padding:6px;margin-bottom:8px;background:#fafafa;box-sizing:border-box;width:100%;'
								});
								if (!applyCands.length) {
									listEl.appendChild(E('div', { 'style': 'color:#888;font-style:italic;' },
										_('(no working strategies in log yet)')));
								} else {
									for (var i = 0; i < applyCands.length; i++) {
										var c = applyCands[i];
										var isRec = (c.recommended === true);
										var row = E('label', {
											'class': 'apply-row' + (isRec ? ' apply-row-recommended' : ''),
											'data-scope': c.scope || '',
											'data-domain': c.domain || '',
											'data-recommended': isRec ? 'true' : 'false',
											'title': isRec ? _('blockcheck\'s first working strategy in this class') : '',
											'style': 'display:flex;align-items:flex-start;gap:8px;padding:3px 4px;font-family:monospace;font-size:11px;border-bottom:1px solid #eee;cursor:pointer;word-break:break-all;' +
												(isRec ? 'background:#fffbe6;border-left:3px solid #f0ad4e;' : '')
										}, [
											E('input', { 'type': 'checkbox', 'value': c.strategy, 'style': 'margin-top:3px;flex-shrink:0;' }),
											E('span', {}, [
												isRec ? E('span', { 'style': 'color:#f0ad4e;font-weight:bold;margin-right:4px;' }, '★') : '',
												E('span', { 'style': 'color:#666;' },
													'[ipv' + c.ipv + ' ' + c.scope + (c.domain ? ' ' + c.domain : '') + '] '),
												E('span', {}, c.strategy)
											])
										]);
										listEl.appendChild(row);
									}
								}
								return listEl;
							})(this),
							E('div', { 'style': 'font-size:11px;color:#666;margin-bottom:8px;' },
								_('Blocks are joined with --new and filtered by protocol (tcp 443 for TLS, udp 443 for QUIC). nfqws picks the first matching block per connection.')),
							E('button', {
								'id': 'apply-select-recommended-btn',
								'class': 'btn cbi-button-action',
								'style': 'margin-right:8px;',
								'disabled': (applyCands.length && applyCands.some(function(c){return c.recommended === true;})) ? null : '',
								'title': _('Tick all rows marked ★ (one per protocol class, picked by blockcheck as first-working)'),
								'click': ui.createHandlerFn(this, 'handleSelectRecommended')
							}, _('Select ★ recommended')),
							E('button', {
								'id': 'apply-btn',
								'class': 'btn cbi-button-positive',
								'style': 'margin-right:8px;',
								'disabled': applyCands.length ? null : '',
								'click': ui.createHandlerFn(this, 'handleApply')
							}, _('Apply selected')),
							E('button', {
								'id': 'apply-revert-btn',
								'class': 'btn cbi-button-negative',
								'style': (applySt && applySt.has_backup) ? '' : 'display:none;',
								'title': (applySt && applySt.backup_ts) ? (_('Backup from ') + applySt.backup_ts) : '',
								'click': ui.createHandlerFn(this, 'handleRevert')
							}, _('Revert to backup'))
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Current NFQWS_OPT')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('code', {
								'id': 'apply-current',
								'style': 'display:block;background:#f5f5f5;padding:6px;font-size:11px;white-space:pre-wrap;word-break:break-all;box-sizing:border-box;max-width:100%;'
							}, (applySt && applySt.current) || _('(NFQWS_OPT empty)'))
						])
					])
				])
			]),

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
								'click': ui.createHandlerFn(this, 'handleAutolearnToggle')
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
								'click': ui.createHandlerFn(this, 'handleAutolearnPurge')
							}, _('Purge all'))
						])
					])
				])
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

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
