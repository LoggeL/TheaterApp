/* Premiere · animierte Demo-Partie (klassisches Script, kein ES-Modul, keine Abhängigkeiten).
 * API: TCGAnim.match(host, {assets:'tcg-gameplan-assets/', autoplay:true, step:0, loop:true})
 *      → {play, pause, toggle, next, prev, restart, goTo(i, instant), step, steps, destroy}
 * Braucht das .tcg-Kartenmarkup und die Tokens (--bg, --surface, --ink …) der Gameplan-Seite.
 */
(function () {
  'use strict';
  var NS = window.TCGAnim = window.TCGAnim || {};

  var DW = 200, DH = 200 * 88 / 63, R = 88 / 63;   // Designgröße einer Karte, skaliert per transform

  /* ---------- Karten (aus CARDS/LANDS der Seite übernommen) ---------- */
  var GLYPH_ANNO = '<svg viewBox="0 0 64 64" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M10 54h44M14 54V30l6-6 6 6v24M38 54V30l6-6 6 6v24M26 54V40h12v14"/><path d="M20 24V14l-3 3M44 24V14l3 3M32 36V20"/><path d="M32 20l8 4-8 4"/></svg>';
  var DEF = {
    wald: {land: 1, f: 'gruen', name: 'Wald', pip: 'g', P: 'G', img: 'land-wald', type: 'Kulisse – Wald', flavor: 'Alles hat eine Geschichte.'},
    kanal: {land: 1, f: 'schwarz', name: 'Kanalisation', pip: 'b', P: 'B', img: 'land-kanalisation', type: 'Kulisse – Sumpf', flavor: 'Wir haben das Jahr 2086.'},
    lucy: {f: 'creep', name: 'Lucy', cost: '6', type: 'Rolle – Hauptrolle', r: 'M', img: 'rolle-lucy', pt: [7, 4],
      text: '<b>Rampensau</b> <span class="rem">(greift an, ohne sich zu erschöpfen)</span><br><b>Monolog</b> — 1 Applaus: 1 Schaden an einem Ziel. Nur 1× pro Zug.', flavor: 'Creepshow · Sommerstück 2026'},
    drusilla: {f: 'creep', name: 'Drusilla', cost: '4', type: 'Rolle – Nebenrolle', r: 'R', img: 'rolle-drusilla', pt: [6, 2],
      text: '<b>Monolog</b> — 1 Applaus: 1 Schaden an einem Ziel. Nur 1× pro Zug.', flavor: 'Wenige Zeilen, aber jede davon lang.'},
    jacques: {f: 'creep', name: 'Jacques', cost: '1', type: 'Rolle – Ensemble', r: 'C', img: 'rolle-jacques', pt: [1, 2],
      text: '<b>Auftritt:</b> Ziehe 1 Karte.<br><span class="rem">Kleine Rolle, großer Auftritt.</span>', flavor: 'Er hat 27 Wörter. Jedes sitzt.'},
    jjohanna: {f: 'anno', name: 'Junge Johanna', cost: '2 · ⟳3', type: 'Rolle – doppelseitig', r: 'U', img: 'rolle-johanna', pt: [2, 3],
      text: '<b>Zeitsprung</b> {3}: Drehe diese Karte um.<br><span class="rem">Rückseite 2/3:</span> <b>Rampensau</b>, <b>Duett</b> (Alte Emma).', flavor: 'Anno 1146 · Szene 5: „Zeitsprung“'},
    ajohanna: {f: 'anno', name: 'Alte Johanna', cost: '⟳', type: 'Rolle – Rückseite', r: 'U', img: 'rolle-johanna', pt: [2, 3],
      text: '<b>Rampensau</b> <span class="rem">(greift an, ohne sich zu erschöpfen)</span><br><b>Duett</b> (Alte Emma)', flavor: 'Anno 1146 · nach dem Zeitsprung'},
    ensemble: {f: 'anno', name: 'Ensemble', cost: '', type: 'Spielstein', r: 'C', rl: 'S', glyph: GLYPH_ANNO, pt: [1, 1],
      text: 'Ein Spielstein aus dem Ensemble.', flavor: 'Anno 1146 · Ensemble ohne Text'},
    blitz: {f: 'neutral', name: 'Blitz und Donner', cost: '2', type: 'Regieanweisung – Ton', r: 'C', img: 'zauber-blitz',
      text: 'Füge einer Rolle deiner Wahl 2 Schaden zu.', flavor: 'Ton-Cue aus Creepshow.'},
    schwert: {f: 'anno', name: 'Schwert, Dolch', cost: '2', type: 'Requisite – Ausrüstung', r: 'C', img: 'requisite-schwert',
      text: 'Die ausgerüstete Rolle erhält +2/+0.<br>Ausrüsten {1}', flavor: 'Requisitenliste 2025: Lothar'}
  };

  function cardHtml(d, A) {
    var art = d.img
      ? '<div class="art has-img"><img data-src="' + A + d.img + '.webp" alt=""></div>'
      : '<div class="art">' + (d.glyph || '') + '</div>';
    if (d.land) {
      return '<div class="tcg land ' + d.f + '"><div class="in">' +
        '<div class="top"><span class="nm">' + d.name + '</span><span class="pip ' + d.pip + '">' + d.P + '</span></div>' + art +
        '<div class="type"><span>' + d.type + '</span><span class="rar C">K</span></div>' +
        '<div class="txt"><b>Tappen:</b> Erhalte 1 Applaus <span class="pip ' + d.pip + '">' + d.P + '</span>.<div class="fl">' + d.flavor + '</div></div>' +
        '</div></div>';
    }
    return '<div class="tcg ' + d.f + '"><div class="in">' +
      '<div class="top"><span class="nm">' + d.name + '</span>' + (d.cost ? '<span class="cost' + (d.cost.length > 2 ? ' dual' : '') + '">' + d.cost + '</span>' : '') + '</div>' + art +
      '<div class="type"><span>' + d.type + '</span><span class="rar ' + d.r + '">' + (d.rl || d.r) + '</span></div>' +
      '<div class="txt">' + d.text + '<div class="fl">' + d.flavor + '</div></div>' +
      '</div>' + (d.pt ? '<div class="pt">' + d.pt[0] + '/' + d.pt[1] + '</div>' : '') + '</div>';
  }

  /* ---------- Ausgangslage: Runde 7, Anno 1146 (unten) ist am Zug ---------- */
  function initialState() {
    var c = {};
    var o = 0;
    function add(id, def, owner, zone, extra) {
      var x = {def: def, own: owner, z: zone, o: ++o, tap: false, down: false, lf: false, atk: false, blk: null, dmg: 0, note: '', host: null,
        pt: DEF[def].pt ? DEF[def].pt.slice() : null};
      for (var k in extra) x[k] = extra[k];
      c[id] = x;
    }
    var i;
    for (i = 1; i <= 6; i++) add('K' + i, 'kanal', 'opp', 'lands', {tap: true});   // alle 6 im Vorzug für Lucy getappt
    add('DR', 'drusilla', 'opp', 'grave');
    add('LU', 'lucy', 'opp', 'stage');
    add('JA', 'jacques', 'opp', 'stage');
    for (i = 1; i <= 3; i++) add('OH' + i, 'jacques', 'opp', 'ohand', {down: true, blank: true});
    for (i = 1; i <= 6; i++) add('W' + i, 'wald', 'me', 'lands', {tap: true});
    add('AJ', 'ajohanna', 'me', 'stage');
    add('EN', 'ensemble', 'me', 'stage', {tap: true});
    add('W7', 'wald', 'me', 'hand');
    add('JJ', 'jjohanna', 'me', 'hand');
    add('SW', 'schwert', 'me', 'hand');
    add('W8', 'wald', 'me', 'hand');
    add('BL', 'blitz', 'me', 'deck', {down: true});
    return {cards: c, seq: o, pub: {me: 14, opp: 11}, deck: {me: 24, opp: 23}, graveBase: {me: 2, opp: 3},
      curtain: true, phase: -1, reaction: false, cap: 'Runde 7: Anno 1146 ist am Zug'};
  }

  var PHASES = ['Vorhang auf', '1. Akt', 'Auftritt', '2. Akt', 'Vorhang zu'];

  /* Drehbuch: jeder Schritt verändert eine Kopie des vorigen Zustands.
   * Applaus: 6 Wald + 1 neu = 7 → Johanna 2, Schwert 2, Ausrüsten 1, Blitz 2 = 7. */
  var STEPS = [
    {phase: 0, cap: 'Vorhang auf: aufrichten, eine Karte ziehen', dur: 3400,
      meta: {delay: {W1: 750, W2: 810, W3: 870, W4: 930, W5: 990, W6: 1050, EN: 750, BL: 1150}, pipAt: 1100},
      run: function (s) { s.curtain = false; untap(s, ['W1', 'W2', 'W3', 'W4', 'W5', 'W6', 'EN']); move(s, 'BL', 'hand'); s.cards.BL.down = false; s.deck.me--; }},
    {phase: 1, cap: 'Kulisse Wald: 7 Applaus bereit', dur: 2500,
      meta: {pipAt: 600},
      run: function (s) { move(s, 'W7', 'lands'); }},
    {phase: 1, cap: 'Junge Johanna für 2, mit Lampenfieber', dur: 3100,
      meta: {delay: {W1: 0, W2: 140, JJ: 380}, focus: ['JJ'], pipAt: 250},
      run: function (s) { tap(s, ['W1', 'W2']); move(s, 'JJ', 'stage'); s.cards.JJ.lf = true; }},
    {phase: 1, cap: 'Requisite Schwert, Dolch für 2 Applaus', dur: 2900,
      meta: {delay: {W3: 0, W4: 140, SW: 380}, focus: ['SW'], pipAt: 250},
      run: function (s) { tap(s, ['W3', 'W4']); move(s, 'SW', 'stage'); }},
    {phase: 1, cap: 'Ausrüsten für 1: Alte Johanna 4/3', dur: 2900,
      meta: {delay: {W5: 0, SW: 300}, pipAt: 150, ptAt: {AJ: 1000}},
      run: function (s) { tap(s, ['W5']); s.cards.SW.z = 'att'; s.cards.SW.host = 'AJ'; s.cards.AJ.pt = [4, 3]; }},
    {phase: 2, cap: 'Angriff: Alte Johanna und Ensemble', dur: 2800,
      meta: {delay: {AJ: 0, SW: 0, EN: 140}},
      run: function (s) { s.cards.AJ.atk = s.cards.EN.atk = true; s.cards.EN.tap = true; s.cards.AJ.note = 'Rampensau<span class="tcgm-lbl-long">: bleibt aufrecht</span>'; }},
    {phase: 2, cap: 'Creepshow blockt das Ensemble mit Jacques', dur: 2800,
      meta: {},
      run: function (s) { s.cards.AJ.note = ''; s.cards.JA.blk = 'EN'; s.cards.JA.note = 'blockt'; }},
    {phase: 2, cap: 'Reaktion: Blitz und Donner trifft Jacques', dur: 3700,
      meta: {delay: {W6: 0, W7: 140, BL: 380}, focus: ['BL'], pipAt: 250, flagAt: {JA: 1750}, fx: 'bolt'},
      run: function (s) { tap(s, ['W6', 'W7']); move(s, 'BL', 'stack'); s.reaction = true; s.cards.JA.note = ''; s.cards.JA.dmg = 2; }},
    {phase: 2, cap: 'Jacques geht auf die Hinterbühne', dur: 2600,
      meta: {delay: {JA: 0, BL: 300}},
      run: function (s) { var j = s.cards.JA; j.blk = null; j.dmg = 0; move(s, 'JA', 'grave'); move(s, 'BL', 'grave'); s.reaction = false; s.cards.EN.note = 'überlebt'; }},
    {phase: 2, cap: 'Alte Johanna trifft: Publikum 11 auf 7', dur: 3100,
      meta: {fx: 'lunge', pubAt: 560},
      run: function (s) { s.cards.EN.note = ''; s.pub.opp = 7; }},
    {phase: 3, cap: '2. Akt: kein Applaus mehr übrig', dur: 2500,
      meta: {delay: {AJ: 0, SW: 0, EN: 120}},
      run: function (s) { s.cards.AJ.atk = s.cards.EN.atk = false; }},
    {phase: 4, cap: 'Vorhang zu: Creepshow ist am Zug', dur: 2600,
      meta: {},
      run: function (s) { s.curtain = true; }}
  ];
  var HOLD = 3200, START_WAIT = 1100;

  function tap(s, ids) { ids.forEach(function (i) { s.cards[i].tap = true; }); }
  function untap(s, ids) { ids.forEach(function (i) { s.cards[i].tap = false; }); }
  function move(s, id, zone) { s.cards[id].z = zone; s.cards[id].o = ++s.seq; }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }

  function buildStates() {
    var st = [initialState()];
    STEPS.forEach(function (step, i) {
      var s = clone(st[i]);
      step.run(s);
      s.phase = step.phase; s.cap = step.cap;
      st.push(s);
    });
    return st;
  }

  /* ---------- CSS (einmalig, Präfix .tcgm-, Farben nur aus Seiten-Tokens) ---------- */
  var CSS = [
    '.tcgm{position:relative;container-type:inline-size;color:var(--ink);font:14px/1.4 Inter,system-ui,sans-serif;margin:18px 0;',
    '--tcgm-wood1:color-mix(in srgb,var(--anno) 80%,var(--gold));--tcgm-wood2:color-mix(in srgb,var(--anno) 86%,var(--ink));--tcgm-seam:color-mix(in srgb,var(--anno) 45%,var(--ink));',
    '--tcgm-c1:var(--curtain);--tcgm-c2:var(--curtain2);--tcgm-c3:color-mix(in srgb,var(--curtain) 62%,var(--ink));--tcgm-cink:var(--gold-soft);--tcgm-scrim:color-mix(in srgb,var(--bg) 6%,transparent)}',
    '@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .tcgm{--tcgm-wood1:color-mix(in srgb,var(--anno) 40%,var(--bg));--tcgm-wood2:color-mix(in srgb,var(--anno) 32%,var(--bg));--tcgm-seam:var(--bg);',
    '--tcgm-c1:color-mix(in srgb,var(--curtain) 62%,var(--bg));--tcgm-c2:color-mix(in srgb,var(--curtain2) 58%,var(--bg));--tcgm-c3:color-mix(in srgb,var(--curtain) 30%,var(--bg));--tcgm-cink:var(--gold);--tcgm-scrim:color-mix(in srgb,var(--bg) 22%,transparent)}}',
    ':root[data-theme="dark"] .tcgm{--tcgm-wood1:color-mix(in srgb,var(--anno) 40%,var(--bg));--tcgm-wood2:color-mix(in srgb,var(--anno) 32%,var(--bg));--tcgm-seam:var(--bg);',
    '--tcgm-c1:color-mix(in srgb,var(--curtain) 62%,var(--bg));--tcgm-c2:color-mix(in srgb,var(--curtain2) 58%,var(--bg));--tcgm-c3:color-mix(in srgb,var(--curtain) 30%,var(--bg));--tcgm-cink:var(--gold);--tcgm-scrim:color-mix(in srgb,var(--bg) 22%,transparent)}',
    '.tcgm *{box-sizing:border-box}',
    '.tcgm-frame{background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);padding:12px}',
    '.tcgm-phases{display:flex;gap:4px;margin:0 0 10px;padding:0;list-style:none}',
    '.tcgm-phases li{flex:1 1 0;min-width:0;text-align:center;font:600 .8rem/1.2 Inter,system-ui,sans-serif;padding:7px 4px;border-radius:999px;background:var(--bg2);color:var(--muted);border:1px solid var(--line);transition:background-color .3s,color .3s,border-color .3s;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin:0}',
    '.tcgm-phases li.done{color:var(--ink)}',
    '.tcgm-phases li.on{background:var(--curtain);border-color:var(--curtain);color:var(--surface)}',
    '.tcgm-stage{position:relative;border-radius:12px;outline:none}',
    '.tcgm-stage:focus-visible{box-shadow:0 0 0 3px var(--gold)}',
    '.tcgm-board{--tcgm-mat:none;position:relative;overflow:hidden;border-radius:12px;height:480px;background-color:var(--tcgm-wood2);',
    'background-image:linear-gradient(var(--tcgm-scrim),var(--tcgm-scrim)),var(--tcgm-mat),repeating-linear-gradient(0deg,transparent 0 5px,color-mix(in srgb,var(--tcgm-seam) 14%,transparent) 5px 6px),',
    'repeating-linear-gradient(90deg,var(--tcgm-wood1) 0 70px,var(--tcgm-seam) 70px 72px,var(--tcgm-wood2) 72px 150px,var(--tcgm-seam) 150px 152px,color-mix(in srgb,var(--tcgm-wood1) 70%,var(--tcgm-wood2)) 152px 214px,var(--tcgm-seam) 214px 216px);',
    'background-size:cover,cover,auto,auto;background-position:center;user-select:none;-webkit-user-select:none}',
    '.tcgm-probe{position:absolute;visibility:hidden;height:0;width:var(--tcgm-cw,clamp(56px,calc(38px + 5.6cqw),100px))}',
    '.tcgm-c{position:absolute;left:0;top:0;width:200px;height:' + DH.toFixed(2) + 'px;transform-origin:50% 50%;will-change:transform;pointer-events:none}',
    '.tcgm-fx,.tcgm-flip,.tcgm-front,.tcgm-back{position:absolute;inset:0}',
    '.tcgm-fx{perspective:1000px}',
    '.tcgm-flip{transform-style:preserve-3d;transition:transform .55s cubic-bezier(.3,.7,.3,1)}',
    '.tcgm-down .tcgm-flip{transform:rotateY(180deg)}',
    '.tcgm-front,.tcgm-back{backface-visibility:hidden;-webkit-backface-visibility:hidden}',
    '.tcgm-back{transform:rotateY(180deg);border-radius:14px;overflow:hidden;background:var(--curtain);box-shadow:0 6px 16px rgba(0,0,0,.3)}',
    '.tcgm-back img,.tcgm-deck img{width:100%;height:100%;object-fit:cover;display:block}',
    '.tcgm-board .tcg{width:100%;height:100%;aspect-ratio:auto;transition:box-shadow .3s}',
    '.tcgm-board .tcg:hover{transform:none}',
    '.tcgm-atk .tcg{box-shadow:0 0 0 calc(5px / var(--s,1)) var(--curtain),0 12px 28px rgba(0,0,0,.4)}',
    '.tcgm-blk .tcg{box-shadow:0 0 0 calc(5px / var(--s,1)) var(--creep),0 12px 28px rgba(0,0,0,.4)}',
    '.tcgm-c .pt{transition:transform .25s,background-color .25s}',
    '.tcgm-ptup .pt{transform:scale(1.7);background:var(--gold-soft);color:var(--ink)}',
    '.tcgm-badge{position:absolute;left:50%;top:0;white-space:nowrap;font:700 11px/1 Inter,system-ui,sans-serif;padding:4px 8px;border-radius:999px;opacity:0;',
    'transform:translate(-50%,-50%) rotate(var(--tcgm-br,0deg)) scale(calc(.85 * var(--tcgm-bs,1) / var(--s,1)));transition:opacity .3s,transform .3s;box-shadow:0 2px 6px rgba(0,0,0,.3)}',
    '.tcgm-lf{background:var(--ink);color:var(--bg);border:1px solid var(--gold);top:40%}',
    '.tcgm-note{top:100%;background:var(--surface);color:var(--ink);border:1px solid var(--gold)}',
    '.tcgm-dmg{left:88%;top:12%;background:var(--curtain);color:var(--surface);font-size:13px;padding:5px 7px}',
    '.tcgm-c.has-lf .tcgm-lf,.tcgm-c.has-note .tcgm-note,.tcgm-c.has-dmg .tcgm-dmg{opacity:1;transform:translate(-50%,-50%) rotate(var(--tcgm-br,0deg)) scale(calc(var(--tcgm-bs,1) / var(--s,1)))}',
    '.tcgm-tap{--tcgm-br:-90deg}',
    '.tcgm-tap .tcgm-note{top:50%}',
    '.tcgm-narrow{--tcgm-bs:.8}',
    '.tcgm-narrow .tcgm-rampe span{display:none}',
    '.tcgm-hud{position:absolute;z-index:60;display:flex;flex-direction:column;align-items:flex-start;gap:6px}',
    '.tcgm-narrow .tcgm-hud{flex-direction:row;align-items:center;gap:5px;flex-wrap:nowrap}',
    '.tcgm-chip{display:inline-flex;align-items:center;gap:6px;background:color-mix(in srgb,var(--surface) 93%,transparent);color:var(--ink);border:1px solid var(--line);border-radius:999px;padding:3px 10px;font:600 .8rem/1.25 Inter,system-ui,sans-serif;box-shadow:0 2px 8px rgba(0,0,0,.22);white-space:nowrap}',
    '.tcgm-chip .pip{width:16px;height:16px;font-size:.55rem;margin:0}',
    '.tcgm-who{font-family:Fraunces,Georgia,serif;font-weight:700}',
    '.tcgm-who em{font:700 .66rem/1 Inter,system-ui,sans-serif;font-style:normal;text-transform:uppercase;letter-spacing:.06em;color:var(--curtain)}',
    '.tcgm-hud.turn .tcgm-who{border-color:var(--curtain);box-shadow:0 0 0 1px var(--curtain),0 2px 8px rgba(0,0,0,.22)}',
    '.tcgm-pub{border-radius:12px;padding:4px 12px;transition:background-color .3s}',
    '.tcgm-pub b{font:900 1.5rem/1 Fraunces,Georgia,serif;font-variant-numeric:tabular-nums;min-width:1.3em;text-align:right}',
    '.tcgm-pub small,.tcgm-app small{font-size:.72rem;color:var(--muted);font-weight:600}',
    '.tcgm-pub.hit{background:color-mix(in srgb,var(--curtain) 30%,var(--surface))}',
    '.tcgm-pips{display:inline-flex;gap:3px}',
    '.tcgm-pips .pip{width:13px;height:13px;margin:0;font-size:0;opacity:.25;transform:scale(.8);transition:opacity .3s,transform .3s,box-shadow .4s}',
    '.tcgm-pips .pip.on{opacity:1;transform:none}',
    '.tcgm-pips .pip.glow{box-shadow:0 0 0 2px var(--gold-soft),0 0 10px 2px var(--gold);transform:scale(1.2)}',
    '.tcgm-app b{font-variant-numeric:tabular-nums}',
    '.tcgm-narrow .tcgm-chip{padding:2px 7px;font-size:.72rem;gap:4px}',
    '.tcgm-narrow .tcgm-pub{padding:2px 8px}',
    '.tcgm-narrow .tcgm-pub b{font-size:1.05rem}',
    '.tcgm-narrow .tcgm-pips .pip{width:9px;height:9px}',
    '.tcgm-narrow .tcgm-pips{gap:2px}',
    '.tcgm-narrow .tcgm-lbl-long,.tcgm-narrow .tcgm-who .pip{display:none}',
    '.tcgm-pile{position:absolute;z-index:5;border-radius:8px}',
    '.tcgm-deck{overflow:hidden;box-shadow:2px 2px 0 var(--line),4px 4px 0 color-mix(in srgb,var(--line) 70%,transparent),0 6px 14px rgba(0,0,0,.35)}',
    '.tcgm-grave{border:2px dashed color-mix(in srgb,var(--surface) 55%,transparent);background:color-mix(in srgb,var(--bg) 30%,transparent)}',
    '.tcgm-plbl{position:absolute;z-index:65;transform:translate(-50%,0);font-size:.68rem;padding:1px 7px;gap:3px}',
    '.tcgm-plbl b{font-variant-numeric:tabular-nums}',
    '.tcgm-narrow .tcgm-plbl{font-size:.62rem;padding:0 5px}',
    '.tcgm-rampe{position:absolute;z-index:2;height:0;border-top:2px dashed color-mix(in srgb,var(--gold) 55%,transparent);transition:border-color .3s}',
    '.tcgm-rampe.on{border-top-color:var(--gold)}',
    '.tcgm-rampe span{position:absolute;left:var(--lx,50%);top:0;transform:translate(-50%,-50%);font-size:.66rem;padding:1px 8px;opacity:.9}',
    '.tcgm-slot{position:absolute;z-index:69;border:2px dashed var(--gold);border-radius:10px;opacity:0;transition:opacity .3s;background:color-mix(in srgb,var(--gold) 12%,transparent)}',
    '.tcgm-slot.on{opacity:1}',
    '.tcgm-slot span{position:absolute;left:50%;bottom:100%;transform:translate(-50%,-4px);font-size:.66rem;padding:1px 8px}',
    '.tcgm-flash{position:absolute;inset:0;z-index:85;pointer-events:none;opacity:0;background:radial-gradient(circle at var(--fx,50%) var(--fy,50%),var(--gold-soft) 0,color-mix(in srgb,var(--gold) 45%,transparent) 22%,transparent 62%)}',
    '.tcgm-bolt{position:absolute;z-index:86;width:90px;height:90px;margin:-45px 0 0 -45px;pointer-events:none;opacity:0}',
    '.tcgm-bolt path{fill:var(--gold-soft);stroke:var(--gold);stroke-width:3;stroke-linejoin:round}',
    '.tcgm-float{position:absolute;z-index:88;pointer-events:none;font:900 1.8rem/1 Fraunces,Georgia,serif;color:var(--curtain);text-shadow:0 1px 0 var(--surface),0 0 8px var(--surface)}',
    '.tcgm-curt{position:absolute;inset:0;z-index:200;pointer-events:none;overflow:hidden}',
    '.tcgm-curt i{position:absolute;top:0;bottom:0;width:51%;transition:transform 1.1s cubic-bezier(.6,0,.3,1);',
    'background:repeating-linear-gradient(90deg,var(--tcgm-c3) 0 6px,var(--tcgm-c1) 6px 22px,var(--tcgm-c2) 22px 30px,var(--tcgm-c1) 30px 40px);box-shadow:0 0 30px rgba(0,0,0,.5)}',
    '.tcgm-curt i:first-child{left:0;transform:translateX(-102%)}',
    '.tcgm-curt i:nth-child(2){right:0;transform:translateX(102%)}',
    '.tcgm-closed .tcgm-curt i{transform:none}',
    '.tcgm-curt b{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:90%;text-align:center;color:var(--tcgm-cink);font:900 clamp(1.2rem,4.2cqw,2.3rem)/1.15 Fraunces,Georgia,serif;opacity:0;transition:opacity .35s;text-shadow:0 2px 12px rgba(0,0,0,.45)}',
    '.tcgm-curt b small{display:block;font:600 clamp(.75rem,1.6cqw,.95rem)/1.4 Inter,system-ui,sans-serif;margin-top:6px;letter-spacing:.04em}',
    '.tcgm-closed .tcgm-curt b{opacity:1;transition-delay:.55s}',
    '.tcgm-bot{display:flex;flex-wrap:wrap;align-items:center;gap:8px 14px;margin-top:10px}',
    '.tcgm-cap{flex:1 1 240px;margin:0;min-height:2.7em;display:flex;align-items:center;font:700 1.05rem/1.3 Fraunces,Georgia,serif}',
    '.tcgm-ctl{display:flex;align-items:center;gap:6px;flex-wrap:wrap}',
    '.tcgm-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-width:40px;height:40px;padding:0 12px;border-radius:999px;border:1px solid var(--line);background:var(--bg2);color:var(--ink);font:600 .85rem/1 Inter,system-ui,sans-serif;cursor:pointer}',
    '.tcgm-btn:hover{border-color:var(--muted)}',
    '.tcgm-btn:focus-visible{outline:3px solid var(--gold);outline-offset:2px}',
    '.tcgm-btn:disabled{opacity:.4;cursor:default}',
    '.tcgm-btn svg{width:16px;height:16px;flex:none}',
    '.tcgm-btn.play{background:var(--curtain);border-color:var(--curtain);color:var(--surface);min-width:120px}',
    '.tcgm-count{font-size:.78rem;color:var(--muted);font-variant-numeric:tabular-nums;min-width:6.5em;text-align:right}',
    '.tcgm-rm .tcgm-btn.play{display:none}',
    '.tcgm-instant *,.tcgm-instant{transition:none!important;animation:none!important}',
    '@container (max-width:560px){.tcgm-phases li{font-size:.66rem;padding:5px 2px;white-space:normal;line-height:1.1;display:flex;align-items:center;justify-content:center;border-radius:10px}.tcgm-cap{font-size:.95rem;flex-basis:100%}.tcgm-ctl{width:100%;justify-content:space-between}.tcgm-btn.play{min-width:0;flex:1}.tcgm-count{min-width:0}.tcgm-cl{display:none}}',
    '@media (prefers-reduced-motion:reduce){.tcgm *{transition:none!important}}'
  ].join('\n');

  function injectCss() {
    if (document.getElementById('tcgm-style')) return;
    var st = document.createElement('style');
    st.id = 'tcgm-style';
    st.textContent = CSS;
    document.head.appendChild(st);
  }

  var ICON = {
    restart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.4-5.7"/><path d="M4 4v4.5h4.5"/></svg>',
    prev: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg>',
    next: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>',
    play: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15l13-7.5z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="5.5" y="4.5" width="4.5" height="15" rx="1"/><rect x="14" y="4.5" width="4.5" height="15" rx="1"/></svg>'
  };
  var BOLT = '<svg class="tcgm-bolt" viewBox="0 0 64 64"><path d="M36 4L14 36h14l-5 24 25-34H34z"/></svg>';

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  /* ======================================================================= */
  NS.match = function (host, opts) {
    opts = opts || {};
    var A = opts.assets != null ? opts.assets : 'tcg-gameplan-assets/';
    var loop = opts.loop !== false;
    injectCss();

    var states = buildStates();
    var N = STEPS.length;
    var mqRM = window.matchMedia ? matchMedia('(prefers-reduced-motion: reduce)') : {matches: false};
    var reduced = !!mqRM.matches;

    host.classList.add('tcgm');
    host.setAttribute('role', 'region');
    host.setAttribute('aria-label', 'Demo-Partie: ein kompletter Zug von Anno 1146 gegen Creepshow');
    host.innerHTML =
      '<div class="tcgm-frame">' +
      '<ol class="tcgm-phases" aria-label="Zugablauf">' + PHASES.map(function (p) { return '<li>' + p + '</li>'; }).join('') + '</ol>' +
      '<div class="tcgm-stage" tabindex="0" role="group" aria-label="Spielbrett. Pfeiltasten: Schritt zurück oder vor. Leertaste: Abspielen oder Pause. Pos1: Neustart.">' +
      '<div class="tcgm-board tcgm-closed" aria-hidden="true">' +
      '<div class="tcgm-probe"></div>' +
      '<div class="tcgm-rampe"><span class="tcgm-chip">Auftritt</span></div>' +
      '<div class="tcgm-slot"><span class="tcgm-chip">Reaktion</span></div>' +
      hudHtml('opp', 'b', 'B', 'Creepshow') + hudHtml('me', 'g', 'G', 'Anno 1146') +
      '<div class="tcgm-pile tcgm-deck" data-side="opp"><img data-src="' + A + 'kartenrueckseite.webp" alt=""></div>' +
      '<div class="tcgm-pile tcgm-grave" data-side="opp"></div>' +
      '<div class="tcgm-pile tcgm-deck" data-side="me"><img data-src="' + A + 'kartenrueckseite.webp" alt=""></div>' +
      '<div class="tcgm-pile tcgm-grave" data-side="me"></div>' +
      '<span class="tcgm-chip tcgm-plbl" data-for="deck-opp"><span class="tcgm-lbl-long">Textbuch</span> <b></b></span>' +
      '<span class="tcgm-chip tcgm-plbl" data-for="grave-opp"><span class="tcgm-lbl-long">Hinterbühne</span> <b></b></span>' +
      '<span class="tcgm-chip tcgm-plbl" data-for="deck-me"><span class="tcgm-lbl-long">Textbuch</span> <b></b></span>' +
      '<span class="tcgm-chip tcgm-plbl" data-for="grave-me"><span class="tcgm-lbl-long">Hinterbühne</span> <b></b></span>' +
      '<div class="tcgm-cards"></div>' +
      '<div class="tcgm-flash"></div>' +
      '<div class="tcgm-curt"><i></i><i></i><b>Premiere<small>Runde 7 · Anno 1146 gegen Creepshow</small></b></div>' +
      '</div></div>' +
      '<div class="tcgm-bot">' +
      '<p class="tcgm-cap" aria-live="polite" aria-atomic="true"></p>' +
      '<div class="tcgm-ctl">' +
      '<button type="button" class="tcgm-btn" data-a="restart" aria-label="Neustart" title="Neustart (Pos1)">' + ICON.restart + '</button>' +
      '<button type="button" class="tcgm-btn" data-a="prev" aria-label="Schritt zurück" title="Schritt zurück (←)">' + ICON.prev + '</button>' +
      '<button type="button" class="tcgm-btn play" data-a="play" aria-pressed="false">' + ICON.play + '<span>Abspielen</span></button>' +
      '<button type="button" class="tcgm-btn" data-a="next" aria-label="Schritt vor" title="Schritt vor (→)">' + ICON.next + '</button>' +
      '<span class="tcgm-count" aria-hidden="true"></span>' +
      '</div></div></div>';

    function hudHtml(side, pip, P, name) {
      return '<div class="tcgm-hud" data-side="' + side + '">' +
        '<span class="tcgm-chip tcgm-who"><span class="pip ' + pip + '">' + P + '</span>' + name + (side === 'me' ? ' <em class="tcgm-lbl-long">am Zug</em>' : '') + '</span>' +
        '<span class="tcgm-chip tcgm-pub"><b>0</b><small>Publikum</small></span>' +
        '<span class="tcgm-chip tcgm-app"><span class="tcgm-pips"></span><small><span class="tcgm-lbl-long">Applaus </span><b>0</b></small></span>' +
        '</div>';
    }

    var $ = function (sel) { return host.querySelector(sel); };
    var board = $('.tcgm-board'), probe = $('.tcgm-probe'), layer = $('.tcgm-cards'), stageEl = $('.tcgm-stage');
    var capEl = $('.tcgm-cap'), countEl = $('.tcgm-count'), playBtn = $('[data-a="play"]');
    var prevBtn = $('[data-a="prev"]'), nextBtn = $('[data-a="next"]');
    var phaseEls = host.querySelectorAll('.tcgm-phases li');
    var hud = {opp: $('.tcgm-hud[data-side="opp"]'), me: $('.tcgm-hud[data-side="me"]')};
    var pile = {
      'deck-opp': $('.tcgm-deck[data-side="opp"]'), 'grave-opp': $('.tcgm-grave[data-side="opp"]'),
      'deck-me': $('.tcgm-deck[data-side="me"]'), 'grave-me': $('.tcgm-grave[data-side="me"]')
    };
    var plbl = {};
    host.querySelectorAll('.tcgm-plbl').forEach(function (e) { plbl[e.getAttribute('data-for')] = e; });
    var rampe = $('.tcgm-rampe'), slot = $('.tcgm-slot'), flash = $('.tcgm-flash');
    var pubVal = {opp: null, me: null};

    /* Karten-Elemente */
    var els = {};
    var ids = Object.keys(states[0].cards);
    ids.forEach(function (id) {
      var cs = states[0].cards[id];
      var el = document.createElement('div');
      el.className = 'tcgm-c';
      el.innerHTML = '<div class="tcgm-fx"><div class="tcgm-flip"><div class="tcgm-front">' + (cs.blank ? '' : cardHtml(DEF[cs.def], A)) + '</div>' +
        '<div class="tcgm-back"><img data-src="' + A + 'kartenrueckseite.webp" alt=""></div></div></div>' +
        '<span class="tcgm-badge tcgm-lf">Lampenfieber</span><span class="tcgm-badge tcgm-note"></span><span class="tcgm-badge tcgm-dmg"></span>';
      el._pt = cs.pt ? cs.pt.slice() : null;
      el._ptEl = el.querySelector('.pt');
      layer.appendChild(el);
      els[id] = el;
    });

    /* ---------- Layout ---------- */
    var L = null;
    function layout() {
      var W = board.clientWidth;
      if (!W) return null;
      var cw = probe.getBoundingClientRect().width || 80;
      var ch = cw * R, lw = cw * 0.62, lh = lw * R, pw = lw;
      var pad = clamp(cw * 0.13, 8, 14), gapR = cw * 0.16;
      var rolesW = 4 * cw + 3 * gapR;
      var LST = 0.8, landsWmax = 6 * lw * LST + lh;  // inkl. Überstand getappter Kulissen
      var hudW = 150;
      var wide = (W - 3 * pad - hudW) >= rolesW + landsWmax + cw * 0.3;
      var l = {W: W, cw: cw, ch: ch, lw: lw, lh: lh, pw: pw, pad: pad, gapR: gapR, wide: wide, opp: {}, me: {}};
      var oppHudH = hud.opp.offsetHeight || 30, meHudH = hud.me.offsetHeight || 30;
      var hs, H, midY, midH;
      if (wide) {
        var cx0 = pad * 2 + hudW, cx1 = W - pad;
        var topB = ch * 0.46;
        var oppY = topB + pad * 0.6;
        midY = oppY + ch; midH = Math.max(ch * 0.5, 44);
        var myY = midY + midH;
        hs = cw * 1.02;
        var hh = hs * R;
        var handTop = myY + ch + pad * 1.2;
        H = handTop + hh + pad * 1.4;
        var landsX0 = cx1 - (lh - lw) / 2 - (6 * lw * LST + lw);
        var pgap = Math.max(pw + 8, 84);
        l.opp = {cy: oppY + ch / 2, x0: cx0, lx0: landsX0, lstep: lw * LST, lcy: oppY + ch / 2,
          hud: [pad, pad], deck: [pad + pw / 2, pad + oppHudH + pad + lh / 2], grave: [pad + pw / 2 + pgap, pad + oppHudH + pad + lh / 2],
          hand: {cx: (cx0 + cx1) / 2, cy: topB - 3 - lw * R / 2, s: lw, sp: lw * 0.42}};
        var myPileY = H - pad - lh / 2 - 14;
        l.me = {cy: myY + ch / 2, x0: cx0, lx0: landsX0, lstep: lw * LST, lcy: myY + ch / 2,
          hud: [pad, myY], deck: [pad + pw / 2, myPileY], grave: [pad + pw / 2 + pgap, myPileY],
          hand: {cx: (cx0 + cx1) / 2, cy: handTop + hh / 2, s: hs, sp: Math.min(hs * 0.74, (cx1 - cx0) * 0.6 / 4)}};
        var gapC = ((cx0 + 3 * (cw + gapR)) + (landsX0 - (lh - lw) / 2)) / 2;
        l.stack = [gapC, midY + midH / 2, cw * 0.9];
        l.rampe = [cx0, midY + midH / 2, cx1 - cx0, cx1 - cx0 - 44];
        l.focus = [(cx0 + cx1) / 2, H / 2, Math.min(1.05, H * 0.6 / DH, (cx1 - cx0) * 0.42 / DW)];
      } else {
        var y = pad;
        var oppHud = y; y += oppHudH + pad * 0.7;
        var oppL = y; y += lh + pad * 0.6;
        var oppS = y; y += ch;
        midY = y; midH = Math.max(ch * 0.56, 40); y += midH;
        var myS = y; y += ch + pad * 0.6;
        var myL = y; y += lh + pad * 0.7;
        var myHud = y; y += meHudH + pad * 0.6;
        hs = Math.min(cw * 1.12, (W - 2 * pad) / 3.1);
        var hh2 = hs * R;
        var handC = y + hh2 / 2 + 4; y += hh2 + pad + 6;
        H = y;
        var gx = W - pad - pw / 2, dx = gx - pw - 6;
        var areaW = dx - pw / 2 - 8 - pad;
        var lstep = Math.min(lw * 0.92, (areaW - lh) / 6);
        var lx0 = pad + (lh - lw) / 2;
        var ow = lw * 0.8;
        l.gapR = gapR = clamp((W - 2 * pad - 4 * cw) / 3, cw * 0.16, cw * 0.6);
        l.opp = {cy: oppS + ch / 2, x0: pad, lx0: lx0, lstep: lstep, lcy: oppL + lh / 2, hud: [pad, oppHud],
          deck: [dx, oppL + lh / 2], grave: [gx, oppL + lh / 2],
          hand: {cx: W - pad - ow * 1.1, cy: oppS + ow * R / 2 + 2, s: ow, sp: ow * 0.45}};
        l.me = {cy: myS + ch / 2, x0: pad, lx0: lx0, lstep: lstep, lcy: myL + lh / 2, hud: [pad, myHud],
          deck: [dx, myL + lh / 2], grave: [gx, myL + lh / 2],
          hand: {cx: W / 2, cy: handC, s: hs, sp: Math.min(hs * 0.66, (W - 2 * pad - hs) / 4)}};
        l.stack = [W - pad - cw * 0.55, midY + midH / 2, cw * 0.95];
        l.rampe = [pad, midY + midH / 2, W - 2 * pad, (W - 2 * pad) * 0.5];
        l.focus = [W / 2, H / 2, Math.min(1, H * 0.5 / DH, W * 0.56 / DW)];
      }
      l.H = H; l.midY = midY; l.midH = midH;
      return l;
    }

    function applyLayoutStatics() {
      board.style.height = L.H + 'px';
      board.classList.toggle('tcgm-narrow', !L.wide);
      ['opp', 'me'].forEach(function (side) {
        var p = L[side];
        hud[side].style.left = p.hud[0] + 'px';
        hud[side].style.top = p.hud[1] + 'px';
        ['deck', 'grave'].forEach(function (k) {
          var e = pile[k + '-' + side], c = p[k];
          e.style.width = L.pw + 'px'; e.style.height = L.pw * R + 'px';
          e.style.left = (c[0] - L.pw / 2) + 'px'; e.style.top = (c[1] - L.pw * R / 2) + 'px';
          var lb = plbl[k + '-' + side];
          lb.style.left = c[0] + 'px';
          lb.style.top = (c[1] + L.pw * R / 2 - (L.wide ? 10 : 8)) + 'px';
        });
      });
      rampe.style.left = L.rampe[0] + 'px'; rampe.style.top = L.rampe[1] + 'px'; rampe.style.width = L.rampe[2] + 'px'; rampe.style.setProperty('--lx', L.rampe[3] + 'px');
      var sw = L.stack[2], sh = sw * R;
      slot.style.width = sw + 'px'; slot.style.height = sh + 'px';
      slot.style.left = (L.stack[0] - sw / 2) + 'px'; slot.style.top = (L.stack[1] - sh / 2) + 'px';
    }

    /* Zielposition jeder Karte für einen Zustand */
    function place(s) {
      var P = {};
      var by = function (side, zone) {
        return ids.filter(function (id) { var c = s.cards[id]; return c.own === side && c.z === zone; })
          .sort(function (a, b) { return s.cards[a].o - s.cards[b].o; });
      };
      ['opp', 'me'].forEach(function (side) {
        var g = L[side], dir = side === 'me' ? -1 : 1;
        by(side, 'lands').forEach(function (id, i) {
          var c = s.cards[id];
          P[id] = {x: g.lx0 + L.lw / 2 + i * g.lstep, y: g.lcy, r: c.tap ? 90 : 0, s: L.lw / DW, z: 10 + i};
        });
        by(side, 'stage').forEach(function (id, i) {
          var c = s.cards[id];
          P[id] = {x: g.x0 + L.cw / 2 + i * (L.cw + L.gapR), y: g.cy + (c.atk || c.blk ? dir * L.ch * 0.26 : 0), r: c.tap ? 90 : 0, s: L.cw / DW, z: 30 + i * 2};
        });
        var h = by(side, 'hand'), n = h.length;
        h.forEach(function (id, i) {
          var t = i - (n - 1) / 2;
          P[id] = {x: g.hand.cx + t * g.hand.sp, y: g.hand.cy + t * t * g.hand.s * 0.035, r: t * 5, s: g.hand.s / DW, z: 50 + i};
        });
        var oh = by(side, 'ohand'), m = oh.length;
        oh.forEach(function (id, i) {
          var t = i - (m - 1) / 2;
          P[id] = {x: g.hand.cx + t * g.hand.sp, y: g.hand.cy - t * t * 2, r: -t * 6, s: g.hand.s / DW, z: 50 + i};
        });
        by(side, 'deck').forEach(function (id) { P[id] = {x: g.deck[0], y: g.deck[1], r: 0, s: L.pw / DW, z: 8}; });
        by(side, 'grave').forEach(function (id, i) { P[id] = {x: g.grave[0], y: g.grave[1], r: 0, s: L.pw / DW, z: 12 + i}; });
        by(side, 'stack').forEach(function (id) { P[id] = {x: L.stack[0], y: L.stack[1], r: 0, s: L.stack[2] / DW, z: 70}; });
      });
      // Blocker stellt sich vor den Angreifer
      ids.forEach(function (id) {
        var c = s.cards[id];
        if (c.blk && P[c.blk] && P[id]) P[id].x = P[c.blk].x;
      });
      // Angelegte Requisiten hinter der Rolle
      ids.forEach(function (id) {
        var c = s.cards[id];
        if (c.z === 'att' && P[c.host]) {
          var hp = P[c.host], d = s.cards[c.host].own === 'me' ? -1 : 1;
          P[id] = {x: hp.x + L.cw * 0.07, y: hp.y + d * L.ch * 0.2, r: hp.r, s: hp.s, z: hp.z - 1};
        }
      });
      return P;
    }

    function tf(p) {
      return 'translate(' + (p.x - DW / 2).toFixed(1) + 'px,' + (p.y - DH / 2).toFixed(1) + 'px) rotate(' + p.r + 'deg) scale(' + p.s.toFixed(4) + ')';
    }

    /* ---------- Timer/Effekte ---------- */
    var timers = [], fxEls = [], rafs = [];
    function later(ms, fn) { if (ms <= 0) { fn(); return; } timers.push(setTimeout(fn, ms)); }
    function clearFx() {
      timers.forEach(clearTimeout); timers = [];
      rafs.forEach(cancelAnimationFrame); rafs = [];
      fxEls.forEach(function (e) { if (e.parentNode) e.parentNode.removeChild(e); }); fxEls = [];
      host.querySelectorAll('.tcgm-pips .glow').forEach(function (e) { e.classList.remove('glow'); });
      hud.opp.querySelector('.tcgm-pub').classList.remove('hit');
      hud.me.querySelector('.tcgm-pub').classList.remove('hit');
      flash.getAnimations && flash.getAnimations().forEach(function (a) { a.cancel(); });
      ids.forEach(function (id) {
        var fx = els[id].firstChild;
        fx.getAnimations && fx.getAnimations().forEach(function (a) { a.cancel(); });
        els[id].classList.remove('tcgm-ptup');
      });
    }
    function animNum(el, from, to, delay, dur) {
      if (from === to || dur <= 0) { el.textContent = to; return; }
      later(delay, function () {
        var t0 = performance.now();
        var tick = function (now) {
          var k = clamp((now - t0) / dur, 0, 1);
          el.textContent = Math.round(from + (to - from) * k);
          if (k < 1) rafs.push(requestAnimationFrame(tick));
        };
        rafs.push(requestAnimationFrame(tick));
      });
    }

    /* ---------- Rendern ---------- */
    var cur = 0, shown = null;
    // mode: 0 = sofort, 1 = vorwärts animiert, 2 = rückwärts animiert
    function render(i, mode) {
      if (!L) return;
      if (reduced) mode = 0;
      clearFx();
      var s = states[i];
      var meta = mode === 1 ? (STEPS[i - 1] && STEPS[i - 1].meta) || {} : {};
      var delay = meta.delay || {}, focus = meta.focus || [], flagAt = meta.flagAt || {}, ptAt = meta.ptAt || {};
      var P = place(s);
      if (mode === 0) { host.classList.add('tcgm-instant'); }

      ids.forEach(function (id) {
        var el = els[id], c = s.cards[id], p = P[id];
        if (!p) return;
        var to = tf(p);
        var old = el._p;
        var moved = !old || old.x !== p.x || old.y !== p.y || old.r !== p.r || old.s !== p.s;
        var dl = delay[id] || 0;
        var isFocus = focus.indexOf(id) >= 0;
        var dur = mode === 2 ? 480 : (isFocus ? 1500 : 720);
        el.style.setProperty('--s', p.s.toFixed(4));
        if (mode === 0 || !moved || !el.animate) {
          if (el.getAnimations) el.getAnimations().forEach(function (a) { a.cancel(); });
          el.style.transform = to;
          el.style.zIndex = p.z;
        } else {
          var running = el.getAnimations ? el.getAnimations() : [];
          var from = running.length ? getComputedStyle(el).transform : el.style.transform;
          running.forEach(function (a) { a.cancel(); });
          el.style.transform = to;
          el.style.zIndex = (isFocus || el._zone !== c.z) ? 100 : Math.max(p.z, old ? old.z : 0);
          var kf;
          if (isFocus) {
            var f = {x: L.focus[0], y: L.focus[1], r: 0, s: L.focus[2]};
            kf = [{transform: from, easing: 'cubic-bezier(.3,.6,.3,1)'}, {transform: tf(f), offset: 0.33}, {transform: tf(f), offset: 0.62, easing: 'cubic-bezier(.5,0,.2,1)'}, {transform: to}];
          } else {
            kf = [{transform: from}, {transform: to}];
          }
          var a = el.animate(kf, {duration: dur, delay: dl, easing: isFocus ? 'linear' : 'cubic-bezier(.25,.75,.25,1)', fill: 'backwards'});
          var z = p.z;
          a.onfinish = function () { el.style.zIndex = z; };
        }
        // Zustands-Klassen (Plaketten erst nach der Landung)
        var fd = flagAt[id] != null ? flagAt[id] : (mode === 1 ? dl + (moved ? dur * 0.85 : 0) : 0);
        el.classList.toggle('tcgm-tap', !!c.tap);
        var down = !!c.down;
        if (mode === 1 && moved && down !== el.classList.contains('tcgm-down')) later(dl + dur * 0.2, function () { el.classList.toggle('tcgm-down', down); });
        else el.classList.toggle('tcgm-down', down);
        later(mode === 1 ? fd : 0, function () {
          el.classList.toggle('has-lf', !!c.lf);
          el.classList.toggle('tcgm-atk', !!c.atk);
          el.classList.toggle('tcgm-blk', !!c.blk);
          if (c.note) el.querySelector('.tcgm-note').innerHTML = c.note;
          el.classList.toggle('has-note', !!c.note);
          if (c.dmg) el.querySelector('.tcgm-dmg').textContent = '−' + c.dmg;
          el.classList.toggle('has-dmg', !!c.dmg);
        });
        // Werte zählen
        if (c.pt && el._ptEl) {
          var cur0 = el._pt;
          if (mode === 1 && cur0[0] !== c.pt[0]) {
            var t0 = ptAt[id] != null ? ptAt[id] : dl + 300, k = 0, steps = Math.abs(c.pt[0] - cur0[0]), sg = c.pt[0] > cur0[0] ? 1 : -1;
            var target = c.pt.slice();
            later(t0, function () { el.classList.add('tcgm-ptup'); });
            for (k = 1; k <= steps; k++) {
              (function (k) {
                later(t0 + k * 320, function () { el._pt = [cur0[0] + sg * k, target[1]]; el._ptEl.textContent = el._pt[0] + '/' + el._pt[1]; });
              })(k);
            }
            later(t0 + steps * 320 + 450, function () { el.classList.remove('tcgm-ptup'); });
          } else {
            el._pt = c.pt.slice();
            el._ptEl.textContent = c.pt[0] + '/' + c.pt[1];
          }
        }
        el._p = p; el._zone = c.z;
      });

      // HUD: Publikum, Applaus, Stapel
      ['opp', 'me'].forEach(function (side) {
        var b = hud[side].querySelector('.tcgm-pub b');
        var to = s.pub[side];
        var from = pubVal[side] == null ? to : pubVal[side];
        if (mode === 1 && from !== to) {
          var at = meta.pubAt || 0;
          animNum(b, from, to, at, 700);
          later(at, function () { hud[side].querySelector('.tcgm-pub').classList.add('hit'); });
          later(at + 900, function () { hud[side].querySelector('.tcgm-pub').classList.remove('hit'); });
        } else b.textContent = to;
        pubVal[side] = to;
        var lands = ids.filter(function (id) { var c = s.cards[id]; return c.own === side && c.z === 'lands'; });
        var lit = lands.filter(function (id) { return !s.cards[id].tap; }).length;
        var pipBox = hud[side].querySelector('.tcgm-pips'), appB = hud[side].querySelector('.tcgm-app b');
        var prevLit = pipBox._lit == null ? lit : pipBox._lit;
        var upd = function () {
          while (pipBox.children.length < lands.length) {
            var pp = document.createElement('span');
            pp.className = 'pip ' + (side === 'me' ? 'g' : 'b');
            pipBox.appendChild(pp);
          }
          while (pipBox.children.length > lands.length) pipBox.removeChild(pipBox.lastChild);
          for (var q = 0; q < pipBox.children.length; q++) {
            var pe = pipBox.children[q];
            pe.classList.toggle('on', q < lit);
            if (mode === 1 && lit > prevLit && q < lit) (function (pe, q) {
              later(q * 70, function () { pe.classList.add('glow'); });
              later(q * 70 + 650, function () { pe.classList.remove('glow'); });
            })(pe, q);
          }
          appB.textContent = lit;
        };
        later(mode === 1 ? (meta.pipAt || 0) : 0, upd);
        pipBox._lit = lit;
        var graveN = s.graveBase[side] + ids.filter(function (id) { var c = s.cards[id]; return c.own === side && c.z === 'grave'; }).length;
        plbl['deck-' + side].querySelector('b').textContent = s.deck[side];
        var gb = plbl['grave-' + side].querySelector('b');
        later(mode === 1 ? 600 : 0, function () { gb.textContent = graveN; });
      });
      hud.me.classList.add('turn');

      board.classList.toggle('tcgm-closed', !!s.curtain);
      rampe.classList.toggle('on', s.phase === 2);
      slot.classList.toggle('on', !!s.reaction);
      for (var q = 0; q < phaseEls.length; q++) {
        phaseEls[q].classList.toggle('on', q === s.phase);
        phaseEls[q].classList.toggle('done', q < s.phase);
        if (q === s.phase) phaseEls[q].setAttribute('aria-current', 'step'); else phaseEls[q].removeAttribute('aria-current');
      }
      if (capEl.textContent !== s.cap) capEl.textContent = s.cap;
      countEl.innerHTML = '<span class="tcgm-cl">Schritt </span>' + i + '/' + N;
      prevBtn.disabled = i === 0;

      if (mode === 1 && meta.fx === 'bolt') fxBolt(P.JA, 1500);
      if (mode === 1 && meta.fx === 'lunge') fxLunge('AJ', P.AJ);

      if (mode === 0) { void board.offsetWidth; requestAnimationFrame(function () { host.classList.remove('tcgm-instant'); }); }
      shown = i;
    }

    function fxBolt(p, at) {
      if (!p || !board.animate) return;
      later(at, function () {
        var wrap = document.createElement('div');
        wrap.innerHTML = BOLT;
        var b = wrap.firstChild;
        b.style.left = p.x + 'px'; b.style.top = p.y + 'px';
        board.appendChild(b); fxEls.push(b);
        b.animate([{opacity: 0, transform: 'translateY(-60px) scale(.4)'}, {opacity: 1, transform: 'translateY(0) scale(1.15)', offset: 0.35}, {opacity: 1, transform: 'scale(1)', offset: 0.6}, {opacity: 0, transform: 'scale(1.5)'}],
          {duration: 900, easing: 'ease-out', fill: 'forwards'});
        flash.style.setProperty('--fx', p.x + 'px'); flash.style.setProperty('--fy', p.y + 'px');
        flash.animate([{opacity: 0}, {opacity: 1, offset: 0.12}, {opacity: 0.2, offset: 0.3}, {opacity: 0.8, offset: 0.42}, {opacity: 0}], {duration: 900, easing: 'ease-out'});
        var fx = els.JA.firstChild;
        fx.animate([{transform: 'none', filter: 'none'}, {transform: 'translateX(-14px) rotate(-3deg)', filter: 'brightness(1.8)'}, {transform: 'translateX(12px) rotate(2deg)'},
          {transform: 'translateX(-8px)', filter: 'brightness(1.3)'}, {transform: 'translateX(5px)'}, {transform: 'none', filter: 'none'}], {duration: 600, easing: 'ease-out'});
      });
    }

    function fxLunge(id, p) {
      var el = els[id];
      if (!p || !el.animate) return;
      var hp = hud.opp.querySelector('.tcgm-pub');
      var br = board.getBoundingClientRect(), r = hp.getBoundingClientRect();
      var tx = r.left - br.left + r.width / 2, ty = r.top - br.top + r.height / 2;
      var mid = {x: p.x + (tx - p.x) * 0.55, y: p.y + (ty - p.y) * 0.55, r: L.wide ? -8 : 0, s: p.s * 1.08};
      later(150, function () {
        el.style.zIndex = 100;
        var a = el.animate([{transform: tf(p)}, {transform: tf(mid), offset: 0.4, easing: 'cubic-bezier(.6,0,.4,1)'}, {transform: tf(p)}], {duration: 820, easing: 'cubic-bezier(.4,0,.2,1)'});
        a.onfinish = function () { el.style.zIndex = p.z; };
        var sw = els.SW;
        var sp = sw._p;
        if (sp) sw.animate([{transform: tf(sp)}, {transform: tf({x: sp.x + (mid.x - p.x), y: sp.y + (mid.y - p.y), r: mid.r, s: sp.s * 1.08}), offset: 0.4, easing: 'cubic-bezier(.6,0,.4,1)'}, {transform: tf(sp)}], {duration: 820, easing: 'cubic-bezier(.4,0,.2,1)'});
      });
      later(480, function () {
        var f = document.createElement('div');
        f.className = 'tcgm-float';
        f.textContent = '−4';
        f.style.left = (tx + r.width / 2 + 4) + 'px'; f.style.top = (ty - 18) + 'px';
        board.appendChild(f); fxEls.push(f);
        f.animate([{opacity: 0, transform: 'translateY(10px) scale(.6)'}, {opacity: 1, transform: 'translateY(0) scale(1.1)', offset: 0.2}, {opacity: 1, offset: 0.7}, {opacity: 0, transform: 'translateY(-26px)'}],
          {duration: 1600, easing: 'ease-out', fill: 'forwards'});
        hud.opp.animate([{transform: 'none'}, {transform: 'translateX(-6px)'}, {transform: 'translateX(5px)'}, {transform: 'translateX(-3px)'}, {transform: 'none'}], {duration: 420});
      });
    }

    /* ---------- Ablauf ---------- */
    var playing = false, userPaused = false, visible = false, T = null;
    function go(i, mode) {
      i = clamp(i, 0, N);
      cur = i;
      render(i, mode);
    }
    function schedule() {
      clearTimeout(T);
      if (!playing) return;
      var wait = cur === 0 ? START_WAIT : (cur === N ? HOLD : STEPS[cur - 1].dur);
      T = setTimeout(function () {
        if (!playing) return;
        if (cur === N) {
          if (!loop) { setPlaying(false); return; }
          go(0, 0);
        } else go(cur + 1, 1);
        schedule();
      }, wait);
    }
    function setPlaying(v) {
      playing = v && !reduced;
      playBtn.setAttribute('aria-pressed', playing ? 'true' : 'false');
      playBtn.innerHTML = (playing ? ICON.pause + '<span>Pause</span>' : ICON.play + '<span>Abspielen</span>');
      if (playing) schedule(); else clearTimeout(T);
    }
    function play() { userPaused = false; if (cur === N) go(0, 0); setPlaying(true); }
    function pause() { userPaused = true; setPlaying(false); }
    function toggle() { if (playing) pause(); else play(); }
    function next() { if (playing) pause(); if (cur >= N) go(0, 0); else go(cur + 1, 1); }
    function prev() { if (playing) pause(); if (cur > 0) go(cur - 1, 2); }
    function restart() { var was = playing; go(0, 0); if (was) setPlaying(true); }

    host.querySelector('.tcgm-ctl').addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      var a = b.getAttribute('data-a');
      if (a === 'play') toggle(); else if (a === 'next') next(); else if (a === 'prev') prev(); else if (a === 'restart') restart();
    });
    host.addEventListener('keydown', function (e) {
      if (e.altKey || e.ctrlKey || e.metaKey) return;
      var onBtn = e.target.closest && e.target.closest('button');
      if (e.key === 'ArrowRight') { next(); e.preventDefault(); }
      else if (e.key === 'ArrowLeft') { prev(); e.preventDefault(); }
      else if (e.key === 'Home') { restart(); e.preventDefault(); }
      else if ((e.key === ' ' || e.key === 'k') && !onBtn && !reduced) { toggle(); e.preventDefault(); }
    });

    function applyReduced() {
      reduced = !!mqRM.matches;
      host.classList.toggle('tcgm-rm', reduced);
      if (reduced && playing) setPlaying(false);
    }
    if (mqRM.addEventListener) mqRM.addEventListener('change', applyReduced);
    applyReduced();

    /* Bilder und Spielbrett erst laden, wenn die Demo in die Nähe kommt */
    var loaded = false;
    function loadImages() {
      if (loaded) return; loaded = true;
      board.style.setProperty('--tcgm-mat', 'url("' + A + 'spielbrett.webp")');
      host.querySelectorAll('img[data-src]').forEach(function (img) { img.src = img.getAttribute('data-src'); img.removeAttribute('data-src'); });
    }

    var io = null, ioNear = null, ro = null;
    if ('IntersectionObserver' in window) {
      ioNear = new IntersectionObserver(function (en) { if (en.some(function (x) { return x.isIntersecting; })) { loadImages(); ioNear.disconnect(); } }, {rootMargin: '600px 0px'});
      ioNear.observe(host);
      io = new IntersectionObserver(function (en) {
        en.forEach(function (x) {
          visible = x.isIntersecting && x.intersectionRatio >= 0.4;
          if (visible) { if (opts.autoplay !== false && !userPaused && !reduced && !playing) setPlaying(true); }
          else if (playing) setPlaying(false);
        });
      }, {threshold: [0, 0.4, 0.6]});
      io.observe(host);
    } else loadImages();
    function onVis() { if (document.hidden && playing) setPlaying(false); else if (!document.hidden && visible && !userPaused && opts.autoplay !== false) setPlaying(true); }
    document.addEventListener('visibilitychange', onVis);

    function relayout() {
      var nl = layout();
      if (!nl) return;
      L = nl;
      applyLayoutStatics();
      var l2 = layout(); if (l2) { L = l2; applyLayoutStatics(); }   // HUD-Höhen hängen vom Modus ab
      render(cur, 0);
    }
    if ('ResizeObserver' in window) {
      var lastW = 0;
      ro = new ResizeObserver(function () { var w = board.clientWidth; if (w && w !== lastW) { lastW = w; relayout(); } });
      ro.observe(board);
    } else window.addEventListener('resize', relayout);
    cur = clamp(opts.step | 0, 0, N);
    relayout();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { relayout(); });

    return {
      play: play, pause: pause, toggle: toggle, next: next, prev: prev, restart: restart,
      goTo: function (i, instant) { if (playing) pause(); go(i, instant ? 0 : 1); },
      get step() { return cur; },
      steps: STEPS.map(function (s) { return {phase: PHASES[s.phase], caption: s.cap}; }),
      destroy: function () {
        setPlaying(false); clearFx();
        if (io) io.disconnect(); if (ioNear) ioNear.disconnect(); if (ro) ro.disconnect();
        window.removeEventListener('resize', relayout);
        document.removeEventListener('visibilitychange', onVis);
        if (mqRM.removeEventListener) mqRM.removeEventListener('change', applyReduced);
        host.innerHTML = ''; host.classList.remove('tcgm', 'tcgm-rm');
      }
    };
  };
})();
