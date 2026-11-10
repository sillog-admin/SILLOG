/* 원형 차트(코드형, 분야끼리): 둘레 전체 = 분야(색 띠, 업무가 많은 분야부터 위에서 시계 방향).
   띠 길이 = 업무 수. 띠 사이를 잇는 리본 = 두 분야 업무가 같이 쓴 자료 수(띠 안에서 같이 쓴 자료 비율만큼 차지).
   분야나 리본에 올리면 그것만 진하게, 숫자는 띠 안쪽에 업무 수. */
window.V3D = window.V3D || {};
window.V3D.chord = function (main, data, ui) {
  const NS = 'http://www.w3.org/2000/svg', FONT = '"SUIT","Apple SD Gothic Neo",sans-serif', RAD = Math.PI / 180;
  const el = (n, a, p) => { const e = document.createElementNS(NS, n); for (const k in a || {}) e.setAttribute(k, a[k]); if (p) p.appendChild(e); return e; };
  const f1 = v => v.toFixed(1);

  main.innerHTML = '';
  if (!data.tasks.length) return () => {};
  const themes = data.themes.filter(th => data.tasks.some(t => t.theme === th.id));
  data.tasks.forEach(t => { if (!themes.some(th => th.id === t.theme)) themes.push({ id: t.theme, name: t.theme, color: t.color }); });
  // 분야마다 쓴 자료 모음(종류 이름 + 자료 이름으로 구분)
  const keyOf = (k, it) => k + ':' + (typeof it === 'string' ? it : (it.id ?? it.name ?? JSON.stringify(it)));
  themes.forEach(th => {
    th.tasks = data.tasks.filter(t => t.theme === th.id); th.n = th.tasks.length; th.items = new Set();
    th.tasks.forEach(t => Object.entries(t.items || {}).forEach(([k, arr]) => arr.forEach(it => th.items.add(keyOf(k, it)))));
  });
  // 행렬: 두 분야가 같이 쓴 자료 수. 대각선 = 그 분야만 쓴 자료 수
  // 분야마다 자료별로 쓴 업무 수(버블 크기, 확대 목록)
  themes.forEach(th => { th.use = new Map(); th.tasks.forEach(t => Object.entries(t.items || {}).forEach(([k, arr]) => arr.forEach(it => { const key = keyOf(k, it); const u = th.use.get(key) || { key, k, name: typeof it === 'string' ? it : (it.name ?? it.title ?? String(it.id ?? '')), n: 0, tids: [] }; u.n++; u.tids.push(t.id); th.use.set(key, u); }))); });
  const N = themes.length, M = themes.map(() => themes.map(() => 0));
  for (let i = 0; i < N; i++) for (let j = i + 1; j < N; j++) { let c = 0; themes[i].items.forEach(x => { if (themes[j].items.has(x)) c++; }); M[i][j] = M[j][i] = c; }
  themes.forEach((th, i) => { let solo = 0; th.items.forEach(x => { if (!themes.some((o, j) => j !== i && o.items.has(x))) solo++; }); M[i][i] = solo; });
  themes.forEach((th, i) => { M[i][i] = 0; th.shared = M[i].reduce((a, v) => a + v, 0); });   // 리본은 다른 분야와 같이 쓴 자료만
  const order = themes.map((_, i) => i).sort((a, b) => themes[b].n - themes[a].n);   // 띠 길이와 순서 = 업무 수

  const wrap = document.createElement('div'); wrap.style.cssText = 'position:absolute;inset:0;font-family:' + FONT; main.appendChild(wrap);
  const svg = el('svg', { style: 'display:block;width:100%;height:100%' }, wrap);
  const tip = document.createElement('div');
  tip.style.cssText = 'position:absolute;pointer-events:none;background:#fff;border:1px solid #E6E1DB;border-radius:8px;padding:6px 9px;font-size:12px;color:#24150F;box-shadow:0 2px 8px rgba(36,21,15,.08);display:none;white-space:nowrap';
  wrap.appendChild(tip);
  const showTip = (ev, html) => { tip.innerHTML = html; tip.style.display = 'block'; const b = wrap.getBoundingClientRect(); tip.style.left = (ev.clientX - b.left + 12) + 'px'; tip.style.top = (ev.clientY - b.top + 12) + 'px'; };

  let ribbons = [];
  // 쉬는 때는 리본마다 작은 쪽 분야 색. 분야나 리본을 고르면 그것만 색이 남고 나머지는 연한 회갈색
  const REST = '#D8D0C8';
  const focus = (ti, one) => ribbons.forEach(r => {
    const on = one ? (r.i === one.i && r.j === one.j) : ti !== null ? (r.i === ti || r.j === ti) : false;
    const col = one ? themes[one.i].color : ti !== null ? themes[ti].color : REST;
    const any = ti !== null || !!one;
    const own = !one && ti !== null && ti === emphTi;   // 확대한 분야: 그 분야 색이 드러나게
    r.e.setAttribute('fill', !any ? r.base : on ? (one ? r.base : own ? themes[ti].color : (r.i === ti ? themes[r.j].color : themes[r.i].color)) : REST);
    r.e.setAttribute('fill-opacity', any ? (on ? .9 : .4) : .72);
    if (r.num) r.num.setAttribute('opacity', !any || on ? 1 : 0);
  });
  // 고정 선택: 분야 띠나 리본을 누르면 그대로 진하게 남고, 왼쪽 위 카드에 업무나 같이 쓴 자료가 나옴. 빈 곳을 누르면 풀림
  let pin = null;   // { ti } 또는 { rb }
  const card = document.createElement('div');
  card.style.cssText = 'position:absolute;left:24px;top:16px;width:250px;max-height:70%;overflow:auto;background:#fff;border:1px solid #ECE7E2;border-radius:12px;padding:12px 14px;font-size:12px;color:#4A3E37;box-shadow:0 3px 12px rgba(36,21,15,.08);display:none';
  wrap.appendChild(card);
  const esc = x => String(x).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const kindName = k => data.kinds?.[k]?.name || k;
  const showCard = () => { card.style.display = 'none'; };   // 카드 대신 그 분야 쪽으로 확대한다(zoomTo)
  const showCardOld = () => {
    if (!pin) { card.style.display = 'none'; return; }
    let html = '';
    if (pin.ti != null) {
      const th = themes[pin.ti];
      html = `<div style="display:flex;align-items:center;gap:6px;margin-bottom:8px"><span style="width:9px;height:9px;border-radius:50%;background:${th.color}"></span><b style="font-size:13px">${esc(th.name)}</b><span style="color:#8C837C">업무 ${th.n}개</span></div>`
        + th.tasks.slice().sort((a, b) => (b.mins || 0) - (a.mins || 0)).map(t => `<div data-id="${t.id}" style="padding:5px 0;border-top:1px solid #F2EEEA;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;${t.id === ui.sel ? 'font-weight:700;color:#24150F' : ''}">${esc(t.title)}</div>`).join('');
    } else {
      const { i, j } = pin.rb, A = themes[i], B = themes[j];
      const shared = [...A.items].filter(x => B.items.has(x)).map(x => { const c = x.indexOf(':'); return [x.slice(0, c), x.slice(c + 1)]; });
      html = `<div style="margin-bottom:8px"><b style="font-size:13px">${esc(A.name)}, ${esc(B.name)}</b><div style="color:#8C837C;margin-top:2px">같이 쓴 자료 ${shared.length}개</div></div>`
        + shared.slice(0, 40).map(([k, nm]) => `<div style="padding:5px 0;border-top:1px solid #F2EEEA;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"><span style="color:#8C837C">${esc(kindName(k))}</span>  ${esc(nm)}</div>`).join('')
        + (shared.length > 40 ? `<div style="color:#8C837C;padding-top:5px">외 ${shared.length - 40}개</div>` : '');
    }
    card.innerHTML = html; card.style.display = 'block';
    card.querySelectorAll('[data-id]').forEach(d => d.addEventListener('click', () => ui.open(+d.dataset.id || d.dataset.id)));
  };
  // 확대 보기 왼쪽 목록: 고른 분야의 자료 전부(종류별, 많이 쓴 순). 고리에 다 못 들어간 자료도 여기서 보인다. 버블을 누르면 목록에서 그 자료를 찾아 줌
  const side = document.createElement('div');
  side.style.cssText = 'position:absolute;left:0;top:96px;bottom:16px;width:330px;padding-left:28px;background:linear-gradient(90deg,rgba(255,255,255,.86) 0,rgba(255,255,255,.8) 62%,rgba(255,255,255,0) 100%);overflow:auto;font-size:12px;line-height:1.85;color:#4A3E37;display:none;scrollbar-width:thin;overscroll-behavior:contain;padding-bottom:24px;box-sizing:border-box;-webkit-mask-image:linear-gradient(#000 calc(100% - 36px),transparent);mask-image:linear-gradient(#000 calc(100% - 36px),transparent)';   // 칸 안에서 스크롤, 아래 끝은 흐리게(더 있다는 표시)
  wrap.appendChild(side);
  const fillSide = ti => {
    const th = themes[ti];
    side.innerHTML = Object.keys(data.kinds || {}).map(k => {
      const list = [...th.use.values()].filter(u => u.k === k).sort((a, b) => b.n - a.n);
      if (!list.length) return '';
      return `<div style="margin:12px 0 2px;font-weight:700;color:#2A201B"><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${data.kinds[k].color};margin-right:7px"></span>${esc(kindName(k))} <span style="font-weight:400;color:#9A918A">${list.length}</span></div>`
        + list.map(u => `<div data-k="${esc(u.key)}" title="${esc(u.name)}" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding-left:15px">${esc(u.name)}${u.n > 1 ? ` <span style="color:#9A918A">${u.n}</span>` : ''}</div>`).join('');
    }).join('');
    side.scrollTop = 0;
  };
  // 왼쪽 목록의 자료: 누르면 자료 상세, 우클릭은 메뉴
  const sideItem = e => { const d = e.target.closest?.('[data-k]'); const u = d && emphTi != null ? themes[emphTi].use.get(d.dataset.k) : null; return u ? { item: u.k, name: u.name, tids: u.tids } : null; };
  side.addEventListener('click', e => { const it = sideItem(e); if (it) ui.node?.(it); });
  side.addEventListener('contextmenu', e => { const it = sideItem(e); if (it) ui.menu?.(it, e); });
  const markSide = key => {
    side.querySelectorAll('[data-on]').forEach(d => { d.removeAttribute('data-on'); d.style.fontWeight = ''; d.style.color = ''; });
    const d = [...side.querySelectorAll('[data-k]')].find(q => q.dataset.k === key); if (!d) return;
    d.setAttribute('data-on', ''); d.style.fontWeight = '700'; d.style.color = '#24150F'; d.scrollIntoView({ block: 'center', behavior: 'smooth' });
  };
  // 확대: 분야를 누르면 그 분야 띠와 자료 버블 쪽으로 부드럽게 다가감, 풀면 원래대로
  let zg = null, geo = null;
  const zoomTo = () => {
    if (!zg || !geo) return;
    const th = pin?.ti != null ? themes[pin.ti] : null;
    if (!th) { zg.style.transform = 'translate(0px,0px) scale(1)'; return; }
    const { W, H, cx, cy, R } = geo, mid = (th.a0 + th.a1) / 2, span = Math.min(330, th.a1 - th.a0);
    const k = Math.max(1.35, Math.min(2.4, 1.6 * 70 / Math.max(40, span)));   // 좁은 분야일수록 더 크게
    const px = cx + (R * .78) * Math.cos(mid * RAD), py = cy + (R * .78) * Math.sin(mid * RAD);
    zg.style.transform = `translate(${W / 2 - k * px}px,${H / 2 - k * py}px) scale(${k})`;
  };
  // 변형: 분야를 고르면 그 분야 띠가 둘레의 절반 넘게 넓어지며 오른쪽으로 돌아오고, 그 자리에 자료 이름과 요약이 나타남. 풀면 되돌아감
  let emph = 0, emphTi = null, raf2 = 0, lab = 0, raf3 = 0, hush = false;   // hush: 분야에서 분야로 옮기는 중(기본 글자를 띄우지 않음)   // lab: 확대 글자 진하기(확대가 끝난 뒤 0 → 1)
  const morphTo = (ti, done, D = 650) => {
    const from = emph, to = ti != null ? 1 : 0, t0 = performance.now();
    if (ti != null) { emphTi = ti; fillSide(ti); }
    cancelAnimationFrame(raf2); cancelAnimationFrame(raf3); lab = 0; svg.style.pointerEvents = 'none'; tip.style.display = 'none';   // 움직이는 동안은 올리기를 받지 않음(그림이 커서 아래로 지나가며 색이 바뀌지 않게)
    const step = now => { const k = Math.min(1, (now - t0) / D), e = k < .5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
      emph = from + (to - from) * e; draw(); if (k < 1) raf2 = requestAnimationFrame(step); else { svg.style.pointerEvents = ''; if (to) hush = false; if (!to) { emphTi = null; draw(); } else { const t1 = performance.now(), fadeIn = n2 => { lab = Math.min(1, (n2 - t1) / 220); draw(); if (lab < 1) raf3 = requestAnimationFrame(fadeIn); }; raf3 = requestAnimationFrame(fadeIn); } done?.(); } };
    raf2 = requestAnimationFrame(step);
  };
  let hint = null;   // 다른 보기에서 고른 업무의 분야(확대 없이 진하게만). 다른 것을 고르면 풀림
  const applyPin = () => { pin ? (pin.ti != null ? focus(pin.ti, null) : focus(null, pin.rb)) : focus(hint, null); };
  // 다른 분야로 바로 옮길 때는 풀기와 확대를 반씩(합 650ms) 이어서 한 번의 움직임으로(돌림이 튀지 않게)
  const setPin = p => { hint = null; const was = pin?.ti ?? null; pin = p; const now = pin?.ti ?? null; applyPin(); if (now === was) return; hush = was != null && now != null; if (hush) morphTo(null, () => morphTo(now, null, 325), 325); else morphTo(now); };
  const hide = () => { tip.style.display = 'none'; applyPin(); };
  // 누르기: 띠, 버블, 이름뿐 아니라 그 분야 쪽 영역(가운데 리본 포함) 어디를 눌러도 그 분야. 원 바깥 빈 곳은 풀기
  svg.addEventListener('click', ev => {
    if (!geo?.g) return;
    const p = svg.createSVGPoint(); p.x = ev.clientX; p.y = ev.clientY;
    const q = p.matrixTransform(geo.g.getScreenCTM().inverse()), rr = Math.hypot(q.x, q.y), ang = Math.atan2(q.y, q.x) / RAD;
    const own = ev.target.closest?.('[data-ti]'), hit = own ? +own.getAttribute('data-ti') : rr < geo.outR + 90 ? themes.findIndex(th => ((ang - th.a0 + 1.5) % 360 + 360) % 360 <= th.a1 - th.a0 + 3) : -1;
    if (hit < 0) setPin(null); else if (pin?.ti !== hit) { setPin({ ti: hit }); ui.node?.({ theme: themes[hit].id }); }   // 분야를 누르면 확대와 분야 상세
  });

  // 글자 폭 재기(이름표 자르기, 겹침 피하기)
  const mctx = document.createElement('canvas').getContext('2d');
  const tw = (s, px, wt) => { mctx.font = `${wt || 400} ${px}px ${FONT}`; return mctx.measureText(s).width; };
  const fit = (s, px, w, wt) => { if (tw(s, px, wt) <= w) return s; let n = s.length; while (n > 1 && tw(s.slice(0, n) + '…', px, wt) > w) n--; return s.slice(0, n) + '…'; };
  const overlaps = (b, list, own) => list.some(q => (own === undefined || q.o !== own) && b[0] < q.b[2] && b[2] > q.b[0] && b[1] < q.b[3] && b[3] > q.b[1]);
  function draw() {
    const W = wrap.clientWidth, H = wrap.clientHeight;
    if (W < 50 || H < 50) return;
    svg.setAttribute('width', W); svg.setAttribute('height', H); svg.innerHTML = '';
    // 확대: 원을 키우며 중심을 왼쪽으로 옮겨 고른 분야 띠가 오른쪽에 오게 한다. 확대 끝 모양(Rf, Cxf, Cyf)은 이름표까지 화면 안에 들어오게 정하고,
    // 크기, 중심, 돌림을 같은 emph 로 한 번에 옮긴다. 글자 크기는 그대로(화면 배율을 쓰지 않음)
    const ez = emphTi != null ? emph : 0, BAND = 14, R0 = Math.max(90, Math.min(W / 2 - 250, H / 2 - 130)), LM = Math.min(220, W * .2);
    const Rf = Math.max(R0 * 1.3, H * .62), Cxf = W - 64 - LM - Rf, Cyf = H / 2 + 10;
    const R = R0 + (Rf - R0) * ez, cx = W / 2 + (Cxf - W / 2) * ez, cy = H / 2 + (Cyf - H / 2) * ez;
    const textOut = hush ? 0 : Math.max(0, 1 - ez * 10), textIn = emphTi != null && emph >= 1 ? lab : 0;   // 기본 글자는 움직이기 전에 사라지고, 확대 글자는 끝에 나타남
    // 확대 끝에서 고리 자리(고른 분야 가운데로부터 각도)마다 이름표에 쓸 수 있는 길이. 70px 이 안 되는 자리에는 점을 두지 않음
    const L0 = Rf + BAND + 31;
    const room = a => { const c = Math.cos(a * RAD), s = Math.sin(a * RAD); let L = LM;
      if (c > 1e-3) L = Math.min(L, (W - 16 - Cxf) / c - L0);
      if (s < -1e-3) L = Math.min(L, (Cyf - 14) / -s - L0);
      if (s > 1e-3) L = Math.min(L, (H - 48 - Cyf) / s - L0);
      return Cxf + (Rf + BAND + 20) * c < 290 ? 0 : L; };   // 왼쪽 목록과 겹치는 자리는 쓰지 않음
    let wLo = 0, wHi = 0; while (wLo > -80 && room(wLo - .5) >= 70) wLo -= .5; while (wHi < 80 && room(wHi + .5) >= 70) wHi += .5;
    zg = el('g', {}, svg); geo = { W, H, cx, cy, R };
    const g = el('g', { transform: `translate(${f1(cx)},${f1(cy)})` }, zg); geo.g = g; geo.outR = R + BAND + 10 + 13 * Object.keys(data.kinds || {}).length + 12;
    const P = (rr, a) => [rr * Math.cos(a * RAD), rr * Math.sin(a * RAD)];
    // 둘레 나누기: 분야 사이 틈 GAP, 나머지를 자료 수 비율로
    const GAP = 3, total = themes.reduce((a, th) => a + th.n, 0) || 1, span = 360 - GAP * N;
    // 고른 분야 무게: emph 에 따라 둘레의 55% 까지
    const wOf = i => { const th = themes[i]; if (i !== emphTi || !emph) return th.n; const target = .55 / .45 * Math.max(1, total - th.n); return th.n + (Math.max(th.n, target) - th.n) * emph; };
    const wt = order.reduce((q, i) => q + wOf(i), 0);
    let a = -90 + GAP / 2;
    order.forEach(i => { const th = themes[i]; th.a0 = a; th.a1 = a + span * wOf(i) / wt; a = th.a1 + GAP; });
    if (emphTi != null && emph) { const m = (themes[emphTi].a0 + themes[emphTi].a1) / 2, rot = -((m % 360) + 360) % 360, r2 = (rot < -180 ? rot + 360 : rot) * emph; themes.forEach(th => { th.a0 += r2; th.a1 += r2; }); }
    // 각 분야 띠 안에서 상대 분야별 몫(상대 순서도 둘레 순서대로)
    const seg = themes.map(() => ({}));
    order.forEach(i => { const th = themes[i]; let c = th.a0; const k = (th.a1 - th.a0) / (th.shared || 1);
      // 자기 몫은 가운데 오도록: 앞쪽 상대들, 자기, 뒤쪽 상대들 순
      const pos = order.indexOf(i), seq = [...order.slice(pos + 1), ...order.slice(0, pos)].reverse();
      [...seq.slice(0, Math.floor(seq.length / 2)), i, ...seq.slice(Math.floor(seq.length / 2))].forEach(j => { const w = M[i][j] * k; seg[i][j] = [c, c + w]; c += w; }); });
    ribbons = [];
    // 확대하는 동안 리본은 흐려져 왼쪽 목록과 고리가 읽히게. 리본 숫자는 기본 글자와 함께 먼저 사라짐
    const fade = 1;   // 리본마다 따로 흐리게(아래): 확대한 분야의 리본은 진하게 남기고 나머지만 옅게
    const rg = el('g', { opacity: fade }, g), ng = el('g', { opacity: textOut.toFixed(2) }, g), r = R + 5;   // 리본은 분야 띠 안쪽 끝(R+4)보다 1px 더 들어가 띠 밑에 겹침(흰 틈 없이)
    const pt = a => P(r, a).map(f1).join(' ');
    const rnum = [];   // 리본 숫자 후보(나중에 겹치지 않는 것만 놓음)
    for (let i = 0; i < N; i++) for (let j = i + 1; j < N; j++) {
      const v = M[i][j]; if (!v) continue;
      const [s0, s1] = seg[i][j], [t0, t1] = seg[j][i];
      const big0 = s1 - s0 > 180 ? 1 : 0, big1 = t1 - t0 > 180 ? 1 : 0;
      const d = `M${pt(s0)} A${f1(r)} ${f1(r)} 0 ${big0} 1 ${pt(s1)} Q0 0 ${pt(t0)} A${f1(r)} ${f1(r)} 0 ${big1} 1 ${pt(t1)} Q0 0 ${pt(s0)}Z`;
      const small = themes[i].n <= themes[j].n ? themes[i] : themes[j];
      const e = el('path', { d, fill: small.color, 'fill-opacity': .72 }, rg);
      const rb = { e, i, j, base: small.color };
      // 같이 쓴 자료 수: 리본이 굵으면 숫자 후보(가운데, 양 끝 가까이)
      if (textOut > 0 && v >= 5 && ((s1 - s0) * RAD * r > 14 || (t1 - t0) * RAD * r > 14)) {
        // 후보: 리본 가운데 줄(두 끝 가운데를 잇는 곡선, 조절점 0,0) 위, 가운데부터 양 끝 쪽으로
        const [ax, ay] = P(r, (s0 + s1) / 2), [bx, by] = P(r, (t0 + t1) / 2);
        const cand = [.5, .4, .6, .3, .7, .22, .78, .14, .86].map(t => [(1 - t) * (1 - t) * ax + t * t * bx, (1 - t) * (1 - t) * ay + t * t * by]);
        rnum.push({ rb, v, cand });
      }
      const html = `<b>${themes[i].name}, ${themes[j].name}</b> 같이 쓴 자료 ${v}개`;
      // 분야를 확대한 동안 옅게 물린 리본은 말풍선을 띄우지 않는다 (목록과 이름표를 가리던 '같이 쓴 자료 N개')
      e.addEventListener('mouseenter', ev => { if (emphTi != null) return; focus(null, rb); showTip(ev, html); });
      e.addEventListener('mousemove', ev => { if (emphTi == null) showTip(ev, html); });
      e.addEventListener('mouseleave', hide);
      e.style.cursor = 'pointer';
      ribbons.push(rb);
      if (emphTi != null) e.setAttribute('opacity', ((rb.i === emphTi || rb.j === emphTi) ? 1 - .45 * emph : 1 - .9 * emph).toFixed(2));
    }
    // 리본 숫자: 큰 것부터, 다른 숫자와 겹치면 다음 후보, 다 겹치면 숫자 없이(올리면 말풍선)
    // 자리마다 감점: 글자 상자 9점 중 자기 리본 밖인 점(2점씩), 경계가 상자를 지나가는 다른 리본(1점씩). 가장 덜 걸리는 자리
    const robst = [], sp = svg.createSVGPoint(), inF = (e, x, y) => { sp.x = x; sp.y = y; return e.isPointInFill(sp); };
    const cost = (rb, x, y, hw) => { const pts = []; for (const dx of [-hw, 0, hw]) for (const dy of [-8, 0, 8]) pts.push([x + dx, y + dy]);
      let c = 0; pts.forEach(([px, py]) => { if (!inF(rb.e, px, py)) c += 2; });
      ribbons.forEach(o => { if (o === rb) return; const n = pts.filter(([px, py]) => inF(o.e, px, py)).length; if (n && n < pts.length) c++; });
      return c; };
    rnum.sort((p2, q2) => q2.v - p2.v).forEach(o => {
      const s = '자료 ' + o.v, hw = tw(s, 12, 700) / 2 + 4;
      let c = null, best = 1e9;
      o.cand.forEach(([x, y]) => { if (overlaps([x - hw, y - 10, x + hw, y + 10], robst)) return; const k = cost(o.rb, x, y, hw - 4); if (k < best) { best = k; c = [x, y]; } });
      if (!c) return;
      robst.push({ b: [c[0] - hw, c[1] - 10, c[0] + hw, c[1] + 10] });
      o.rb.num = el('text', { x: f1(c[0]), y: f1(c[1]), 'text-anchor': 'middle', 'dominant-baseline': 'middle', 'font-size': 12, 'font-weight': 700, fill: '#2A201B', 'pointer-events': 'none' }, ng);
      o.rb.num.textContent = s;
    });
    const obst = [], allB = [], names = [];   // 바깥 점 자리(글자가 피할 곳), 묶음 버블, 분야 이름 후보
    const fsz = 11, bOp = emphTi != null ? Math.max(0, 1 - emph * 2.5) : 1;   // 고르지 않은 분야의 점은 확대 앞부분에 사라짐
    // 분야 띠, 자료 버블, 이름
    order.forEach(i => {
      const th = themes[i], big = th.a1 - th.a0 > 180 ? 1 : 0, r1 = R + 4, r2 = R + 4 + BAND;
      const [ax, ay] = P(r2, th.a0), [bx, by] = P(r2, th.a1), [qx, qy] = P(r1, th.a1), [dx, dy] = P(r1, th.a0);
      const ag = el('g', { 'data-ti': i }, g);
      el('path', { d: `M${f1(ax)} ${f1(ay)} A${f1(r2)} ${f1(r2)} 0 ${big} 1 ${f1(bx)} ${f1(by)} L${f1(qx)} ${f1(qy)} A${f1(r1)} ${f1(r1)} 0 ${big} 0 ${f1(dx)} ${f1(dy)}Z`, fill: th.color, opacity: emphTi != null && i !== emphTi ? (1 - .7 * emph).toFixed(2) : 1 }, ag);
      // 자료 버블: 자료 하나가 버블 하나. 분야 띠 바깥 둘레를 따라 종류 순(주제 → 산출물)으로 늘어놓음.
      // 색 = 자료 범례, 크기 = 그 분야에서 그 자료를 쓴 업무 수. 둘레에 다 못 들어가면 많이 쓴 자료부터 채움
      const mid = (th.a0 + th.a1) / 2, na = ((mid % 360) + 360) % 360, right = na < 90 || na > 270;
      const use = th.use;
      // 층: 자료 종류마다 고리 한 겹. 진한 종류(주제)가 안쪽, 연한 종류가 바깥
      const KO = Object.keys(data.kinds || {}), BR = R + BAND + 10, STEP = 13, rOf = n => 2.2 + 3.6 * Math.sqrt(Math.min(n, 6) / 6);
      const sel = i === emphTi && emph > 0;
      const bundles = [];   // 묶음 버블: (종류, 같이 가는 리본 방향)이 같은 자료를 하나로
      KO.forEach((k, layer) => {
        const LR = BR + layer * STEP + 5, arcLen = (th.a1 - th.a0) * RAD * LR;
        // 자리 = 데이터: 그 자료를 같이 쓴 분야로 가는 리본이 붙는 자리(여러 분야면 같이 쓴 자료가 가장 많은 분야), 이 분야만 쓴 자료는 이 분야 자기 몫 자리
        const anchorOf = u => { let best = -1; themes.forEach((o, j) => { if (j !== i && o.items.has(u.key) && (best < 0 || M[i][j] > M[i][best])) best = j; }); return best < 0 ? i : best; };
        const toPx = a2 => (a2 - th.a0) * RAD * LR;
        // 묶음: 같은 (종류, 리본 방향) 자료를 버블 하나로. 자리는 그 리본 자리의 가운데, 크기는 자료 수의 제곱근
        const allK = [...use.values()].filter(u => u.k === k), bj = new Map();
        allK.forEach(u => { const j = anchorOf(u); if (!bj.has(j)) bj.set(j, []); bj.get(j).push(u); });
        const bw = [...bj].map(([j, arr]) => { const [s0, s1] = seg[i][j], c = arr.length, lab = c > 1 ? String(c) : '';
          return { arr, c, k, lab, r: Math.min(5.8, 2.4 + 3.4 * Math.sqrt(Math.min(c, 16) / 16)), ex: lab ? 3 + 6.5 * lab.length : 0, s: (toPx(s0) + toPx(s1)) / 2 }; }).sort((p2, q2) => p2.s - q2.s);
        let e2 = 0; bw.forEach(w => { w.s = Math.max(w.s, e2 + w.r + .5); e2 = w.s + w.r + w.ex + .5; });
        let l2 = arcLen; for (let q = bw.length - 1; q >= 0; q--) { const w = bw[q]; w.s = Math.min(w.s, l2 - w.r - w.ex - .5); l2 = w.s - w.r - .5; }
        bw.forEach(w => { w.LR = LR; bundles.push(w); });
      });
      // 고른 분야: 자료를 종류 순(안에서는 많이 쓴 순)으로 한 줄 고리에 늘어놓고 바깥으로 이름(방사형 글자).
      // 고리는 확대 끝에서 이름표가 화면 안에 들어오는 각도 창(wLo~wHi) 안에만, 자리는 확대 끝 크기 기준이라 움직이는 동안 바뀌지 않음
      const rpos = new Map();
      const groups = [];
      if (sel) {
        const RR = BR + 10, RRf = Rf + BAND + 20, GAPPX = 18, SLOT = 16, kinds = KO.map(k => ({ k, list: [...use.values()].filter(u => u.k === k).sort((a, b) => b.n - a.n) })).filter(o => o.list.length);
        const arcLen = (wHi - wLo) * RAD * RRf - GAPPX * (kinds.length - 1);
        const wsum = kinds.reduce((q, o) => q + Math.sqrt(o.list.length), 0) || 1, da = SLOT / 2 / RRf / RAD, place = [];
        let cur = 0;
        kinds.forEach(o => {
          const cap = Math.max(Math.min(1, o.list.length), Math.floor(arcLen * Math.sqrt(o.list.length) / wsum / SLOT)), part = o.list.slice(0, cap);
          const g0 = cur;
          part.forEach(u => { cur += da; place.push([u, cur]); cur += da; });
          groups.push({ k: o.k, a0: g0, a1: cur, n: o.list.length, shown: part.length });
          cur += GAPPX / RRf / RAD;
        });
        cur -= GAPPX / RRf / RAD;
        const off = mid + (wLo + wHi) / 2 - cur / 2;   // 창 가운데에
        place.forEach(([u, a2]) => { const [x, y] = P(RR, off + a2); rpos.set(u, { x, y, r: rOf(u.n), a: off + a2 }); });
        groups.forEach(gq => { gq.a0 += off; gq.a1 += off; });
      }
      const lerp = (p2, q2, k2) => p2 + (q2 - p2) * k2;
      // 확대하는 동안 묶음 버블은 사라지고, 고리 버블은 띠에서 제자리로 나오며 나타남
      (sel ? [...rpos.keys()] : []).forEach(u => {
        const B = rpos.get(u), [sx, sy] = P(R + BAND + 4, B.a), x = lerp(sx, B.x, emph), y = lerp(sy, B.y, emph), op = emph;
        if (op <= .02) return;
        const r = B.r, b = el('circle', { cx: f1(x), cy: f1(y), r: f1(r), fill: data.kinds[u.k].color, opacity: op.toFixed(2) }, ag);
        const html2 = `<b>${u.name}</b><br><span style="color:#8C837C">${data.kinds[u.k].name}, ${th.name} 업무 ${u.n}개에서 씀</span>`;
        b.addEventListener('mouseenter', ev => { ev.stopPropagation(); showTip(ev, html2); }); b.addEventListener('mousemove', ev => showTip(ev, html2));
        b.addEventListener('click', ev => { if (pin?.ti === i) { ev.stopPropagation(); markSide(u.key); ui.node?.({ item: u.k, name: u.name, tids: u.tids }); } });   // 자료 상세
        b.addEventListener('contextmenu', ev => { ev.stopPropagation(); ui.menu?.({ item: u.k, name: u.name, tids: u.tids }, ev); });
        if (B && textIn > 0) {
          const ang = ((B.a % 360) + 360) % 360, flip = ang > 90 && ang < 270, [lx2, ly2] = P(BR + 10 + r + 5, B.a);
          const tl = el('text', { x: f1(lx2), y: f1(ly2), 'text-anchor': flip ? 'end' : 'start', 'dominant-baseline': 'middle', 'font-size': fsz, fill: '#4A3E37', opacity: textIn.toFixed(2), transform: `rotate(${f1(flip ? B.a + 180 : B.a)} ${f1(lx2)} ${f1(ly2)})`, 'pointer-events': 'none' }, ag);
          tl.textContent = fit(u.name, fsz, Math.max(40, room(B.a - mid)));
        }
      });
      if (bOp > .02) bundles.forEach(w => {
        const a2 = th.a0 + w.s / w.LR / RAD, [x, y] = P(w.LR, a2), kd = data.kinds[w.k];
        const bb = el('circle', { cx: f1(x), cy: f1(y), r: f1(w.r), fill: kd.color, opacity: bOp.toFixed(2) }, ag);
        const names2 = w.arr.slice().sort((p2, q2) => q2.n - p2.n).map(u => esc(u.name)), nm = names2.slice(0, 3).join(', ') + (names2.length > 3 ? ` 외 ${names2.length - 3}개` : '');
        const html3 = `<b>${esc(kd.name)} ${w.c}개</b><br><span style="color:#8C837C">${th.name}, ${nm}</span>`;
        bb.addEventListener('mouseenter', ev => showTip(ev, html3)); bb.addEventListener('mousemove', ev => showTip(ev, html3));
        const own = {}; obst.push({ b: [x - w.r - 1, y - w.r - 1, x + w.r + 1, y + w.r + 1], o: own });
        allB.push({ w, ag, a2, own, th });
      });
      // 종류 구간 머리: 고리 안쪽에 종류 색 짧은 호와 이름, 개수(다 못 보이면 '보이는 수 / 전체')
      if (sel && textIn > 0) groups.forEach(gq => {
        const ri = BR + 2, big = gq.a1 - gq.a0 > 180 ? 1 : 0, [x0, y0] = P(ri, gq.a0), [x1, y1] = P(ri, gq.a1);
        el('path', { d: `M${f1(x0)} ${f1(y0)} A${f1(ri)} ${f1(ri)} 0 ${big} 1 ${f1(x1)} ${f1(y1)}`, fill: 'none', stroke: data.kinds[gq.k].color, 'stroke-width': 2, 'stroke-linecap': 'round', opacity: textIn.toFixed(2) }, ag);
        const am = gq.a0, flip = ((am % 360) + 360) % 360 > 90 && ((am % 360) + 360) % 360 < 270, [hx, hy] = P(R + 4 - 7, am);   // 글 끝을 띠 안쪽 가장자리보다 7px 안에(띠를 덮지 않게)
        const ht = el('text', { x: f1(hx), y: f1(hy), 'text-anchor': flip ? 'start' : 'end', 'dominant-baseline': 'middle', 'font-size': 11.5, 'font-weight': 700, fill: '#4A3E37', opacity: textIn.toFixed(2), transform: `rotate(${f1(flip ? am + 180 : am)} ${f1(hx)} ${f1(hy)})`, 'pointer-events': 'none' }, ag);
        ht.textContent = `${data.kinds[gq.k].name} ${gq.shown < gq.n ? gq.shown + '/' + gq.n : gq.n}`;
      });
      // 분야 이름 후보: 띠 바로 바깥, 가로 글자(자리는 아래에서 점, 다른 이름과 겹치지 않게 정함)
      if (textOut > 0) names.push({ th, ag, mid, right, w: tw(th.name, 13.5, 700) + 6 + tw('업무 ' + th.n, 12) });
      const html = `<b>${th.name}</b> 업무 ${th.n}개, 자료 ${th.items.size}개`;
      ag.addEventListener('mouseenter', ev => { focus(i, null); showTip(ev, html); });
      ag.addEventListener('contextmenu', ev => ui.menu?.({ theme: th.id }, ev));
      ag.addEventListener('mousemove', ev => showTip(ev, html));
      ag.addEventListener('mouseleave', hide);
      ag.style.cursor = 'pointer';
    });
    // 분야 이름: 띠 바로 바깥에서 시작해 점과 겹치면 바깥으로 조금씩, 같은 쪽 이름끼리는 위아래로 벌림
    const boxAt = (o, x, y) => o.right ? [x, y - 10, x + o.w, y + 10] : [x - o.w, y - 10, x, y + 10];
    names.forEach(o => {
      let rr = R + BAND + 12;
      for (let q = 0; q < 24; q++) { const [x, y] = P(rr, o.mid); if (!overlaps(boxAt(o, x, y), obst)) break; rr += 5; }
      o.rr = rr; [o.x, o.y] = P(rr, o.mid);
    });
    [true, false].forEach(side2 => {
      const s = names.filter(o => o.right === side2).sort((p2, q2) => p2.y - q2.y), lo = -cy + 14, hi = H - cy - 14;
      for (let q = 0; q < s.length; q++) s[q].y = Math.max(s[q].y, q ? s[q - 1].y + 20 : lo);
      for (let q = s.length - 1; q >= 0; q--) s[q].y = Math.min(s[q].y, q < s.length - 1 ? s[q + 1].y - 20 : hi);
      s.forEach(o => { const xx = Math.sqrt(Math.max(0, o.rr * o.rr - o.y * o.y)); if (Math.abs(o.y - P(o.rr, o.mid)[1]) > .5) o.x = (o.right ? 1 : -1) * Math.max(xx, 4); });
    });
    names.forEach(o => {
      // 화면 가장자리까지 남는 폭: 넘치면 '업무 N' 을 빼고, 그래도 넘치면 이름을 줄임(전체 이름은 올리면 말풍선)
      const avail = o.right ? W - 8 - (cx + o.x) : cx + o.x - 8, nmW = tw(o.th.name, 13.5, 700), numW = 6 + tw('업무 ' + o.th.n, 12);
      const withNum = nmW + numW <= avail, name = withNum || nmW <= avail ? o.th.name : fit(o.th.name, 13.5, Math.max(20, avail), 700);
      o.w = withNum ? nmW + numW : tw(name, 13.5, 700);
      const bx2 = boxAt(o, o.x, o.y); obst.push({ b: bx2 });
      // 띠에서 멀리 밀려난 이름: 띠 바깥 끝에서 이름 상자 가장 가까운 곳까지 가는 선
      const [px, py] = P(R + BAND + 6, o.mid), ex = Math.min(Math.max(px, bx2[0] - 3), bx2[2] + 3), ey = Math.min(Math.max(py, bx2[1] + 1), bx2[3] - 1);
      if (Math.hypot(ex - px, ey - py) > 28) el('line', { x1: f1(px), y1: f1(py), x2: f1(ex), y2: f1(ey), stroke: '#CFC6BE', 'stroke-width': 1, opacity: textOut.toFixed(2), 'pointer-events': 'none' }, o.ag);
      const t = el('text', { x: f1(o.x), y: f1(o.y), 'text-anchor': o.right ? 'start' : 'end', 'dominant-baseline': 'middle', 'font-size': 13.5, 'font-weight': 700, fill: '#2A201B', opacity: textOut.toFixed(2) }, o.ag);
      t.textContent = name;
      if (withNum) { const n = el('tspan', { 'font-weight': 400, fill: '#8C837C', dx: 6, 'font-size': 12 }, t); n.textContent = '업무 ' + o.th.n; }
    });
    // 묶음 버블 숫자: 큰 수부터, 버블 뒤(시계 방향) 또는 앞에. 다른 점, 이름, 숫자와 겹치면 숫자 없이(올리면 말풍선)
    if (textOut > 0) allB.filter(b => b.w.lab).sort((p2, q2) => q2.w.c - p2.w.c).forEach(b => {
      const { w } = b, hw = tw(w.lab, 11) / 2 + 2;
      const spot = sgn => { const [x, y] = P(w.LR, b.a2 + sgn * (w.r + 3 + hw) / w.LR / RAD); return [x, y, [x - hw - 2, y - 9, x + hw + 2, y + 9]]; };
      const c = [spot(1), spot(-1)].find(q => !overlaps(q[2], obst, b.own)); if (!c) return;
      obst.push({ b: c[2] });
      const tt = el('text', { x: f1(c[0]), y: f1(c[1]), 'text-anchor': 'middle', 'dominant-baseline': 'central', 'font-size': 11, fill: '#6E6862', opacity: textOut.toFixed(2), 'pointer-events': 'none' }, b.ag); tt.textContent = w.lab;
    });
    // 확대 머리: 분야 이름과 요약, 전체 보기(확대가 끝날 때 나타남)
    if (emphTi != null && textIn > 0) {
      const th = themes[emphTi];
      const cg = el('g', { opacity: textIn.toFixed(2), style: 'cursor:pointer' }, svg);
      const c1 = el('text', { x: 28, y: 34, 'font-size': 18, 'font-weight': 700, fill: th.color }, cg); c1.textContent = fit(th.name, 18, Math.min(420, W - 56), 700);
      const c2 = el('text', { x: 28, y: 56, 'font-size': 12.5, fill: '#6E6862' }, cg); c2.textContent = `업무 ${th.n}개, 자료 ${th.items.size}개, 같이 쓴 분야 ${themes.filter((o, j) => j !== emphTi && M[emphTi][j] > 0).length}곳`;
      const c3 = el('text', { x: 28, y: 78, 'font-size': 12, fill: '#9A918A' }, cg); c3.textContent = '‹ 전체 보기';
      cg.addEventListener('click', ev => { ev.stopPropagation(); setPin(null); });
    }
    side.style.display = textIn > 0 ? 'block' : 'none'; side.style.opacity = textIn.toFixed(2);
    applyPin();
  }
  // 다른 보기에서 고른 업무가 있으면 확대하지 않고 그 업무의 분야만 진하게 표시한다(누르면 그때 확대)
  if (ui.sel) { const t = data.tasks.find(q => q.id === ui.sel), ti = t ? themes.findIndex(th => th.id === t.theme) : -1; if (ti >= 0) hint = ti; }
  const ro = new ResizeObserver(draw); ro.observe(wrap); draw(); showCard();
  return () => { ro.disconnect(); wrap.remove(); };
};
