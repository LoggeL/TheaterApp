/* Premiere · Animation „Vom Drehbuch zur Karte“
 * Klassisches Script (kein ES-Modul, läuft über file://), keine Abhängigkeiten.
 * API: TCGAnim.pipeline(host, opts) → { play, showEnd, stepMode, next, reset, destroy }
 *   host  Element oder CSS-Selektor; der Inhalt wird ersetzt
 *   opts.assets         Pfad-Präfix der Bilder (Standard 'tcg-gameplan-assets/')
 *   opts.autoplay       false = nicht per IntersectionObserver starten (Standard true)
 *   opts.reducedMotion  true/false erzwingt den Modus (Standard: prefers-reduced-motion)
 *   opts.frame          false = ohne eigenen Rahmen/Hintergrund
 * Benötigt die Kartenklassen der Seite (.tcg, .in, .top, …) und die Farb-Tokens auf :root.
 */
(function () {
  'use strict';
  var TCGAnim = window.TCGAnim = window.TCGAnim || {};

  var CSS = [
    '.tcgp-root{container:tcgp/inline-size;position:relative;color:var(--ink);font:15px/1.5 Inter,system-ui,sans-serif;background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:18px;box-shadow:var(--shadow);overflow:clip}',
    '.tcgp-root.tcgp-bare{background:none;border:0;box-shadow:none;padding:0}',
    '.tcgp-root *,.tcgp-root *::before,.tcgp-root *::after{box-sizing:border-box}',
    '.tcgp-sr{position:absolute;width:1px;height:1px;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}',
    '.tcgp-stage{display:grid;grid-template-columns:minmax(0,1.12fr) 40px minmax(0,1fr) 40px minmax(0,1fr);align-items:stretch}',
    '.tcgp-st{min-width:0;background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:14px;transition:border-color .35s,box-shadow .35s}',
    '.tcgp-st.tcgp-act{border-color:var(--gold);box-shadow:0 0 0 3px color-mix(in srgb,var(--gold) 22%,transparent)}',
    '.tcgp-h{display:flex;align-items:center;gap:8px;margin:0 0 10px;font:700 .74rem/1.2 Inter,system-ui,sans-serif;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}',
    '.tcgp-h i{font-style:normal;flex:none;display:grid;place-items:center;width:20px;height:20px;border-radius:50%;background:var(--curtain);color:var(--bg);font-size:.7rem;letter-spacing:0}',
    /* Station 1: Drehbuch */
    '.tcgp-script{font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--surface);border:1px solid var(--line);border-left:3px double var(--line);border-radius:8px;padding:10px 10px 10px 12px;overflow-wrap:anywhere}',
    '.tcgp-scene{font-weight:700;letter-spacing:.14em;border-bottom:1px solid var(--line);padding:0 0 4px 6px;margin-bottom:6px}',
    '.tcgp-l{padding:3px 6px;margin:2px 0;border-left:3px solid transparent;border-radius:4px;transition:background-color .4s,border-color .4s,opacity .4s}',
    '.tcgp-sp{font-weight:700}',
    '.tcgp-dir{font-style:italic;color:var(--muted)}',
    '.tcgp-dir>span{background:linear-gradient(var(--curtain),var(--curtain)) no-repeat 0 58%/0% 1.5px;-webkit-box-decoration-break:clone;box-decoration-break:clone;transition:background-size .55s ease}',
    '.tcgp-dir em{display:inline-block;margin-left:6px;padding:0 6px;border:1px solid currentColor;border-radius:999px;font:700 .6rem/1.5 Inter,system-ui,sans-serif;letter-spacing:.05em;text-transform:uppercase;font-style:normal;color:var(--curtain);white-space:nowrap;opacity:0;transform:translateX(-4px);transition:opacity .3s .3s,transform .3s .3s}',
    '.tcgp-dir.tcgp-x>span{background-size:100% 1.5px}',
    '.tcgp-dir.tcgp-x em{opacity:1;transform:none}',
    '.tcgp-lucy.tcgp-on{background:var(--gold-soft);border-left-color:var(--gold)}',
    '.tcgp-lucy.tcgp-on .tcgp-sp{color:var(--curtain)}',
    '.tcgp-other.tcgp-dim{opacity:.45}',
    '.tcgp-foot{margin:8px 0 0;font-size:.74rem;line-height:1.4;color:var(--muted)}',
    /* Verbinder */
    '.tcgp-con{position:relative;align-self:center;width:100%;height:24px}',
    '.tcgp-con::before{content:"";position:absolute;left:6px;right:11px;top:11px;border-top:2px dashed var(--line);transition:border-color .3s}',
    '.tcgp-con::after{content:"";position:absolute;right:4px;top:6px;border:6px solid transparent;border-left:8px solid var(--line);border-right:0;transition:border-color .3s}',
    '.tcgp-con.tcgp-on::before,.tcgp-con.tcgp-done::before{border-top-color:var(--gold)}',
    '.tcgp-con.tcgp-on::after,.tcgp-con.tcgp-done::after{border-left-color:var(--gold)}',
    '.tcgp-con span{position:absolute;left:3px;top:8px;width:8px;height:8px;border-radius:50%;background:var(--curtain);opacity:0}',
    '.tcgp-con.tcgp-on span{animation:tcgp-flow .9s linear infinite}',
    '.tcgp-con.tcgp-on span:nth-child(2){animation-delay:.3s}.tcgp-con.tcgp-on span:nth-child(3){animation-delay:.6s}',
    '@keyframes tcgp-flow{0%{opacity:0;transform:translateX(0)}20%,75%{opacity:1}100%{opacity:0;transform:translateX(24px)}}',
    '@keyframes tcgp-flowv{0%{opacity:0;transform:translateY(0)}20%,75%{opacity:1}100%{opacity:0;transform:translateY(22px)}}',
    /* Station 2: Kennzahlen */
    '.tcgp-stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(86px,1fr));gap:6px}',
    '.tcgp-stat{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:7px 9px;min-width:0}',
    '.tcgp-stat b{display:block;font:900 1.35rem/1.15 Fraunces,Georgia,serif;font-variant-numeric:tabular-nums;white-space:nowrap}',
    '.tcgp-stat small{display:block;font-size:.72rem;line-height:1.3;color:var(--muted)}',
    '.tcgp-wpl{margin-top:10px;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:8px 10px}',
    '.tcgp-wpl-h{font-size:.74rem;font-weight:700;color:var(--muted);margin-bottom:4px}',
    '.tcgp-bar{display:grid;grid-template-columns:52px minmax(0,1fr) 36px;align-items:center;gap:8px;font-size:.78rem;margin:3px 0}',
    '.tcgp-bar i{display:block;height:10px;border-radius:5px;background:var(--bg2);overflow:hidden}',
    '.tcgp-bar i::before{content:"";display:block;height:100%;width:0;border-radius:inherit;background:var(--curtain);transition:width 1.4s cubic-bezier(.2,.8,.2,1)}',
    '.tcgp-bar.tcgp-med i::before{background:var(--muted)}',
    '.tcgp-wpl.tcgp-on .tcgp-bar i::before{width:var(--w)}',
    '.tcgp-bar b{font-variant-numeric:tabular-nums;text-align:right}',
    '.tcgp-delta{font-size:.72rem;color:var(--curtain);font-weight:700;opacity:0;transition:opacity .4s 1.2s}',
    '.tcgp-wpl.tcgp-on .tcgp-delta{opacity:1}',
    /* Station 3: Formel → Karte */
    '.tcgp-chips{list-style:none;margin:0 0 12px;padding:0;display:flex;flex-wrap:wrap;gap:5px}',
    '.tcgp-chips li{margin:0;padding:3px 9px;border:1px solid var(--line);border-radius:999px;background:var(--surface);font:600 .72rem/1.35 Inter,system-ui,sans-serif;opacity:0;transform:translateY(6px) scale(.96);transition:opacity .35s,transform .35s cubic-bezier(.2,1.4,.4,1),background-color .3s,border-color .3s}',
    '.tcgp-chips li b{color:var(--curtain)}',
    '.tcgp-chips li.tcgp-on{opacity:1;transform:none}',
    '.tcgp-chips li.tcgp-hit{border-color:var(--gold);background:var(--gold-soft)}',
    '.tcgp-cardwrap{position:relative;width:min(210px,100%);margin:0 auto}',
    '.tcgp-slot{aspect-ratio:63/88;border:2px dashed var(--line);border-radius:14px;display:grid;place-items:center;color:var(--muted);font-size:.78rem}',
    '.tcgp-card .tcg{position:absolute;inset:0;aspect-ratio:auto;opacity:0;transform:scale(.9) translateY(8px);transition:opacity .45s,transform .5s cubic-bezier(.2,1.3,.4,1),box-shadow .6s}',
    '.tcgp-card.f-frame .tcg,.tcgp-card.f-frame .tcg:hover{opacity:1;transform:none}',
    '.tcgp-card .art img{opacity:0;transform:scale(1.08);transition:opacity .7s,transform 1.2s}',
    '.tcgp-card .art.has-img::after{opacity:0;transition:opacity .4s .4s}',
    '.tcgp-card.f-art .art img{opacity:1;transform:none}',
    '.tcgp-card.f-art .art.has-img::after{opacity:1}',
    '.tcgp-card .cost,.tcgp-card .pt{transform:scale(0);transition:transform .45s cubic-bezier(.2,1.6,.4,1)}',
    '.tcgp-card.f-cost .cost,.tcgp-card.f-pt .pt{transform:none}',
    '.tcgp-card .type>span:first-child,.tcgp-card .fl{opacity:0;transition:opacity .4s}',
    '.tcgp-card.f-type .type>span:first-child,.tcgp-card.f-type .fl{opacity:1}',
    '.tcgp-card .rar{transform:scale(0) rotate(-90deg);transition:transform .5s cubic-bezier(.2,1.6,.4,1)}',
    '.tcgp-card.f-rar .rar{transform:none}',
    '.tcgp-kw{display:inline-block;opacity:0;transform:translateX(-6px);transition:opacity .4s,transform .4s}',
    '.tcgp-card.f-kw1 .tcgp-kw1,.tcgp-card.f-kw2 .tcgp-kw2{opacity:1;transform:none}',
    '.tcgp-shine{position:absolute;inset:0;border-radius:14px;overflow:hidden;pointer-events:none;z-index:2}',
    '.tcgp-shine::before{content:"";position:absolute;top:-20%;bottom:-20%;left:-70%;width:45%;background:linear-gradient(100deg,transparent,rgba(255,255,255,.75),transparent);transform:skewX(-14deg);opacity:0}',
    '.tcgp-card.f-shine .tcgp-shine::before{animation:tcgp-shine 1.2s ease-out}',
    '.tcgp-card.f-shine .tcg{box-shadow:0 0 0 2px var(--gold),0 10px 30px color-mix(in srgb,var(--gold) 45%,transparent)}',
    '@keyframes tcgp-shine{0%{left:-70%;opacity:1}100%{left:130%;opacity:1}}',
    /* Steuerung */
    '.tcgp-ctl{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:14px}',
    '.tcgp-btn{font:600 .84rem/1 Inter,system-ui,sans-serif;color:var(--ink);background:var(--surface);border:1px solid var(--line);border-radius:999px;padding:8px 14px;cursor:pointer;min-height:36px}',
    '.tcgp-btn:hover{background:var(--bg2)}',
    '.tcgp-btn:focus-visible{outline:2px solid var(--curtain);outline-offset:2px}',
    '.tcgp-btn[hidden]{display:none}',
    '.tcgp-status{font-size:.8rem;color:var(--muted)}',
    /* schmal: untereinander */
    '@container tcgp (max-width:820px){',
    '.tcgp-stage{grid-template-columns:minmax(0,1fr)}',
    '.tcgp-con{width:24px;height:38px;justify-self:center}',
    '.tcgp-con::before{left:11px;right:auto;top:4px;bottom:11px;border-top:0;border-left:2px dashed var(--line)}',
    '.tcgp-con.tcgp-on::before,.tcgp-con.tcgp-done::before{border-left-color:var(--gold)}',
    '.tcgp-con::after{right:auto;left:6px;top:auto;bottom:3px;border:6px solid transparent;border-top:8px solid var(--line);border-bottom:0}',
    '.tcgp-con.tcgp-on::after,.tcgp-con.tcgp-done::after{border-top-color:var(--gold);border-left-color:transparent}',
    '.tcgp-con span{left:8px;top:2px}',
    '.tcgp-con.tcgp-on span{animation-name:tcgp-flowv}',
    '}',
    '@container tcgp (max-width:400px){.tcgp-root:not(.tcgp-bare){padding:12px}.tcgp-st{padding:10px}}',
    '.tcgp-rm *,.tcgp-rm *::before,.tcgp-rm *::after{transition:none!important;animation:none!important}',
    '@media (prefers-reduced-motion:reduce){.tcgp-root *,.tcgp-root *::before,.tcgp-root *::after{transition:none!important;animation:none!important}}'
  ].join('\n');

  function injectCSS() {
    if (document.getElementById('tcgp-style')) return;
    var s = document.createElement('style');
    s.id = 'tcgp-style';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }
  function prefersReduced() {
    return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }
  function fmt(v, dec) {
    return v.toLocaleString('de-DE', { minimumFractionDigits: dec, maximumFractionDigits: dec });
  }

  /* frei erfundener, neutraler Probenskript-Ausschnitt */
  var SCRIPT = [
    ['dir', '(Dachboden. Nacht. LUCY tritt mit einer Taschenlampe auf.)'],
    ['lucy', 'LUCY (MIKRO 2):', 'Hier oben war seit Jahren niemand mehr.'],
    ['other', 'CLARA (MIKRO 5):', 'Dann wird es Zeit, dass jemand nachsieht.'],
    ['dir', '(Ein Knarren. Beide bleiben stehen.)'],
    ['lucy', 'LUCY (MIKRO 2):', 'Wenn das der Wind war, trägt er schwere Schuhe.'],
    ['dir', '(Sie leuchtet in die dunkle Ecke.)'],
    ['lucy', 'LUCY (MIKRO 2):', 'Bleib hinter mir und zähl langsam bis zehn.']
  ];
  var STATS = [
    { to: 152, label: 'Zeilen' },
    { to: 2089, label: 'Wörter' },
    { to: 17.8, dec: 1, suf: ' %', label: 'Textanteil' },
    { to: 10, label: 'Szenen' },
    { to: 2, label: 'Monologe' },
    { from: 24, to: 1, suf: '/24', label: 'Rang' }
  ];
  var CHIPS = [
    'Rang 1 → <b>Mythic</b>',
    '17,8 % → <b>Kosten 6</b>',
    'Budget 2×6+1−2 = <b>11</b>',
    '13,7 &gt; 9,9 → mehr Angriff → <b>7/4</b>',
    '10 Szenen → <b>Rampensau</b>',
    '2 lange Reden → <b>Monolog</b>'
  ];
  var STAGES = ['Drehbuch', 'Kennzahlen', 'Regeln', 'Karte'];
  var SUMMARY = 'Aus einem Drehbuch-Ausschnitt werden nur Lucys Sprechzeilen gezählt, Regieanweisungen in Klammern zählen nicht. ' +
    'Kennzahlen: 152 Zeilen, 2.089 Wörter, 17,8 % Textanteil, 10 Szenen, 2 Monologe, Rang 1 von 24, 13,7 Wörter pro Zeile gegenüber einem Median von 9,9. ' +
    'Regeln: Rang 1 ergibt Mythic. 17,8 % ergibt Kosten 6. Budget 2×6+1−2 = 11. 13,7 liegt über 9,9, also mehr Angriff: 7/4. 10 Szenen ergeben Rampensau. 2 lange Reden ergeben Monolog. ' +
    'Ergebnis: Karte Lucy, Kosten 6, Rolle – Hauptrolle, Mythic, Rampensau und Monolog, Werte 7/4.';

  function markup(A) {
    var lines = SCRIPT.map(function (l) {
      if (l[0] === 'dir') return '<div class="tcgp-l tcgp-dir"><span>' + l[1] + '</span><em>zählt nicht</em></div>';
      return '<div class="tcgp-l tcgp-' + l[0] + '"><span class="tcgp-sp">' + l[1] + '</span> ' + l[2] + '</div>';
    }).join('');
    var stats = STATS.map(function (s) {
      return '<div class="tcgp-stat"><b data-from="' + (s.from || 0) + '" data-to="' + s.to + '" data-dec="' + (s.dec || 0) + '" data-suf="' + (s.suf || '') + '"></b><small>' + s.label + '</small></div>';
    }).join('');
    var chips = CHIPS.map(function (c) { return '<li>' + c + '</li>'; }).join('');
    return '' +
      '<p class="tcgp-sr">' + SUMMARY + '</p>' +
      '<div class="tcgp-stage" aria-hidden="true">' +
        '<div class="tcgp-st tcgp-st1"><div class="tcgp-h"><i>1</i>Drehbuch</div>' +
          '<div class="tcgp-script"><div class="tcgp-scene">SZENE 4</div>' + lines + '</div>' +
          '<p class="tcgp-foot">Gezählt werden nur Lucys Sprechzeilen. Regie in Klammern fällt raus.</p></div>' +
        '<div class="tcgp-con"><span></span><span></span><span></span></div>' +
        '<div class="tcgp-st tcgp-st2"><div class="tcgp-h"><i>2</i>Kennzahlen</div>' +
          '<div class="tcgp-stats">' + stats + '</div>' +
          '<div class="tcgp-wpl"><div class="tcgp-wpl-h">Wörter pro Zeile</div>' +
            '<div class="tcgp-bar"><span>Lucy</span><i style="--w:' + (13.7 / 15 * 100).toFixed(1) + '%"></i><b data-from="0" data-to="13.7" data-dec="1" data-suf=""></b></div>' +
            '<div class="tcgp-bar tcgp-med"><span>Median</span><i style="--w:' + (9.9 / 15 * 100).toFixed(1) + '%"></i><b data-from="0" data-to="9.9" data-dec="1" data-suf=""></b></div>' +
            '<div class="tcgp-delta">+38 % über dem Median</div></div></div>' +
        '<div class="tcgp-con"><span></span><span></span><span></span></div>' +
        '<div class="tcgp-st tcgp-st3"><div class="tcgp-h"><i>3</i>Formel → Karte</div>' +
          '<ul class="tcgp-chips">' + chips + '</ul>' +
          '<div class="tcgp-cardwrap tcgp-card"><div class="tcgp-slot">Karte</div>' +
            '<div class="tcg creep">' +
              '<div class="in">' +
                '<div class="top"><span class="nm">Lucy</span><span class="cost">6</span></div>' +
                '<div class="art has-img"><img src="' + A + 'rolle-lucy.webp" alt=""></div>' +
                '<div class="type"><span>Rolle – Hauptrolle</span><span class="rar M" title="Mythic">M</span></div>' +
                '<div class="txt"><span class="tcgp-kw tcgp-kw1"><b>Rampensau</b> <span class="rem">(greift an, ohne sich zu erschöpfen)</span></span><br>' +
                  '<span class="tcgp-kw tcgp-kw2"><b>Monolog</b> — 1 Applaus: 1 Schaden an einem Ziel. Nur 1× pro Zug.</span>' +
                  '<div class="fl">Creepshow · Sommerstück 2026</div></div>' +
              '</div>' +
              '<div class="pt">7/4</div>' +
              '<span class="tcgp-shine"></span>' +
            '</div>' +
          '</div></div>' +
      '</div>' +
      '<div class="tcgp-ctl">' +
        '<button type="button" class="tcgp-btn tcgp-again">Nochmal</button>' +
        '<button type="button" class="tcgp-btn tcgp-steps" hidden>Schritt für Schritt</button>' +
        '<span class="tcgp-status" role="status" aria-live="polite"></span>' +
      '</div>';
  }

  TCGAnim.pipeline = function (host, opts) {
    if (typeof host === 'string') host = document.querySelector(host);
    if (!host) throw new Error('TCGAnim.pipeline: host fehlt');
    opts = opts || {};
    var A = opts.assets != null ? opts.assets : 'tcg-gameplan-assets/';
    var reduced = opts.reducedMotion != null ? !!opts.reducedMotion : prefersReduced();
    injectCSS();

    var root = document.createElement('div');
    root.className = 'tcgp-root' + (reduced ? ' tcgp-rm' : '') + (opts.frame === false ? ' tcgp-bare' : '');
    root.setAttribute('role', 'group');
    root.setAttribute('aria-label', 'Animation: Vom Drehbuch zur Karte');
    root.innerHTML = markup(A);
    host.innerHTML = '';
    host.appendChild(root);

    function q(s) { return root.querySelector(s); }
    function qa(s) { return Array.prototype.slice.call(root.querySelectorAll(s)); }
    var st = qa('.tcgp-st'), cons = qa('.tcgp-con'), lines = qa('.tcgp-l'), chips = qa('.tcgp-chips li');
    var card = q('.tcgp-card'), wpl = q('.tcgp-wpl');
    var nums = qa('.tcgp-stat b'), barNums = qa('.tcgp-bar b');
    var btnAgain = q('.tcgp-again'), btnSteps = q('.tcgp-steps'), status = q('.tcgp-status');

    var gen = 0, timers = [], stepIdx = -1, started = false, io = null;

    function cls(el, c, on) { el.classList.toggle(c, on !== false); }
    function active(i) { st.forEach(function (s, k) { cls(s, 'tcgp-act', k === i); }); }
    function setNum(el, v) { el.textContent = fmt(v, +el.dataset.dec) + el.dataset.suf; }
    function count(el, instant, dur) {
      var from = +el.dataset.from, to = +el.dataset.to;
      if (instant) return setNum(el, to);
      /* setTimeout statt rAF: läuft auch in Hintergrund-Tabs und Headless-Tests sicher bis zum Endwert */
      var g = gen, t0 = Date.now();
      dur = dur || 1500;
      (function tick() {
        if (g !== gen) return;
        var p = Math.min(1, Math.max(0, (Date.now() - t0) / dur));
        setNum(el, from + (to - from) * (1 - Math.pow(1 - p, 3)));
        if (p < 1) timers.push(setTimeout(tick, 33));
      })();
    }
    function hit(i, instant) {
      var c = chips[i];
      if (instant) return;
      cls(c, 'tcgp-hit');
      var g = gen;
      timers.push(setTimeout(function () { if (g === gen) cls(c, 'tcgp-hit', false); }, 900));
    }

    /* Aktionen: [Zeitpunkt ms, Stufe, fn(instant)] */
    var ACT = [];
    function at(t, stage, fn) { ACT.push([t, stage, fn]); }
    at(0, 0, function () { active(0); });
    lines.forEach(function (l, i) {
      at(450 + i * 480, 0, function () {
        if (l.classList.contains('tcgp-lucy')) cls(l, 'tcgp-on');
        else if (l.classList.contains('tcgp-dir')) cls(l, 'tcgp-x');
        else cls(l, 'tcgp-dim');
      });
    });
    var T1 = 450 + lines.length * 480;
    at(T1, 1, function (inst) { cls(cons[0], inst ? 'tcgp-done' : 'tcgp-on'); });
    at(T1 + 650, 1, function (inst) { cls(cons[0], 'tcgp-on', false); cls(cons[0], 'tcgp-done'); active(1); nums.forEach(function (n) { count(n, inst); }); });
    at(T1 + 1100, 1, function (inst) { cls(wpl, 'tcgp-on'); barNums.forEach(function (n) { count(n, inst, 1400); }); });
    var T2 = T1 + 2700;
    at(T2, 2, function (inst) { cls(cons[1], inst ? 'tcgp-done' : 'tcgp-on'); });
    at(T2 + 650, 2, function () { cls(cons[1], 'tcgp-on', false); cls(cons[1], 'tcgp-done'); active(2); });
    chips.forEach(function (c, i) { at(T2 + 650 + i * 450, 2, function () { cls(c, 'tcgp-on'); }); });
    var T3 = T2 + 650 + chips.length * 450 + 350;
    var parts = [['f-frame'], ['f-art'], ['f-cost', 1], ['f-type'], ['f-kw1', 4], ['f-kw2', 5], ['f-pt', 3], ['f-rar', 0]];
    parts.forEach(function (p, i) {
      at(T3 + i * 360, 3, function (inst) { if (i === 0) active(2); cls(card, p[0]); if (p[1] != null) { hit(p[1], inst); if (p[1] === 3) hit(2, inst); } });
    });
    var T4 = T3 + parts.length * 360 + 250;
    at(T4, 3, function (inst) { if (!inst) cls(card, 'f-shine'); });
    at(T4 + 1300, 3, function () { active(-1); });

    function reset() {
      gen++;
      timers.forEach(clearTimeout);
      timers = [];
      active(-1);
      cons.forEach(function (c) { c.classList.remove('tcgp-on', 'tcgp-done'); });
      lines.forEach(function (l) { l.classList.remove('tcgp-on', 'tcgp-x', 'tcgp-dim'); });
      chips.forEach(function (c) { c.classList.remove('tcgp-on', 'tcgp-hit'); });
      wpl.classList.remove('tcgp-on');
      card.className = 'tcgp-cardwrap tcgp-card';
      nums.concat(barNums).forEach(function (n) { setNum(n, +n.dataset.from); });
      stepIdx = -1;
      btnSteps.textContent = 'Schritt für Schritt';
      status.textContent = '';
    }
    function play() {
      started = true;
      reset();
      var g = gen;
      ACT.forEach(function (a) {
        timers.push(setTimeout(function () { if (g === gen) a[2](false); }, a[0]));
      });
    }
    function showEnd() {
      started = true;
      reset();
      ACT.forEach(function (a) { a[2](true); });
    }
    function stepMode() {
      started = true;
      reset();
      stepIdx = 0;
      btnSteps.textContent = 'Weiter (1/' + STAGES.length + ')';
      status.textContent = 'Schritt für Schritt: noch leer. „Weiter“ zeigt ' + STAGES[0] + '.';
    }
    function next() {
      if (stepIdx < 0 || stepIdx >= STAGES.length) return stepMode();
      var s = stepIdx;
      ACT.forEach(function (a) { if (a[1] === s) a[2](true); });
      if (s === STAGES.length - 1) active(2);
      stepIdx++;
      status.textContent = 'Schritt ' + (s + 1) + ' von ' + STAGES.length + ': ' + STAGES[s] + '.';
      btnSteps.textContent = stepIdx < STAGES.length ? 'Weiter (' + (stepIdx + 1) + '/' + STAGES.length + ')' : 'Schritt für Schritt';
      if (stepIdx >= STAGES.length) stepIdx = -1;
    }

    btnAgain.addEventListener('click', function () { reduced ? showEnd() : play(); });
    btnSteps.addEventListener('click', function () { stepIdx < 0 ? stepMode() : next(); });
    if (reduced) {
      btnSteps.hidden = false;
      btnAgain.textContent = 'Endzustand';
      showEnd();
    } else if (opts.autoplay !== false) {
      if ('IntersectionObserver' in window) {
        io = new IntersectionObserver(function (es) {
          es.forEach(function (e) {
            if (!e.isIntersecting || started) return;
            var vh = e.rootBounds ? e.rootBounds.height : window.innerHeight;
            /* 40 % sichtbar oder, bei sehr hohen Hosts, 40 % des Viewports gefüllt */
            if (e.intersectionRatio >= 0.4 || e.intersectionRect.height >= vh * 0.4) {
              play();
              io.disconnect();
            }
          });
        }, { threshold: [0, 0.1, 0.2, 0.3, 0.4, 0.6] });
        io.observe(root);
      } else {
        play();
      }
    }

    return {
      root: root,
      play: play,
      showEnd: showEnd,
      stepMode: stepMode,
      next: next,
      reset: reset,
      destroy: function () {
        reset();
        if (io) io.disconnect();
        if (root.parentNode) root.parentNode.removeChild(root);
      }
    };
  };
})();
