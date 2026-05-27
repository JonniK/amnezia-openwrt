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

// Debounce: pbr's async interface trigger (fired by ifup/ifdown awg1) can
// briefly leave /var/run/pbr.nft mid-rewrite, so one transient unhealthy
// poll right after a tunnel toggle is normal. Require 2 consecutive bad
// polls before flipping the UI to red.
var pbrBadCount = 0;

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

function parseZapret(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
}

function parsePbr(text) {
	if (!text) return null;
	try { return JSON.parse(text); } catch (e) { return null; }
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

function paintPbr(s) {
	var dot = document.getElementById('pbr-dot');
	var label = document.getElementById('pbr-label');
	var detail = document.getElementById('pbr-detail');
	var btn = document.getElementById('pbr-reload-btn');

	if (!s) {
		if (dot) dot.style.background = '#888';
		if (label) label.textContent = _('pbr: unknown');
		if (detail) detail.textContent = '';
		if (btn) btn.className = 'btn cbi-button-action';
		return;
	}

	if (s.healthy) { pbrBadCount = 0; } else { pbrBadCount++; }
	var displayBad = pbrBadCount >= 2;

	var colour = !displayBad ? '#3c763d'
		: (s.running ? '#f0ad4e' : '#a94442');
	if (dot) dot.style.background = colour;

	var bits = [];
	bits.push(s.running ? _('running') : _('stopped'));
	bits.push(s.nft_ok ? _('nft ok') : _('nft BAD'));
	bits.push(_('ipdeny ') + s.ipdeny_count);
	if (s.recent_failure) bits.push(_('recent FAILED TO START'));
	if (label) label.textContent = bits.join(' / ');

	if (detail) detail.textContent = s.nft_error || '';

	// Reload button: action style by default, negative once we've actually
	// confirmed multiple bad polls (debounced) so a 5s transient during
	// awg-toggle's ifup/ifdown doesn't flash the button red.
	if (btn) {
		btn.className = 'btn ' + (displayBad ? 'cbi-button-negative' : 'cbi-button-action');
	}
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

function paintApply(state, candidates) {
	var sel = document.getElementById('apply-select');
	var currentEl = document.getElementById('apply-current');
	var applyBtn = document.getElementById('apply-btn');
	var revertBtn = document.getElementById('apply-revert-btn');
	var summary = document.getElementById('apply-summary');

	// Rebuild the <select> only when the candidate set actually changed --
	// otherwise an open dropdown is collapsed by the browser on every poll.
	if (sel) {
		var newSig = candidatesSignature(candidates);
		if (newSig !== candidatesSig) {
			candidatesSig = newSig;
			var prevValue = sel.value;
			sel.innerHTML = '';
			if (!candidates || candidates.length === 0) {
				var opt = document.createElement('option');
				opt.textContent = _('(no working strategies in log yet)');
				opt.value = '';
				opt.disabled = true;
				sel.appendChild(opt);
			} else {
				for (var i = 0; i < candidates.length; i++) {
					var c = candidates[i];
					var label = '[ipv' + c.ipv + ' ' + c.scope + ' / ' + c.family + '] ' + c.strategy;
					if (label.length > 140) label = label.substring(0, 137) + '...';
					var o = document.createElement('option');
					o.textContent = label;
					o.value = c.strategy;
					sel.appendChild(o);
				}
				if (prevValue) {
					for (var j = 0; j < sel.options.length; j++) {
						if (sel.options[j].value === prevValue) { sel.selectedIndex = j; break; }
					}
				}
			}
		}
	}

	if (summary) {
		var count = (candidates && candidates.length) || 0;
		summary.textContent = count
			? (count + ' ' + _('working strategy(ies) found in current log'))
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
	handlePbrReload: function(ev) {
		var btn = document.getElementById('pbr-reload-btn');
		if (btn) { btn.disabled = true; btn.textContent = _('Reloading...'); }
		return fs.exec('/usr/bin/pbr-reload').then(L.bind(function(res) {
			ui.addNotification(null, E('pre', { 'style': 'white-space:pre-wrap;margin:0;' },
				(res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')),
				(res.code === 0) ? 'info' : 'warning');
			if (btn) { btn.disabled = false; btn.textContent = _('Reload PBR'); }
			return this.refresh();
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('PBR reload failed: ') + err), 'danger');
			var b = document.getElementById('pbr-reload-btn');
			if (b) { b.disabled = false; b.textContent = _('Reload PBR'); }
		});
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

	handleBlockcheckRun: function(ev) {
		var input = document.getElementById('bc-domain');
		var domain = (input && input.value || '').trim() || 'youtube.com';
		// Domain validation: hostname chars only, no shell metachars (defensive --
		// fs.exec passes argv array so injection isn't possible, but reject
		// obvious garbage to avoid hour-long runs on bad input).
		if (!/^[A-Za-z0-9.\-_]{2,253}$/.test(domain)) {
			ui.addNotification(null, E('p', {}, _('Invalid domain: ') + domain), 'warning');
			return Promise.resolve();
		}
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

	handleApply: function(ev) {
		var sel = document.getElementById('apply-select');
		if (!sel || !sel.value) {
			ui.addNotification(null, E('p', {}, _('Select a strategy first')), 'warning');
			return Promise.resolve();
		}
		var strategy = sel.value;
		// Lock the buttons BEFORE the confirm modal: a 5s poll firing while the
		// user reads the dialog must not re-enable Apply for a second click.
		applyInFlight = true;
		return uiConfirm(_('Apply this nfqws strategy and restart zapret?\n\n') + strategy).then(L.bind(function(ok) {
			if (!ok) { applyInFlight = false; return null; }
			var btn = document.getElementById('apply-btn');
			if (btn) { btn.disabled = true; btn.textContent = _('Applying...'); }
			return fs.exec('/usr/bin/zapret-apply', ['apply', strategy]).then(L.bind(function(res) {
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
		var p3 = L.resolveDefault(fs.exec('/usr/bin/zapret-status'), null).then(function(res) {
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
		var p4 = L.resolveDefault(fs.read('/etc/awg/blockcheck.json'), '').then(L.bind(function(text) {
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
		var p5 = Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['state']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['parse']), { stdout: '' })
		]).then(function(res) {
			var st = parseApplyState((res[0] && res[0].stdout) || '');
			var cand = parseCandidates((res[1] && res[1].stdout) || '');
			paintApply(st, cand);
		});
		var p6 = L.resolveDefault(fs.exec('/usr/bin/pbr-status'), { stdout: '' }).then(function(res) {
			paintPbr(parsePbr((res && res.stdout) || ''));
		});
		return Promise.all([p1, p2, p3, p4, p5, p6]);
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec('/usr/bin/awg-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/awg/ru-update.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-status'), { stdout: '' }),
			L.resolveDefault(fs.read('/etc/awg/blockcheck.json'), ''),
			L.resolveDefault(fs.exec('/usr/bin/zapret-blockcheck', ['log']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['state']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/zapret-apply', ['parse']), { stdout: '' }),
			L.resolveDefault(fs.exec('/usr/bin/pbr-status'), { stdout: '' })
		]);
	},

	render: function(data) {
		var initial = parseStatus((data && data[0] && data[0].stdout) || '');
		var stamp = parseRuStamp(data && data[1]);
		var zap = parseZapret((data && data[2] && data[2].stdout) || '');
		var bc = parseBlockcheck(data && data[3]);
		var bcLog = (data && data[4] && data[4].stdout) || '';
		var applySt = parseApplyState((data && data[5] && data[5].stdout) || '');
		var applyCands = parseCandidates((data && data[6] && data[6].stdout) || '');
		var pbr = parsePbr((data && data[7] && data[7].stdout) || '');
		// Seed the rebuild-guard so the first poll doesn't tear down our select.
		candidatesSig = candidatesSignature(applyCands);

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
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('PBR')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('span', {
								'id': 'pbr-dot',
								'style': 'display:inline-block;width:12px;height:12px;border-radius:50%;background:' +
									(pbr && pbr.healthy ? '#3c763d' : (pbr && pbr.running ? '#f0ad4e' : '#a94442')) +
									';margin-right:8px;vertical-align:middle;'
							}),
							E('span', { 'id': 'pbr-label' }, pbr
								? ((pbr.running ? _('running') : _('stopped')) + ' / ' +
								   (pbr.nft_ok ? _('nft ok') : _('nft BAD')) + ' / ' +
								   _('ipdeny ') + pbr.ipdeny_count +
								   (pbr.recent_failure ? (' / ' + _('recent FAILED TO START')) : ''))
								: _('pbr: unknown')),
							E('button', {
								'id': 'pbr-reload-btn',
								'style': 'margin-left:12px;',
								'class': 'btn ' + (pbr && pbr.healthy ? 'cbi-button-action' : 'cbi-button-negative'),
								'click': ui.createHandlerFn(this, 'handlePbrReload')
							}, _('Reload PBR')),
							E('div', { 'id': 'pbr-detail', 'style': 'margin-top:4px;color:#a94442;font-size:11px;' },
								(pbr && pbr.nft_error) ? pbr.nft_error : '')
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
								'style': 'font-size:11px;word-break:break-all;'
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
								'style': 'width:220px;margin-right:8px;',
								'value': (bc && bc.domain) || 'youtube.com',
								'placeholder': 'youtube.com',
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
								'style': 'background:#1e1e1e;color:#d4d4d4;padding:8px;margin:0;max-height:320px;overflow:auto;font-size:11px;white-space:pre;'
							}, bcLog || _('(no log yet)'))
						])
					]),
					E('hr', { 'style': 'margin:12px 0;' }),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Recommendations')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'id': 'apply-summary', 'style': 'margin-bottom:6px;color:#666;font-size:12px;' },
								(applyCands.length
									? (applyCands.length + ' ' + _('working strategy(ies) found in current log'))
									: _('Run blockcheck on a blocked domain to populate this list'))),
							(function() {
								var sel = E('select', {
									'id': 'apply-select',
									'class': 'cbi-input-select',
									'style': 'width:100%;max-width:720px;display:block;margin-bottom:6px;font-family:monospace;font-size:11px;'
								});
								if (!applyCands.length) {
									var o = document.createElement('option');
									o.textContent = _('(no working strategies in log yet)');
									o.disabled = true; o.value = '';
									sel.appendChild(o);
								} else {
									for (var i = 0; i < applyCands.length; i++) {
										var c = applyCands[i];
										var label = '[ipv' + c.ipv + ' ' + c.scope + ' / ' + c.family + '] ' + c.strategy;
										if (label.length > 140) label = label.substring(0, 137) + '...';
										var op = document.createElement('option');
										op.textContent = label;
										op.value = c.strategy;
										sel.appendChild(op);
									}
								}
								return sel;
							})(),
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
								'style': 'display:block;background:#f5f5f5;padding:6px;font-size:11px;word-break:break-all;'
							}, (applySt && applySt.current) || _('(NFQWS_OPT empty)'))
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'margin:0;' }, _('Live status')),
					E('button', {
						'id': 'manual-refresh-btn',
						'class': 'btn cbi-button-action',
						'style': 'margin-left:12px;',
						'title': _('Force an immediate poll instead of waiting for the 5s tick'),
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, _('Refresh status'))
				]),
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
