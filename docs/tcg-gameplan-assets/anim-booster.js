/* Premiere · Animation „Booster öffnen“
 * Klassisches Script (kein ES-Modul, läuft über file://), keine Abhängigkeiten.
 * API: TCGAnim.booster(host, opts) → { open, again, reset, destroy }
 *   host  Element oder CSS-Selektor; der Inhalt wird ersetzt
 *   opts.assets         Pfad-Präfix der Bilder (Standard 'tcg-gameplan-assets/')
 *   opts.reducedMotion  true/false erzwingt den Modus (Standard: prefers-reduced-motion)
 *   opts.foilChance     Wahrscheinlichkeit für 1 Foil-Karte je Booster (Standard 1/3, Demo)
 *   opts.random         eigene Zufallsfunktion () → [0,1) für Tests (Standard crypto.getRandomValues)
 *   opts.foil           Testhilfe: Index 0–4 erzwingt Foil an dieser Stelle, -1 = keine
 *   opts.frame          false = ohne eigenen Rahmen/Hintergrund
 * Das Päckchen kommt aus <assets>booster-pack.webp, falls die Datei existiert, sonst aus CSS.
 * Designregel: keine Walze, kein Beinahe-Treffer. Alle Karten drehen sich im gleichen Takt um.
 */
(function () {
  'use strict';
  var TCGAnim = window.TCGAnim = window.TCGAnim || {};

  var CSS = [
    '.tcgb-root{container:tcgb/inline-size;position:relative;color:var(--ink);font:15px/1.5 Inter,system-ui,sans-serif;background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:16px;box-shadow:var(--shadow);overflow:clip}',
    '.tcgb-root.tcgb-bare{background:none;border:0;box-shadow:none;padding:0}',
    '.tcgb-root *,.tcgb-root *::before,.tcgb-root *::after{box-sizing:border-box}',
    '.tcgb-stage{position:relative;width:100%;height:360px;border-radius:12px;background:radial-gradient(ellipse 60% 70% at 50% 45%,color-mix(in srgb,var(--gold) 16%,transparent),transparent 70%),var(--bg);border:1px solid var(--line)}',
    /* Päckchen */
    '.tcgb-pack{position:absolute;left:0;top:0;cursor:pointer;z-index:3;filter:drop-shadow(0 12px 16px rgba(0,0,0,.28));transition:opacity .5s,transform .6s cubic-bezier(.4,0,.6,1);opacity:0}',
    '.tcgb-pack.tcgb-ready{opacity:1}',
    '.tcgb-float{position:absolute;inset:0}',
    '.tcgb-pack.tcgb-idle .tcgb-float{animation:tcgb-float 3.4s ease-in-out infinite}',
    '.tcgb-pack.tcgb-idle:hover .tcgb-float{animation-duration:1.8s}',
    '@keyframes tcgb-float{0%,100%{transform:translateY(0) rotate(-1.6deg)}50%{transform:translateY(-9px) rotate(1.6deg)}}',
    '.tcgb-pack.tcgb-shake .tcgb-float{animation:tcgb-shake .28s linear}',
    '@keyframes tcgb-shake{0%,100%{transform:none}25%{transform:translateX(-3px) rotate(-1.5deg)}75%{transform:translateX(3px) rotate(1.5deg)}}',
    '.tcgb-pk{position:absolute;inset:0;display:block}',
    '.tcgb-pk img{display:block;width:100%;height:100%;object-fit:contain;user-select:none;-webkit-user-drag:none}',
    '.tcgb-pk-top{transition:transform .7s cubic-bezier(.3,.6,.4,1),opacity .4s .35s;transform-origin:85% 10%}',
    '.tcgb-pack.tcgb-torn .tcgb-pk-top{transform:translate(38%,-85%) rotate(28deg);opacity:0}',
    '.tcgb-pack.tcgb-gone{opacity:0;transform:translateY(40px) scale(.92);pointer-events:none}',
    /* CSS-Päckchen (Fallback) */
    '.tcgb-css{position:absolute;inset:0;border-radius:6px;overflow:hidden;background:linear-gradient(160deg,var(--curtain2),var(--curtain) 45%,color-mix(in srgb,var(--curtain) 55%,#000));color:color-mix(in srgb,var(--gold) 40%,#fff);text-align:center}',
    '.tcgb-css::before{content:"";position:absolute;inset:9% 7%;border:1.5px solid var(--gold);border-radius:4px;box-shadow:inset 0 0 0 3px color-mix(in srgb,var(--gold) 30%,transparent)}',
    '.tcgb-css::after{content:"";position:absolute;inset:0;background:linear-gradient(115deg,transparent 30%,rgba(255,255,255,.22) 42%,transparent 54%);background-size:250% 100%;animation:tcgb-sheen 4.5s ease-in-out infinite}',
    '@keyframes tcgb-sheen{0%,55%{background-position:100% 0}100%{background-position:-60% 0}}',
    '.tcgb-crimp{position:absolute;left:0;right:0;height:7%;background:repeating-linear-gradient(90deg,var(--gold) 0 3px,color-mix(in srgb,var(--gold) 55%,#000) 3px 6px)}',
    '.tcgb-crimp.t{top:0}.tcgb-crimp.b{bottom:0}',
    '.tcgb-css-in{position:absolute;inset:12% 10%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4%}',
    '.tcgb-css-in small{font:700 .55em/1.2 Inter,system-ui,sans-serif;letter-spacing:.14em;text-transform:uppercase;opacity:.9}',
    '.tcgb-css-in strong{font:900 1.65em/1 Fraunces,Georgia,serif;letter-spacing:.02em;color:color-mix(in srgb,var(--gold) 25%,#fff);text-shadow:0 2px 8px rgba(0,0,0,.35)}',
    '.tcgb-css-in em{font:italic 600 .8em/1 Fraunces,Georgia,serif}',
    '.tcgb-emb{width:46%;aspect-ratio:1;border-radius:50%;background-size:cover;background-position:50% 50%;border:2px solid var(--gold);box-shadow:0 0 0 4px color-mix(in srgb,var(--curtain) 60%,#000),0 0 18px color-mix(in srgb,var(--gold) 50%,transparent)}',
    /* Karten */
    '.tcgb-card{position:absolute;left:0;top:0;perspective:1100px;transform-origin:50% 50%;opacity:0;transition:transform .65s cubic-bezier(.2,.9,.25,1.08),opacity .3s;outline:none}',
    '.tcgb-card.tcgb-vis{opacity:1}',
    '.tcgb-card[role=button]{cursor:zoom-in}',
    '.tcgb-card.tcgb-zoom{cursor:zoom-out}',
    '.tcgb-card:focus-visible .tcgb-flip{outline:3px solid var(--curtain);outline-offset:3px;border-radius:calc(14px * var(--s,1))}',
    '.tcgb-flip{position:absolute;inset:0;transform-style:preserve-3d;transition:transform .6s cubic-bezier(.4,.1,.2,1)}',
    '.tcgb-card.tcgb-up .tcgb-flip{transform:rotateY(180deg)}',
    '.tcgb-face{position:absolute;inset:0;-webkit-backface-visibility:hidden;backface-visibility:hidden;border-radius:calc(14px * var(--s,1))}',
    '.tcgb-back{overflow:hidden;background:var(--curtain);box-shadow:0 8px 20px rgba(0,0,0,.3)}',
    '.tcgb-back img{display:block;width:100%;height:100%;object-fit:cover}',
    '.tcgb-front{transform:rotateY(180deg)}',
    '.tcgb-scale{position:absolute;left:0;top:0;width:200px;transform:scale(var(--s,1));transform-origin:0 0}',
    '.tcgb-scale .tcg,.tcgb-scale .tcg:hover{width:200px;transition:none;transform:none}',
    '.tcgb-glowfx{position:absolute;inset:-22%;border-radius:50%;background:radial-gradient(closest-side,color-mix(in srgb,var(--gold) 75%,transparent),color-mix(in srgb,var(--gold) 25%,transparent) 60%,transparent);opacity:0;pointer-events:none;transform:scale(.4)}',
    '.tcgb-card.tcgb-glow .tcgb-glowfx{animation:tcgb-burst 1.4s ease-out forwards}',
    '@keyframes tcgb-burst{0%{opacity:0;transform:scale(.4)}35%{opacity:1;transform:scale(1.15)}100%{opacity:.5;transform:scale(1)}}',
    '.tcgb-card.tcgb-glow .tcgb-front{box-shadow:0 0 0 calc(2px + 1px * var(--s,1)) var(--gold),0 0 28px color-mix(in srgb,var(--gold) 70%,transparent)}',
    '.tcgb-foil{position:absolute;inset:0;border-radius:inherit;pointer-events:none;opacity:0;mix-blend-mode:hard-light;background:linear-gradient(115deg,transparent 22%,color-mix(in srgb,var(--p0) 60%,transparent) 32%,color-mix(in srgb,var(--p1) 60%,transparent) 39%,color-mix(in srgb,var(--gold) 60%,transparent) 46%,color-mix(in srgb,var(--p3) 60%,transparent) 53%,color-mix(in srgb,var(--p2) 60%,transparent) 60%,color-mix(in srgb,var(--creep) 60%,transparent) 67%,transparent 78%);background-size:300% 100%;background-position:100% 0}',
    '.tcgb-card.tcgb-isfoil .tcgb-foil{opacity:.75;animation:tcgb-foil 3.2s ease-in-out infinite}',
    '@keyframes tcgb-foil{0%{background-position:100% 0}65%,100%{background-position:0% 0}}',
    '.tcgb-foiltag{position:absolute;left:50%;top:calc(100% + 6px);transform:translateX(-50%);font:800 .62rem/1 Inter,system-ui,sans-serif;letter-spacing:.12em;text-transform:uppercase;padding:3px 7px;border-radius:999px;color:var(--ink);background:linear-gradient(90deg,color-mix(in srgb,var(--p0) 30%,var(--surface)),color-mix(in srgb,var(--gold) 30%,var(--surface)),color-mix(in srgb,var(--p3) 30%,var(--surface)),color-mix(in srgb,var(--p2) 30%,var(--surface)));border:1px solid var(--line);opacity:0;transition:opacity .4s;white-space:nowrap}',
    '.tcgb-card.tcgb-isfoil .tcgb-foiltag{opacity:1}',
    '.tcgb-card.tcgb-zoom .tcgb-foiltag{opacity:0}',
    '.tcgb-dim{position:absolute;inset:0;border-radius:inherit;background:color-mix(in srgb,var(--bg) 78%,transparent);opacity:0;pointer-events:none;transition:opacity .3s;z-index:40}',
    '.tcgb-dim.tcgb-on{opacity:1;pointer-events:auto;cursor:zoom-out}',
    /* Steuerung */
    '.tcgb-ctl{display:flex;flex-wrap:wrap;align-items:center;gap:8px 12px;margin-top:12px}',
    '.tcgb-btn{font:700 .9rem/1 Inter,system-ui,sans-serif;color:var(--bg);background:var(--curtain);border:1px solid var(--curtain);border-radius:999px;padding:10px 20px;cursor:pointer;min-height:40px}',
    '.tcgb-btn:hover{filter:brightness(1.08)}',
    '.tcgb-btn:disabled{opacity:.55;cursor:default;filter:none}',
    '.tcgb-btn:focus-visible{outline:2px solid var(--ink);outline-offset:2px}',
    '.tcgb-hint{font-size:.8rem;color:var(--muted)}',
    '.tcgb-list{margin:8px 0 0;font-size:.86rem;min-height:1.4em}',
    '.tcgb-list b{font-weight:700}',
    '.tcgb-note{margin:4px 0 0;font-size:.76rem;color:var(--muted)}',
    '@container tcgb (max-width:400px){.tcgb-root:not(.tcgb-bare){padding:12px}}',
    '.tcgb-rm *,.tcgb-rm *::before,.tcgb-rm *::after{transition:none!important;animation:none!important}',
    '@media (prefers-reduced-motion:reduce){.tcgb-root *,.tcgb-root *::before,.tcgb-root *::after{transition:none!important;animation:none!important}}'
  ].join('\n');

  function injectCSS() {
    if (document.getElementById('tcgb-style')) return;
    var s = document.createElement('style');
    s.id = 'tcgb-style';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }
  function prefersReduced() {
    return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  /* Kartenpool: die 7 Beispielkarten der Seite + 5 Grund-Kulissen (als Common) */
  var RARN = { C: 'Common', U: 'Uncommon', R: 'Rare', M: 'Mythic' };
  var POOL = [
    { f: 'creep', name: 'Lucy', cost: '6', type: 'Rolle – Hauptrolle', r: 'M', img: 'rolle-lucy', pt: '7/4',
      text: '<b>Rampensau</b> <span class="rem">(greift an, ohne sich zu erschöpfen)</span><br><b>Monolog</b> — 1 Applaus: 1 Schaden an einem Ziel. Nur 1× pro Zug.',
      flavor: 'Creepshow · Sommerstück 2026' },
    { f: 'creep', name: 'Drusilla', cost: '4', type: 'Rolle – Nebenrolle', r: 'R', img: 'rolle-drusilla', pt: '6/2',
      text: '<b>Monolog</b> — 1 Applaus: 1 Schaden an einem Ziel. Nur 1× pro Zug.',
      flavor: 'Wenige Zeilen, aber jede davon lang.' },
    { f: 'creep', name: 'Clara', cost: '5', type: 'Rolle – Hauptrolle', r: 'R', img: 'rolle-clara', pt: '4/5',
      text: '<b>Rampensau</b><br><b>Stichwortgeber</b> — Auftritt: Eine verbündete Rolle erhält +1/+1 bis zum Ende des Zuges.',
      flavor: 'Creepshow · 11 Szenen' },
    { f: 'anno', name: 'Junge Johanna // Alte Johanna', cost: '2 · ⟳3', type: 'Rolle – doppelseitig', r: 'U', img: 'rolle-johanna', pt: '2/3',
      text: '<b>Zeitsprung</b> {3}: Drehe diese Karte um.<br><span class="rem">Rückseite 2/3:</span> <b>Rampensau</b>, <b>Duett</b> (Alte Emma).',
      flavor: 'Anno 1146 · Szene 5: „Zeitsprung“' },
    { f: 'creep', name: 'Jacques', cost: '1', type: 'Rolle – Ensemble', r: 'C', img: 'rolle-jacques', pt: '1/2',
      text: '<b>Auftritt:</b> Ziehe 1 Karte.<br><span class="rem">Kleine Rolle, großer Auftritt.</span>',
      flavor: 'Er hat 27 Wörter. Jedes sitzt.' },
    { f: 'neutral', name: 'Blitz und Donner', cost: '2', type: 'Regieanweisung – Ton', r: 'C', img: 'zauber-blitz', pt: '',
      text: 'Füge einer Rolle deiner Wahl 2 Schaden zu.',
      flavor: 'Ton-Cue aus Creepshow.' },
    { f: 'anno', name: 'Schwert, Dolch', cost: '2', type: 'Requisite – Ausrüstung', r: 'C', img: 'requisite-schwert', pt: '',
      text: 'Die ausgerüstete Rolle erhält +2/+0.<br>Ausrüsten {1}',
      flavor: 'Requisitenliste 2025: Lothar' },
    { land: 1, f: 'rot', pip: 'r', col: 'R', cname: 'Rot', name: 'Wüste', type: 'Kulisse – Gebirge', r: 'C', img: 'land-wueste', src: 'Goldfieber 2022', flavor: 'Eine alte Mine mit einem Schatz.' },
    { land: 1, f: 'blau', pip: 'u', col: 'U', cname: 'Blau', name: 'Piratenbucht', type: 'Kulisse – Insel', r: 'C', img: 'land-piratenbucht', src: 'Traum von Freiheit 2023', flavor: 'Wir schreiben das Jahr 1715.' },
    { land: 1, f: 'schwarz', pip: 'b', col: 'B', cname: 'Schwarz', name: 'Kanalisation', type: 'Kulisse – Sumpf', r: 'C', img: 'land-kanalisation', src: 'Nexus 2024', flavor: 'Wir haben das Jahr 2086.' },
    { land: 1, f: 'weiss', pip: 'w', col: 'W', cname: 'Weiß', name: 'Klosterhof', type: 'Kulisse – Ebene', r: 'C', img: 'land-klosterhof', src: 'Malleus Maleficarum 2021', flavor: 'Das leerstehende Kloster soll hergerichtet werden.' },
    { land: 1, f: 'gruen', pip: 'g', col: 'G', cname: 'Grün', name: 'Wald', type: 'Kulisse – Wald', r: 'C', img: 'land-wald', src: 'Anno 1146', flavor: 'Alles hat eine Geschichte.' }
  ];

  function cardHtml(c, A) {
    var art = '<div class="art has-img"><img src="' + A + c.img + '.webp" alt=""></div>';
    if (c.land) {
      return '<div class="tcg land ' + c.f + '"><div class="in">' +
        '<div class="top"><span class="nm">' + c.name + '</span><span class="pip ' + c.pip + '">' + c.col + '</span></div>' + art +
        '<div class="type"><span>' + c.type + '</span><span class="rar C" title="Grund-Kulisse (Common)">K</span></div>' +
        '<div class="txt"><b>Tappen:</b> Erhalte 1 Applaus <span class="pip ' + c.pip + '">' + c.col + '</span>.<div class="fl">' + c.flavor + '</div></div>' +
        '</div></div>';
    }
    return '<div class="tcg ' + c.f + '"><div class="in">' +
      '<div class="top"><span class="nm">' + c.name + '</span><span class="cost' + (c.cost.length > 2 ? ' dual' : '') + '">' + c.cost + '</span></div>' + art +
      '<div class="type"><span>' + c.type + '</span><span class="rar ' + c.r + '" title="' + RARN[c.r] + '">' + c.r + '</span></div>' +
      '<div class="txt">' + c.text + '<div class="fl">' + c.flavor + '</div></div>' +
      '</div>' + (c.pt ? '<div class="pt">' + c.pt + '</div>' : '') + '</div>';
  }
  function cardLabel(c, foil) {
    var s = c.land ? 'Kulisse ' + c.name + ', ' + c.cname + ', Common, aus ' + c.src
      : 'Karte ' + c.name + ', Kosten ' + c.cost + ', ' + c.type + ', ' + RARN[c.r] + (c.pt ? ', Werte ' + c.pt : '');
    return s + (foil ? ', Foil' : '');
  }

  /* gezackte Risskante, oben und unten passgenau */
  function tearPaths(y) {
    var pts = [], n = 16;
    for (var i = 0; i <= n; i++) pts.push([(i / n * 100).toFixed(2), (y + (i % 2 ? 2.2 : -1.6) + (i % 3 === 0 ? 0.8 : 0)).toFixed(2)]);
    var line = pts.map(function (p) { return p[0] + '% ' + p[1] + '%'; });
    return {
      top: 'polygon(0% 0%, 100% 0%, ' + line.slice().reverse().join(', ') + ')',
      body: 'polygon(' + line.join(', ') + ', 100% 100%, 0% 100%)'
    };
  }

  TCGAnim.booster = function (host, opts) {
    if (typeof host === 'string') host = document.querySelector(host);
    if (!host) throw new Error('TCGAnim.booster: host fehlt');
    opts = opts || {};
    var A = opts.assets != null ? opts.assets : 'tcg-gameplan-assets/';
    var reduced = opts.reducedMotion != null ? !!opts.reducedMotion : prefersReduced();
    var foilChance = opts.foilChance != null ? +opts.foilChance : 1 / 3;
    injectCSS();

    var root = document.createElement('div');
    root.className = 'tcgb-root' + (reduced ? ' tcgb-rm' : '') + (opts.frame === false ? ' tcgb-bare' : '');
    root.setAttribute('role', 'group');
    root.setAttribute('aria-label', 'Demo: Booster „Programmheft“ öffnen');
    root.innerHTML =
      '<div class="tcgb-stage">' +
        '<div class="tcgb-pack" aria-hidden="true"><div class="tcgb-float"><span class="tcgb-pk tcgb-pk-body"></span><span class="tcgb-pk tcgb-pk-top"></span></div></div>' +
        '<div class="tcgb-dim" aria-hidden="true"></div>' +
      '</div>' +
      '<div class="tcgb-ctl"><button type="button" class="tcgb-btn">Öffnen</button><span class="tcgb-hint">Programmheft mit 5 Karten</span></div>' +
      '<p class="tcgb-list" role="status" aria-live="polite"></p>' +
      '<p class="tcgb-note">Programmheft: 5 Karten · 3 C · 1 U · 1 R+ · Foil 3 % (hier zur Demo öfter)</p>';
    host.innerHTML = '';
    host.appendChild(root);

    var stage = root.querySelector('.tcgb-stage');
    var pack = root.querySelector('.tcgb-pack');
    var pkBody = root.querySelector('.tcgb-pk-body'), pkTop = root.querySelector('.tcgb-pk-top');
    var dim = root.querySelector('.tcgb-dim');
    var btn = root.querySelector('.tcgb-btn'), hint = root.querySelector('.tcgb-hint');
    var list = root.querySelector('.tcgb-list');

    var state = 'loading'; // loading | sealed | opening | done
    var gen = 0, timers = [], cards = [], drawn = [], foilIdx = -1, zoomed = -1, phase = 'none';
    var aspect = 0.7, L = null, ro = null, packImg = null, pending = false;

    function rnd() {
      if (opts.random) return opts.random();
      if (window.crypto && crypto.getRandomValues) { var a = new Uint32Array(1); crypto.getRandomValues(a); return a[0] / 4294967296; }
      return Math.random();
    }
    function pick(arr) { return arr[Math.floor(rnd() * arr.length)]; }
    function draw() {
      var commons = POOL.filter(function (c) { return c.r === 'C'; }).slice();
      for (var i = commons.length - 1; i > 0; i--) { var j = Math.floor(rnd() * (i + 1)); var t = commons[i]; commons[i] = commons[j]; commons[j] = t; }
      var unc = pick(POOL.filter(function (c) { return c.r === 'U'; }));
      /* Rare-Slot wie bei MTG: jede Rare doppelt so häufig wie eine Mythic */
      var rares = POOL.filter(function (c) { return c.r === 'R' || c.r === 'M'; });
      var tot = rares.reduce(function (s, c) { return s + (c.r === 'M' ? 1 : 2); }, 0), x = rnd() * tot, rare = rares[0];
      for (var k = 0; k < rares.length; k++) { x -= rares[k].r === 'M' ? 1 : 2; if (x < 0) { rare = rares[k]; break; } }
      drawn = commons.slice(0, 3).concat([unc, rare]);
      foilIdx = opts.foil != null ? +opts.foil : (rnd() < foilChance ? Math.floor(rnd() * 5) : -1);
    }

    function later(ms, fn) {
      var g = gen;
      timers.push(setTimeout(function () { if (g === gen) fn(); }, ms));
    }
    function clearTimers() { gen++; timers.forEach(clearTimeout); timers = []; }

    /* Päckchen: Bild, wenn vorhanden, sonst CSS */
    function packVisual() {
      if (packImg) return '<img src="' + packImg + '" alt="" draggable="false">';
      return '<span class="tcgb-css"><span class="tcgb-crimp t"></span><span class="tcgb-css-in">' +
        '<small>Kartenspiel</small><strong>Premiere</strong>' +
        '<span class="tcgb-emb" style="background-image:url(\'' + A + 'kartenrueckseite.webp\')"></span>' +
        '<em>Programmheft</em><small>5 Karten</small></span><span class="tcgb-crimp b"></span></span>';
    }
    function buildPack() {
      var v = packVisual();
      pkBody.innerHTML = v;
      pkTop.innerHTML = v;
      var tp = tearPaths(packImg ? 13 : 9);
      pkTop.style.clipPath = tp.top;
      pkBody.style.clipPath = tp.body;
    }
    function loadPack(cb) {
      var done = false, im = new Image();
      function fin(ok) {
        if (done) return;
        done = true;
        if (ok && im.naturalWidth) { packImg = im.src; aspect = im.naturalWidth / im.naturalHeight; }
        else { packImg = null; aspect = 0.7; }
        cb();
      }
      im.onload = function () { fin(true); };
      im.onerror = function () { fin(false); };
      setTimeout(function () { fin(false); }, 2500);
      im.src = A + 'booster-pack.webp';
    }

    function computeLayout() {
      var W = stage.clientWidth || 320;
      var narrow = W < 560, pos = [], cw, ch, fanH;
      if (!narrow) {
        cw = Math.min(190, Math.max(108, (W - 40) / 5.4));
        ch = cw * 88 / 63;
        var step = Math.min(cw * 1.04, (W - cw - 60) / 4), arc = cw * 0.035;
        for (var i = 0; i < 5; i++) {
          var d = i - 2;
          pos.push({ x: W / 2 + d * step, y: 20 + ch / 2 + d * d * arc, r: d * 4 });
        }
        fanH = 20 + ch + 4 * arc + 34;
      } else {
        var gap = 8;
        cw = Math.min(150, (W - 2 * gap - 12) / 3);
        ch = cw * 88 / 63;
        var y1 = 14 + ch / 2, y2 = y1 + ch + gap + 18, rr = [-3, 0, 3, -2, 2];
        for (var k = 0; k < 5; k++) {
          var row2 = k > 2, idx = row2 ? k - 3 : k, n = row2 ? 2 : 3;
          pos.push({ x: W / 2 + (idx - (n - 1) / 2) * (cw + gap), y: row2 ? y2 : y1, r: rr[k] });
        }
        fanH = y2 + ch / 2 + 30;
      }
      var pw = Math.min(narrow ? 170 : 200, W * 0.6), ph = pw / aspect, k0 = 0.72;
      var need = 0.55 * ch * k0 - 0.16 * ph + 8; /* Platz über dem Päckchen für herausschauende Karten */
      var H = Math.max(fanH, ph + 2 * Math.max(24, need));
      var off = (H - fanH) / 2;
      pos.forEach(function (p) { p.y += off; });
      var py = Math.max((H - ph) / 2, need);
      return { W: W, H: H, cw: cw, ch: ch, pos: pos, pw: pw, ph: ph, px: (W - pw) / 2, py: py, k0: k0 };
    }
    function tf(cx, cy, r, k) {
      return 'translate(' + (cx - L.cw / 2).toFixed(1) + 'px,' + (cy - L.ch / 2).toFixed(1) + 'px) rotate(' + r + 'deg) scale(' + k + ')';
    }
    function placeCard(i) {
      var el = cards[i];
      if (!el) return;
      var p = L.pos[i], t;
      if (zoomed === i) {
        var z = Math.max(1.15, Math.min((L.H - 16) / L.ch, (L.W - 24) / L.cw, 2.6));
        t = tf(L.W / 2, L.H / 2, 0, z.toFixed(3));
      } else if (phase === 'spawn') {
        t = tf(L.W / 2 + (i - 2) * 4, L.py + L.ph * 0.24 + L.ch * L.k0 / 2, (i - 2) * 2, L.k0);
      } else if (phase === 'rise') {
        t = tf(L.W / 2 + (i - 2) * 6, L.py + L.ph * 0.16 - 0.05 * L.ch * L.k0 - i * 3, (i - 2) * 3, L.k0);
      } else {
        t = tf(p.x, p.y, p.r, 1);
      }
      el.style.transform = t;
      el.style.zIndex = zoomed === i ? 50 : (phase === 'spawn' || phase === 'rise' ? 1 : 5 + i);
    }
    function applyLayout() {
      L = computeLayout();
      stage.style.height = Math.round(L.H) + 'px';
      stage.style.setProperty('--s', (L.cw / 200).toFixed(4));
      pack.style.width = L.pw + 'px';
      pack.style.height = L.ph + 'px';
      pack.style.left = L.px + 'px';
      pack.style.top = L.py + 'px';
      cards.forEach(function (el, i) {
        el.style.width = L.cw + 'px';
        el.style.height = L.ch + 'px';
        placeCard(i);
      });
    }

    function buildCards() {
      cards.forEach(function (el) { el.remove(); });
      cards = drawn.map(function (c, i) {
        var el = document.createElement('div');
        el.className = 'tcgb-card';
        el.setAttribute('aria-hidden', 'true');
        el.innerHTML = '<span class="tcgb-glowfx"></span><div class="tcgb-flip">' +
          '<div class="tcgb-face tcgb-back"><img src="' + A + 'kartenrueckseite.webp" alt="" draggable="false"></div>' +
          '<div class="tcgb-face tcgb-front"><div class="tcgb-scale">' + cardHtml(c, A) + '</div><span class="tcgb-foil"></span></div>' +
          '</div><span class="tcgb-foiltag">Foil</span>';
        el.dataset.i = i;
        stage.insertBefore(el, dim);
        return el;
      });
    }

    function reveal(i) {
      var el = cards[i], c = drawn[i];
      el.classList.add('tcgb-up');
      var g = function () {
        if (c.r === 'R' || c.r === 'M') el.classList.add('tcgb-glow');
        if (i === foilIdx) el.classList.add('tcgb-isfoil');
      };
      reduced ? g() : later(380, g);
      el.removeAttribute('aria-hidden');
      el.setAttribute('role', 'button');
      el.setAttribute('tabindex', '0');
      el.setAttribute('aria-pressed', 'false');
      el.setAttribute('aria-label', cardLabel(c, i === foilIdx) + '. Vergrößern');
    }
    function finish() {
      state = 'done';
      btn.disabled = false;
      btn.textContent = 'Nochmal';
      btn.setAttribute('aria-label', 'Nochmal: neuen Booster öffnen');
      hint.textContent = 'Karte antippen zum Vergrößern';
      list.innerHTML = 'Gezogen: ' + drawn.map(function (c, i) {
        var tag = c.r + (i === foilIdx ? ', Foil' : '');
        return (c.r === 'R' || c.r === 'M' ? '<b>' + c.name + '</b>' : c.name) + ' (' + tag + ')';
      }).join(' · ');
    }

    function open() {
      if (state !== 'sealed') return;
      state = 'opening';
      btn.disabled = true;
      list.textContent = '';
      draw();
      buildCards();
      phase = 'spawn';
      applyLayout();
      if (reduced) {
        pack.classList.add('tcgb-gone');
        phase = 'fan';
        cards.forEach(function (el, i) { placeCard(i); el.classList.add('tcgb-vis'); reveal(i); });
        finish();
        return;
      }
      pack.classList.remove('tcgb-idle');
      pack.classList.add('tcgb-shake');
      later(280, function () { pack.classList.add('tcgb-torn'); });
      later(560, function () { cards.forEach(function (el) { el.classList.add('tcgb-vis'); }); });
      later(640, function () {
        phase = 'rise';
        cards.forEach(function (el, i) { el.style.transitionDelay = (i * 70) + 'ms'; placeCard(i); });
      });
      later(1450, function () {
        phase = 'fan';
        pack.classList.add('tcgb-gone');
        cards.forEach(function (el, i) { el.style.transitionDelay = (i * 90) + 'ms'; placeCard(i); });
      });
      later(2300, function () { cards.forEach(function (el) { el.style.transitionDelay = ''; }); });
      /* gleichmäßiger Takt für alle 5 Karten, kein Abbremsen vor der Rare */
      for (var i = 0; i < 5; i++) (function (i) { later(2350 + i * 620, function () { reveal(i); }); })(i);
      later(2350 + 4 * 620 + 700, finish);
    }

    function seal() {
      clearTimers();
      zoomed = -1;
      dim.classList.remove('tcgb-on');
      cards.forEach(function (el) { el.remove(); });
      cards = [];
      phase = 'none';
      pack.className = 'tcgb-pack';
      buildPack();
      applyLayout();
      void pack.offsetWidth;
      pack.classList.add('tcgb-ready');
      if (!reduced) pack.classList.add('tcgb-idle');
      state = 'sealed';
      btn.disabled = false;
      btn.textContent = 'Öffnen';
      btn.setAttribute('aria-label', 'Booster öffnen');
      hint.textContent = 'Programmheft mit 5 Karten';
      if (pending) { pending = false; open(); }
    }
    function again() {
      list.textContent = '';
      btn.disabled = true;
      loadPack(function () {
        seal();
        if (reduced) open();
        else later(450, open);
      });
    }

    function setZoom(i) {
      if (zoomed === i) i = -1;
      var prev = zoomed;
      zoomed = i;
      if (prev >= 0) { cards[prev].setAttribute('aria-pressed', 'false'); cards[prev].classList.remove('tcgb-zoom'); placeCard(prev); }
      if (i >= 0) { cards[i].setAttribute('aria-pressed', 'true'); cards[i].classList.add('tcgb-zoom'); placeCard(i); }
      dim.classList.toggle('tcgb-on', i >= 0);
    }

    btn.addEventListener('click', function () {
      if (state === 'sealed') open();
      else if (state === 'done') again();
    });
    pack.addEventListener('click', function () { if (state === 'sealed') open(); });
    dim.addEventListener('click', function () { setZoom(-1); });
    stage.addEventListener('click', function (e) {
      var el = e.target.closest && e.target.closest('.tcgb-card');
      if (el && state === 'done') setZoom(+el.dataset.i);
    });
    stage.addEventListener('keydown', function (e) {
      var el = e.target.closest && e.target.closest('.tcgb-card');
      if (e.key === 'Escape' && zoomed >= 0) { setZoom(-1); e.preventDefault(); return; }
      if (el && state === 'done' && (e.key === 'Enter' || e.key === ' ')) { setZoom(+el.dataset.i); e.preventDefault(); }
    });

    if ('ResizeObserver' in window) {
      var lastW = 0;
      ro = new ResizeObserver(function () {
        var w = stage.clientWidth;
        /* verzögert, damit die Höhenänderung keine RO-Schleife auslöst */
        if (w && w !== lastW) { lastW = w; setTimeout(applyLayout, 0); }
      });
      ro.observe(stage);
    } else {
      window.addEventListener('resize', applyLayout);
    }

    loadPack(seal);

    return {
      root: root,
      open: function () { if (state === 'sealed') open(); else if (state === 'loading') pending = true; },
      again: again,
      reset: function () { loadPack(seal); },
      destroy: function () {
        clearTimers();
        if (ro) ro.disconnect(); else window.removeEventListener('resize', applyLayout);
        if (root.parentNode) root.parentNode.removeChild(root);
      }
    };
  };
})();
