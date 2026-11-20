(function () {
  'use strict';

  var data = JSON.parse(document.getElementById('audioin-data').textContent || '{}');
  var S = data.strings || {};
  function t(k) { return S[k] || k; }
  function $(id) { return document.getElementById(id); }

  document.title = t('TITLE');
  $('h-title').textContent = t('TITLE');
  Array.prototype.forEach.call(document.querySelectorAll('[data-t]'), function (el) {
    el.textContent = t(el.getAttribute('data-t'));
  });

  var partsKey = null;
  var state = null, busy = false, players = [], peakHold = [null, null], peakAt = [0, 0];

  function rpc(player, cmd) {
    return fetch('/jsonrpc.js', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 1, method: 'slim.request', params: [player || '', cmd] })
    }).then(function (r) { return r.json(); }).then(function (j) { return j.result || {}; });
  }

  function msg(text) {
    var m = $('msg');
    m.textContent = text || '';
    m.hidden = !text;
  }

  function errText(r) {
    if (!r || !r.error) return '';
    var key = 'ERR_' + String(r.reason || r.error).toUpperCase();
    return S[key] || S['ERR_' + String(r.error).toUpperCase()] || (t('ERR_FAILED') + ' (' + (r.reason || r.error) + ')');
  }

  function cmd(args, withPlayer) {
    if (busy) return Promise.resolve();
    busy = true;
    var player = withPlayer ? $('player').value : '';
    return rpc(player, ['audioin'].concat(args)).then(function (r) {
      busy = false;
      msg(r.error ? errText(r) : '');
      return refresh();
    }, function () { busy = false; msg(t('ERR_FAILED')); });
  }

  function fmtTime(s) {
    s = Math.max(0, Math.floor(s || 0));
    var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (sec < 10 ? '0' : '') + sec;
  }

  // ---------- merac ----------
  function pct(db) {
    if (db === null || db === undefined) return 0;
    return Math.max(0, Math.min(100, (db + 60) / 60 * 100));
  }
  function color(db) { return db >= -6 ? 'var(--rec)' : db >= -12 ? 'var(--warn)' : 'var(--ok)'; }

  function drawMeter(m) {
    var now = Date.now();
    ['l', 'r'].forEach(function (c, i) {
      var pk = m && m.pk ? m.pk[i] : null;
      var fill = $('m-' + c);
      fill.style.width = pct(pk) + '%';
      fill.style.background = color(pk === null ? -99 : pk);
      if (pk !== null && pk !== undefined && (peakHold[i] === null || pk >= peakHold[i] || now - peakAt[i] > 3000)) {
        peakHold[i] = pk; peakAt[i] = now;
      }
      if (!m) peakHold[i] = null;
      $('m-' + c + 'p').style.left = pct(peakHold[i]) + '%';
      $('m-' + c + 'v').textContent = pk === null || pk === undefined ? '' : pk.toFixed(1);
    });
  }

  var meterTimer = null;
  function meterLoop() {
    clearTimeout(meterTimer);
    if (document.hidden || !state || !state.input || !state.input.open) { drawMeter(null); return; }
    rpc('', ['audioin', 'meter']).then(function (r) {
      drawMeter(r.meter);
      meterTimer = setTimeout(meterLoop, 250);
    }, function () { meterTimer = setTimeout(meterLoop, 1000); });
  }

  // ---------- stanje ----------
  function render() {
    var s = state || {}, inp = s.input || {}, rec = s.rec, ses = s.session;
    var open = !!inp.open;
    var info = [];
    if (open) {
      info.push((inp.src === 'file' ? 'test: ' + (inp.path || '') : (inp.dev || '')));
      if (inp.rate) info.push('24 bit / ' + (inp.rate / 1000) + ' kHz');
      info.push(t('UI_BUFFERED') + ' ' + fmtTime(inp.buffered));
      info.push(t('UI_LISTENERS') + ': ' + (s.listeners || 0));
    }
    $('in-state').textContent = !s.helper ? t('ERR_HELPER') : open ? '● ' + t('UI_INPUT') : t('UI_CLOSED');
    $('in-info').textContent = info.join(' · ');
    $('b-open').disabled = open || !s.helper;
    $('b-close').disabled = !open || !!rec;

    var lags = inp.lags || [];
    $('ls-info').textContent = lags.length ? lags.map(function (l) { return '−' + fmtTime(l) + ' ' + t('UI_BEHIND'); }).join(', ') : '';
    $('b-live').disabled = !open;

    // snimanje
    var recState = rec ? rec.state : null;
    $('b-rec').disabled = !!rec || !s.helper;
    $('b-pause').disabled = !rec || recState === 'stopping';
    $('b-pause').textContent = recState === 'paused' ? t('UI_RESUME') : t('UI_PAUSE');
    $('b-marker').disabled = !rec || recState !== 'rec';
    $('b-stop').disabled = !rec || recState === 'stopping';
    $('rc-time').innerHTML = '';
    if (rec) {
      if (recState === 'rec') { var d = document.createElement('span'); d.className = 'recdot'; $('rc-time').appendChild(d); }
      $('rc-time').appendChild(document.createTextNode(fmtTime(rec.seconds)));
      var ri = [t('UI_PART') + ' ' + rec.part, t('UI_MARKERS') + ': ' + (rec.markers || 0)];
      if (rec.xruns) ri.push(t('UI_XRUNS') + ': ' + rec.xruns);
      if (rec.clip_windows) ri.push(t('UI_CLIP') + '!');
      $('rc-info').textContent = ri.join(' · ');
    } else {
      $('rc-info').textContent = '';
    }
    $('rc-session').textContent = ses ? sessionTitle(ses) : t('UI_NO_SESSION');
    renderCover(ses);
    renderExports(ses);

    // delovi
    var sel = $('part'), cur = s.part;
    var names = ses ? ses.parts.map(function (p) { return p.name; }) : ['A'];
    if (cur && names.indexOf(cur) < 0) names.push(cur);
    sel.innerHTML = '';
    names.forEach(function (n) { var o = document.createElement('option'); o.value = n; o.textContent = n; if (n === cur) o.selected = true; sel.appendChild(o); });
    sel.disabled = !!rec;
    $('b-next').disabled = !ses;

    // sesija: forma (ne dira polje koje korisnik menja)
    if (ses && document.activeElement.tagName !== 'INPUT' && document.activeElement.tagName !== 'SELECT') {
      var m = ses.meta || {};
      $('s-type').value = ses.type || 'vinyl';
      $('s-artist').value = m.artist || '';
      $('s-album').value = m.album || '';
      $('s-year').value = m.year || '';
    }
    var parts = $('parts');
    var key = JSON.stringify(ses ? ses.parts : null);
    if (key === partsKey) return;    // crta se samo kad se promeni (dugmad ne trepere)
    partsKey = key;
    parts.innerHTML = '';
    if (ses) ses.parts.forEach(function (p) {
      var div = document.createElement('div'); div.className = 'part';
      var b = document.createElement('b'); b.textContent = p.name; div.appendChild(b);
      if (!p.takes.length) div.appendChild(document.createTextNode(' ' + t('UI_NONE')));
      p.takes.forEach(function (tk) {
        var x = document.createElement('div'); x.className = 'take';
        var bits = [tk.name, fmtTime(tk.seconds), t('UI_MARKERS') + ': ' + tk.markers];
        if (tk.xruns) bits.push(t('UI_XRUNS') + ': ' + tk.xruns);
        if (tk.clip_windows) bits.push(t('UI_CLIP') + '!');
        if (!tk.ok) bits.push('✕');
        x.textContent = bits.join(' · ') + ' ';
        if (tk.ok) {
          var eb = document.createElement('button'); eb.className = 'ghost icon'; eb.textContent = t('UI_EDIT');
          eb.onclick = function () { openEditor(ses.id, tk.name); };
          x.appendChild(eb);
        }
        div.appendChild(x);
      });
      parts.appendChild(div);
    });
  }

  function sessionTitle(ses) {
    var m = ses.meta || {};
    var name = [m.artist, m.album].filter(Boolean).join(' – ');
    return (name || ses.id) + (m.year ? ' (' + m.year + ')' : '');
  }

  var refreshTimer = null;
  function refresh() {
    clearTimeout(refreshTimer);
    return rpc('', ['audioin', 'status']).then(function (r) {
      var wasOpen = state && state.input && state.input.open;
      state = r;
      render();
      renderExport(state.export);
      if (state.input && state.input.open && !wasOpen) meterLoop();
      var fast = state.rec || (state.input && state.input.open) || (state.export && state.export.running);
      refreshTimer = setTimeout(refresh, fast ? 1000 : 5000);
    }, function () { refreshTimer = setTimeout(refresh, 5000); });
  }

  function loadPlayers() {
    rpc('', ['players', 0, 100]).then(function (r) {
      players = r.players_loop || [];
      var sel = $('player');
      sel.innerHTML = '';
      players.forEach(function (p) {
        var o = document.createElement('option');
        o.value = p.playerid; o.textContent = p.name;
        if (p.playerid === data.player) o.selected = true;
        sel.appendChild(o);
      });
    });
  }

  function loadSessions() {
    rpc('', ['audioin', 'sessions']).then(function (r) {
      var ul = $('sessions');
      ul.innerHTML = '';
      (r.sessions || []).forEach(function (s) {
        var li = document.createElement('li');
        var takes = 0;
        s.parts.forEach(function (p) { takes += p.takes.length; });
        var span = document.createElement('span');
        span.textContent = sessionTitle(s) + ' · ' + t('UI_TAKES') + ': ' + takes;
        var b = document.createElement('button'); b.className = 'ghost'; b.textContent = t('UI_SELECT');
        b.onclick = function () { cmd(['session_select', 'id:' + s.id]).then(loadSessions); };
        li.appendChild(span); li.appendChild(b);
        ul.appendChild(li);
      });
    });
  }

  // ---------- dugmad ----------
  $('b-open').onclick = function () { cmd(['open']); };
  $('b-close').onclick = function () { cmd(['close']); };
  $('b-listen').onclick = function () { cmd(['listen'], true); };
  $('b-live').onclick = function () { cmd(['listen'], true); };
  $('b-rec').onclick = function () { cmd(['rec_start', 'part:' + $('part').value]).then(loadSessions); };
  $('b-pause').onclick = function () { cmd([state && state.rec && state.rec.state === 'paused' ? 'rec_resume' : 'rec_pause']); };
  $('b-marker').onclick = function () { cmd(['marker'], true); };
  $('b-stop').onclick = function () { cmd(['rec_stop']).then(function () { setTimeout(loadSessions, 2000); }); };
  $('b-next').onclick = function () { cmd(['next_part']); };
  $('part').onchange = function () {
    if (state && state.session) cmd(['session_select', 'id:' + state.session.id, 'part:' + $('part').value]);
  };
  $('sess-form').onsubmit = function (e) {
    e.preventDefault();
    var args = ['type:' + $('s-type').value, 'artist:' + $('s-artist').value, 'album:' + $('s-album').value, 'year:' + $('s-year').value];
    if (state && state.session) cmd(['session_edit', 'id:' + state.session.id].concat(args)).then(loadSessions);
    else cmd(['session_new'].concat(args)).then(loadSessions);
  };
  $('b-new').onclick = function () {
    var args = ['type:' + $('s-type').value, 'artist:' + $('s-artist').value, 'album:' + $('s-album').value, 'year:' + $('s-year').value];
    cmd(['session_new'].concat(args)).then(loadSessions);
  };
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { refresh(); meterLoop(); } });

  // ---------- MusicBrainz ----------
  function mbSearch() {
    var ses = state && state.session;
    var args = ['mb_search', 'artist:' + $('s-artist').value, 'album:' + $('s-album').value];
    if (ses) args.push('id:' + ses.id);
    $('mb').hidden = false;
    $('mb-info').textContent = t('UI_MB_SEARCHING');
    $('mb-list').innerHTML = '';
    rpc('', ['audioin'].concat(args)).then(function (r) {
      if (r.error) { $('mb-info').textContent = errText(r); return; }
      var list = r.releases || [];
      $('mb-info').textContent = list.length ? t('UI_MB_PICK') : t('UI_MB_NONE');
      list.forEach(function (x) {
        var li = document.createElement('li');
        var d = document.createElement('div'); d.className = 'mb-t';
        var a = document.createElement('div'); a.textContent = x.artist + ' – ' + x.title; if (x.match) a.className = 'hit';
        var b = document.createElement('div'); b.className = 'mb-sub';
        b.textContent = [x.formats, x.date, x.country, x.label, x.catno, x.tracks + ' ' + t('UI_TRACKS_N')].filter(Boolean).join(' · ');
        d.appendChild(a); d.appendChild(b);
        var btn = document.createElement('button'); btn.className = 'ghost'; btn.textContent = t('UI_MB_APPLY');
        btn.onclick = function () { mbApply(x.id); };
        li.appendChild(d); li.appendChild(btn);
        $('mb-list').appendChild(li);
      });
    }, function () { $('mb-info').textContent = t('ERR_FAILED'); });
  }

  function mbApply(release) {
    var go = function (sid) {
      $('mb-info').textContent = t('UI_MB_SEARCHING');
      rpc('', ['audioin', 'mb_apply', 'id:' + sid, 'release:' + release]).then(function (r) {
        if (r.error) { $('mb-info').textContent = errText(r); return; }
        $('mb-list').innerHTML = '';
        $('mb-info').textContent = t('UI_MB_APPLIED');
        partsKey = null;
        refresh(); loadSessions();
        if (ed && ed.sid === sid) openEditor(sid, ed.take);
        setTimeout(refresh, 3000);    // omot stize posle
      });
    };
    if (state && state.session) return go(state.session.id);
    rpc('', ['audioin', 'session_new', 'type:' + $('s-type').value]).then(function (r) { if (r.id) go(r.id); });
  }

  $('b-mb').onclick = mbSearch;

  // Izvozi albuma: premestanje poslednjeg izvoza u izabrani folder biblioteke.
  var exportsKey = null;
  function renderExports(ses) {
    var box = $('exports');
    var list = ses ? ses.exports || [] : [];
    var key = JSON.stringify([ses && ses.id, list]);
    if (key === exportsKey) return;
    exportsKey = key;
    box.innerHTML = '';
    list.forEach(function (x, i) {
      var row = document.createElement('div'); row.className = 'take';
      row.textContent = (x.moved ? t('UI_IN_LIBRARY') : t('UI_EXPORTED')) + ' ' + x.dir + (x.error ? ' (' + (S['ERR_' + String(x.error).toUpperCase()] || x.error) + ')' : '') + ' ';
      var last = i === list.length - 1 || list.slice(i + 1).every(function (y) { return y.moved; });
      if (!x.moved && last) {
        var b = document.createElement('button'); b.className = 'ghost icon'; b.textContent = t('UI_MOVE');
        b.onclick = function () {
          var m = ses.meta || {};
          window.FolderPicker.open({
            prefix: 'audioin', t: t, artist: m.artist || '', name: String(x.dir).replace(/^.*\//, '').replace(/ \(\d+\)$/, ''),
            rpc: function (args) { return rpc('', args); },
            onPick: function (dir, name) { cmd(['move', 'id:' + ses.id, 'dir:' + dir, 'name:' + name]).then(loadSessions); }
          });
        };
        row.appendChild(b);
      }
      box.appendChild(row);
    });
  }

  function renderCover(ses) {
    var img = $('s-cover');
    var c = ses && ses.meta && ses.meta.cover;
    if (!c) { img.hidden = true; return; }
    var src = '/plugins/AudioIn/cover/' + ses.id + '.' + c + '.jpg';
    if (img.getAttribute('src') !== src) img.setAttribute('src', src);
    img.hidden = false;
  }

  // ---------- editor pesama ----------
  var ed = null;    // { sid, take, data, tracks, zoom, cursor, sel, drag }
  var HIT = 6;      // px oko granice za hvatanje

  function fmtPrec(s) {
    s = Math.max(0, s || 0);
    var m = Math.floor(s / 60), r = s - m * 60;
    return m + ':' + (r < 10 ? '0' : '') + r.toFixed(1);
  }

  function openEditor(sid, take) {
    rpc('', ['audioin', 'take', 'id:' + sid, 'take:' + take, 'points:3000']).then(function (r) {
      if (r.error) { msg(errText(r)); return; }
      ed = { sid: sid, take: take, data: r, zoom: 1, cursor: null, sel: 0,
        tracks: (r.tracks || []).map(function (x) { return { start: x.start, end: x.end, title: x.title || '', keep: x.keep !== 0, from: x.from, mbid: x.mbid, artist: x.artist }; }) };
      if (!ed.tracks.length) ed.tracks = [{ start: 0, end: r.frames, title: '', keep: true, from: 'edge' }];
      $('editor').hidden = false;
      $('ed-h').textContent = t('UI_EDIT') + ' · ' + r.part + ' (' + take + ')';
      var a = r.analysis || {};
      $('ed-info').textContent = fmtTime(r.frames / r.rate) + ' · ' + (r.rate / 1000) + ' kHz' +
        (a.floor_db !== undefined && a.floor_db !== null ? ' · floor ' + a.floor_db + ' dBFS, thr ' + a.thr_db + ' dBFS' : '') +
        ((r.xruns || []).length ? ' · ' + t('UI_XRUNS') + ': ' + r.xruns.length : '');
      drawEd(); renderTracks();
      $('editor').scrollIntoView({ behavior: 'smooth' });
    });
  }

  function canvasW() { return Math.max(300, Math.floor($('editor').clientWidth - 34) * ed.zoom); }
  function xOf(f) { return f / ed.data.frames * $('wave').width; }
  function fOf(x) { return Math.max(0, Math.min(ed.data.frames, Math.round(x / $('wave').width * ed.data.frames))); }

  // Granice: [frejm, indeks]; indeks k = pocetak pesme k, k == n = kraj poslednje.
  function bounds() {
    var b = ed.tracks.map(function (tr, i) { return [tr.start, i]; });
    b.push([ed.tracks[ed.tracks.length - 1].end, ed.tracks.length]);
    return b;
  }

  function drawEd() {
    if (!ed) return;
    var cv = $('wave'), dpr = window.devicePixelRatio || 1;
    var w = canvasW(), h = 140;
    cv.style.width = w + 'px'; cv.style.height = h + 'px';
    cv.width = w * dpr; cv.height = h * dpr;
    var c = cv.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    var css = getComputedStyle(document.documentElement);
    var col = function (v) { return css.getPropertyValue(v).trim(); };
    c.clearRect(0, 0, w, h);
    var pts = ed.data.points || [], n = pts.length, mid = h / 2;
    var scaleW = w / ed.data.frames;
    var X = function (f) { return f * scaleW; };
    // necuvane pesme zatamnjene
    ed.tracks.forEach(function (tr, i) {
      if (i === ed.sel) { c.fillStyle = col('--accent'); c.globalAlpha = 0.10; c.fillRect(X(tr.start), 0, X(tr.end) - X(tr.start), h); }
      if (!tr.keep) { c.fillStyle = col('--fg'); c.globalAlpha = 0.08; c.fillRect(X(tr.start), 0, X(tr.end) - X(tr.start), h); }
    });
    c.globalAlpha = 1;
    for (var i = 0; i < n; i++) {
      var x = i / n * w, pk = pts[i][0], rm = pts[i][1];
      c.fillStyle = col('--muted'); c.fillRect(x, mid - pk * mid, Math.max(1, w / n), pk * mid * 2);
      c.fillStyle = col('--accent'); c.fillRect(x, mid - rm * mid, Math.max(1, w / n), rm * mid * 2);
    }
    // markeri iz snimanja
    (ed.data.markers || []).forEach(function (m) {
      c.fillStyle = m.kind === 'pause' ? col('--warn') : col('--ok');
      c.beginPath(); var mx = X(m.frame); c.moveTo(mx - 5, 0); c.lineTo(mx + 5, 0); c.lineTo(mx, 8); c.fill();
    });
    (ed.data.xruns || []).forEach(function (f) { c.fillStyle = col('--rec'); c.fillRect(X(f) - 1, h - 8, 2, 8); });
    // granice
    bounds().forEach(function (b) {
      var est = b[1] < ed.tracks.length && ed.tracks[b[1]].from === 'estimate';
      c.strokeStyle = est ? col('--warn') : col('--rec'); c.lineWidth = 2;
      c.beginPath(); c.moveTo(X(b[0]), 0); c.lineTo(X(b[0]), h); c.stroke();
      if (b[1] < ed.tracks.length) {
        c.fillStyle = col('--fg'); c.font = '11px system-ui'; c.fillText(String(b[1] + 1), X(b[0]) + 3, 12);
      }
    });
    if (ed.cursor !== null) {
      c.strokeStyle = col('--fg'); c.lineWidth = 1; c.setLineDash([3, 3]);
      c.beginPath(); c.moveTo(X(ed.cursor), 0); c.lineTo(X(ed.cursor), h); c.stroke(); c.setLineDash([]);
    }
    $('ed-cursor').textContent = ed.cursor !== null ? fmtPrec(ed.cursor / ed.data.rate) : '';
  }

  function evX(e) { var r = $('wave').getBoundingClientRect(); return (e.clientX - r.left) / r.width * ed.data.frames; }

  function nearestBound(f) {
    var px = ed.data.frames / parseFloat($('wave').style.width);
    var best = null;
    bounds().forEach(function (b) { var d = Math.abs(b[0] - f) / px; if (d <= HIT && (!best || d < best.d)) best = { d: d, k: b[1] }; });
    return best;
  }

  function setBound(k, f) {
    var tr = ed.tracks, n = tr.length, gap = Math.round(ed.data.rate * 0.1);
    if (k === 0) { tr[0].start = Math.max(0, Math.min(f, tr[0].end - gap)); return; }
    if (k === n) { tr[n - 1].end = Math.min(ed.data.frames, Math.max(f, tr[n - 1].start + gap)); return; }
    f = Math.max(tr[k - 1].start + gap, Math.min(f, tr[k].end - gap));
    tr[k - 1].end = f; tr[k].start = f; tr[k].from = 'user';
  }

  $('wave').addEventListener('pointerdown', function (e) {
    if (!ed) return;
    var f = evX(e), nb = nearestBound(f);
    if (nb) { ed.drag = nb.k; $('wave').setPointerCapture(e.pointerId); }
    else {
      ed.cursor = Math.round(f);
      ed.tracks.forEach(function (tr, i) { if (f >= tr.start && f < tr.end) ed.sel = i; });
      drawEd(); renderTracks();
    }
  });
  $('wave').addEventListener('pointermove', function (e) {
    if (!ed) return;
    if (ed.drag === undefined || ed.drag === null) {
      $('wave').style.cursor = nearestBound(evX(e)) ? 'ew-resize' : 'crosshair';
      return;
    }
    setBound(ed.drag, Math.round(evX(e)));
    drawEd();
  });
  $('wave').addEventListener('pointerup', function () { if (ed && ed.drag !== null && ed.drag !== undefined) { ed.drag = null; renderTracks(); } });

  function renderTracks() {
    var tb = $('ed-tracks');
    tb.innerHTML = '';
    var rate = ed.data.rate;
    ed.tracks.forEach(function (tr, i) {
      var row = document.createElement('tr');
      if (!tr.keep) row.className = 'off';
      if (i === ed.sel) row.className += ' sel';
      var td = function (cls) { var d = document.createElement('td'); if (cls) d.className = cls; row.appendChild(d); return d; };
      td('num').textContent = i + 1;
      var cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = tr.keep;
      cb.onchange = function () { tr.keep = cb.checked; renderTracks(); drawEd(); };
      td().appendChild(cb);
      var st = td('num'); st.textContent = fmtPrec(tr.start / rate);
      if (tr.from === 'estimate') { st.className += ' est'; st.title = t('UI_ESTIMATE'); }
      td('num').textContent = fmtPrec((tr.end - tr.start) / rate);
      var inp = document.createElement('input'); inp.type = 'text'; inp.value = tr.title || '';
      inp.oninput = function () { tr.title = inp.value; };
      inp.onfocus = function () { ed.sel = i; drawEd(); };
      td().appendChild(inp);
      var act = td('num');
      var pl = document.createElement('button'); pl.className = 'ghost icon'; pl.textContent = '▶'; pl.title = t('UI_LISTEN');
      pl.onclick = function () {
        ed.sel = i; drawEd();
        rpc($('player').value, ['audioin', 'preview', 'id:' + ed.sid, 'take:' + ed.take, 'frame:' + tr.start]).then(function (r) { msg(r.error ? errText(r) : ''); });
      };
      act.appendChild(pl);
      if (i > 0) {
        var mg = document.createElement('button'); mg.className = 'ghost icon'; mg.textContent = '⤒'; mg.title = t('UI_MERGE');
        mg.onclick = function () { ed.tracks[i - 1].end = tr.end; ed.tracks.splice(i, 1); ed.sel = i - 1; renderTracks(); drawEd(); };
        act.appendChild(mg);
      }
      tb.appendChild(row);
    });
  }

  function saveTracks() {
    var payload = ed.tracks.map(function (tr) { return { start: tr.start, end: tr.end, title: tr.title, keep: tr.keep ? 1 : 0, from: tr.from, mbid: tr.mbid, artist: tr.artist }; });
    return rpc('', ['audioin', 'tracks', 'id:' + ed.sid, 'take:' + ed.take, 'tracks:' + JSON.stringify(payload)]).then(function (r) {
      msg(r.error ? errText(r) : '');
      return !r.error;
    });
  }

  $('ed-close').onclick = function () { $('editor').hidden = true; ed = null; };
  $('ed-zoom-in').onclick = function () { if (ed) { ed.zoom = Math.min(64, ed.zoom * 2); drawEd(); } };
  $('ed-zoom-out').onclick = function () { if (ed) { ed.zoom = Math.max(1, ed.zoom / 2); drawEd(); } };
  $('ed-add').onclick = function () {
    if (!ed || ed.cursor === null) return;
    var f = ed.cursor, gap = Math.round(ed.data.rate * 0.1);
    for (var i = 0; i < ed.tracks.length; i++) {
      var tr = ed.tracks[i];
      if (f > tr.start + gap && f < tr.end - gap) {
        ed.tracks.splice(i + 1, 0, { start: f, end: tr.end, title: '', keep: true, from: 'user' });
        tr.end = f; ed.sel = i + 1;
        break;
      }
    }
    renderTracks(); drawEd();
  };
  $('ed-analyze').onclick = function () {
    if (!ed) return;
    var sid = ed.sid, take = ed.take;
    rpc('', ['audioin', 'analyze', 'id:' + sid, 'take:' + take]).then(function (r) {
      if (r.error) { msg(errText(r)); return; }
      openEditor(sid, take);
    });
  };
  $('ed-save').onclick = function () { if (ed) saveTracks().then(function (ok) { if (ok) msg(''); $('ed-export-info').textContent = ok ? t('UI_SAVED') : ''; }); };
  $('ed-export').onclick = function () {
    if (!ed) return;
    var sid = ed.sid;
    saveTracks().then(function (ok) {
      if (!ok) return;
      rpc('', ['audioin', 'export', 'id:' + sid]).then(function (r) { msg(r.error ? errText(r) : ''); refresh(); });
    });
  };
  window.addEventListener('resize', function () { if (ed) drawEd(); });

  function renderExport(x) {
    var el = $('ed-export-info');
    if (!x) return;
    if (x.running) el.textContent = t('UI_EXPORTING') + ' ' + x.done + '/' + x.total + (x.title ? ' · ' + x.title : '');
    else if (x.ok) el.textContent = t('UI_EXPORTED') + ' ' + x.dir;
    else if (x.error) el.textContent = t('ERR_FAILED') + ' (' + x.error + ')';
  }

  loadPlayers();
  loadSessions();
  refresh();
})();
