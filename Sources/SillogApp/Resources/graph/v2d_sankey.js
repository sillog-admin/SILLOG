/* 흐름 보기: 분야(왼쪽 막대) -> 업무 종류(마디) -> 업무(업무 종류끼리 묶어 시작일 순) -> 자료 종류(오른쪽 끝)로 흐르는 4단 산키 그림. 앞 두 구간은 덩어리 띠, 업무 -> 자료 종류는 업무마다. 가운데 마디와 오른쪽 막대는 위아래로 끌 수 있음. 업무 이름은 업무 막대 오른쪽에 왼쪽 정렬로 쓰고, 줄이 많으면 줄 높이와 글자를 줄여 칸 안에 맞춤. 윗줄(주 칸)은 화면 맨 위에 고정. */
window.V3D = window.V3D || {};
window.V3D.sankey = function (main, data, ui) {
  const vivid = hex => {   // 분야 색을 유리 위에서 맑게: 채도 ×1.4, 밝기 조금 올림
    const n = parseInt(String(hex).replace('#', ''), 16); if (isNaN(n)) return hex;
    let r = (n >> 16 & 255) / 255, g = (n >> 8 & 255) / 255, b = (n & 255) / 255;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b); let h = 0, s = 0, l = (mx + mn) / 2;
    if (mx !== mn) { const d = mx - mn; s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
      h = mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4; h /= 6; }
    s = Math.min(1, s * 1.55); l = Math.min(0.52, Math.max(0.44, l * 1.05));   // 맑은 보석색: 채도 높게, 밝기는 중간
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q, f = t => { t = (t + 1) % 1; return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p; };
    return '#' + [f(h + 1 / 3), f(h), f(h - 1 / 3)].map(v => Math.round(v * 255).toString(16).padStart(2, '0')).join('');
  };
  const pastel = hex => {   // 분야 색을 흰색과 40% 섞은 파스텔 (레퍼런스 띠 톤)
    const n = parseInt(String(hex).replace('#', ''), 16); if (isNaN(n)) return hex;
    const m = v => Math.round(v + (255 - v) * .4).toString(16).padStart(2, '0');
    return '#' + m(n >> 16 & 255) + m(n >> 8 & 255) + m(n & 255);
  };
  const NS = 'http://www.w3.org/2000/svg', STRIP = 30, GAP = 16, DAY = 864e5;
  let MX = 40, MR = 40;
  const el = (n, a, p) => { const e = document.createElementNS(NS, n); for (const k in a || {}) e.setAttribute(k, a[k]); if (p) p.appendChild(e); return e; };
  const now = new Date();
  const toDay = w => { const [m, d] = w.split(' ')[0].split('/').map(Number); let y = now.getFullYear(); if (m > now.getMonth() + 2) y--; return Math.floor(Date.UTC(y, m - 1, d) / DAY); };
  const hm = m => m >= 60 ? Math.floor(m / 60) + '시간' + (m % 60 ? ' ' + (m % 60) + '분' : '') : m + '분';

  const ts = data.tasks.filter(t => t.sessions.length).map(t => {
    const ds = t.sessions.map(s => toDay(s.when)), ss = t.sessions.slice().sort((a, b) => a.d - b.d);
    return { t, first: Math.min(...ds), mins: Math.max(t.mins || 0, 1), fw: ss[0].when, lw: ss[ss.length - 1].when };
  });
  main.innerHTML = '';
  if (!ts.length) return () => {};
  const lo = Math.min(...ts.map(x => x.first)), hi = Math.max(...data.tasks.flatMap(t => t.sessions.map(s => toDay(s.when))));
  const mon = d => d - ((d + 3) % 7);
  const nW = (mon(hi) - mon(lo)) / 7 + 1, byDay = nW < 6;
  const colOf = d => byDay ? d - lo : (mon(d) - mon(lo)) / 7;
  ts.forEach(x => x.col = colOf(x.first));

  const wrap = document.createElement('div');
  wrap.style.cssText = 'position:absolute;inset:0;background:transparent;overflow:hidden;font-family:"SUIT",-apple-system,"Apple SD Gothic Neo",sans-serif';
  const stripSvg = el('svg', { style: 'position:absolute;left:0;top:0;width:100%;height:' + STRIP + 'px;z-index:2' });
  const body = document.createElement('div');
  body.style.cssText = 'position:absolute;left:0;right:0;bottom:0;top:' + STRIP + 'px;overflow:hidden';
  const svg = el('svg', { style: 'display:block;user-select:none' }); body.appendChild(svg);
  const tip = document.createElement('div');
  tip.style.cssText = 'position:absolute;z-index:5;pointer-events:none;display:none;background:#fff;color:#24150F;border:1px solid #E6E1DB;box-shadow:0 2px 8px rgba(36,21,15,.06);font-size:12px;line-height:1.5;padding:7px 10px;border-radius:8px;max-width:260px';
  wrap.append(body, stripSvg, tip); main.appendChild(wrap);

  const NK = (th, ty) => th + '\u0001' + ty;
  ts.forEach(x => { x.type = x.t.type || '기타'; x.nk = NK(x.t.theme, x.type); });

  let morphFrom = null, ovGeo = null, hoverId = null, hoverTheme = null, hoverNode = null, pinId = null, ribs = [], bands = [], hlG = null, pathOf = null;
  // 강조: 업무를 올리거나 누르면 오른쪽 띠뿐 아니라 왼쪽(분야 → 업무 종류 → 업무)도 그 업무 몫만 진한 띠로 덧그림
  const apply = () => {
    const id = hoverId || pinId, any = id || hoverTheme || hoverNode;
    ribs.forEach(r => {
      const on = id ? r.t.id === id : hoverNode ? r.nk === hoverNode : hoverTheme ? r.t.theme === hoverTheme : true;
      r.p.setAttribute('fill-opacity', any ? (on ? 0.95 : 0.12) : 0.8);
      if (r.lab.style) r.lab.style.fontWeight = id && on ? 700 : 400, r.lab.style.fill = id && on ? '#24150F' : '';
      r.lab.setAttribute('opacity', any ? (on ? 1 : 0.2) : 1);
    });
    bands.forEach(b => b.e.setAttribute('fill-opacity', !any ? b.base : id ? .14 : (hoverNode ? b.nk === hoverNode : b.theme === hoverTheme) ? .92 : .14));
    if (hlG) { hlG.innerHTML = ''; if (id && pathOf) pathOf(id); }
  };

  let vg = null, WW = 0, dragged = false;
  // 끌 수 있는 한 줄(분야 막대, 업무 종류 마디): 순서, 위치, 폭, 스프링 상태를 줄마다 따로 가짐
  const BG = 8, mkRow = () => ({ order: null, pos: null, w: {}, tgt: {}, disp: {}, vel: {} });
  const R1 = mkRow(), R2 = mkRow(); let drag = null, raf = 0, lastT = 0;
  const step = now => {
    const dt = Math.min(.033, (now - lastT) / 1000 || .016); lastT = now; let moving = false;
    [R1, R2].forEach(R => { for (const id in R.tgt) {
      if (R.disp[id] == null) { R.disp[id] = R.tgt[id]; R.vel[id] = 0; continue; }
      if (drag && drag.R === R && drag.id === id) { R.disp[id] += (R.tgt[id] - R.disp[id]) * (1 - Math.exp(-dt * 16)); R.vel[id] = 0; moving = true; continue; }
      const a = 380 * (R.tgt[id] - R.disp[id]) - 22 * R.vel[id]; R.vel[id] += a * dt; R.disp[id] += R.vel[id] * dt;
      if (Math.abs(R.tgt[id] - R.disp[id]) > .3 || Math.abs(R.vel[id]) > .3) moving = true; else { R.disp[id] = R.tgt[id]; R.vel[id] = 0; }
    } });
    raf = 0; draw(true); if (moving || drag) raf = requestAnimationFrame(step);
  };
  const kick = () => { if (!raf) { lastT = performance.now(); raf = requestAnimationFrame(step); } };
  // 끈 항목(id)을 기준으로 좌우 이웃을 밀어내며 겹침 제거
  const resolve = (R, id) => {
    const d = R.order.indexOf(id), W = WW, L = R.order.slice(0, d), Rt = R.order.slice(d + 1), pos = R.pos, bw = R.w;
    const lo = 4 + L.reduce((q, i) => q + bw[i] + BG, 0), hi = W - 4 - bw[id] - Rt.reduce((q, i) => q + bw[i] + BG, 0);
    pos[id] = Math.max(lo, Math.min(hi, pos[id]));
    let e = pos[id] + bw[id] + BG; Rt.forEach(i => { pos[i] = Math.max(pos[i], e); e = pos[i] + bw[i] + BG; });
    let st = pos[id] - BG; for (let j = L.length - 1; j >= 0; j--) { const i = L[j]; pos[i] = Math.min(pos[i], st - bw[i]); st = pos[i] - BG; }
  };
  const DRAG = false;   // 막대와 마디는 고정(끌어서 옮기지 않음)
  const grab = (hit, R, id, items) => DRAG && hit.addEventListener('mousedown', e => {
    if (e.button) return; e.preventDefault();
    const sx = e.clientY; dragged = true; drag = { R, id }; tip.style.display = 'none'; body.style.cursor = 'grabbing';
    if (!R.pos) { R.pos = {}; items.forEach(q => { R.pos[q] = R.tgt[q]; }); }
    const p0 = R.pos[id];
    const mv = ev => {
      R.pos[id] = p0 + ev.clientY - sx;
      let d = R.order.indexOf(id);
      for (;;) {   // 이웃의 가운데를 넘으면 순서 교환
        const c = R.pos[id] + R.w[id] / 2, rn = R.order[d + 1], ln = R.order[d - 1];
        if (rn != null && c > R.pos[rn] + R.w[rn] / 2) { R.order[d] = rn; R.order[d + 1] = id; d++; }
        else if (ln != null && c < R.pos[ln] + R.w[ln] / 2) { R.order[d] = ln; R.order[d - 1] = id; d--; }
        else break;
      }
      resolve(R, id); R.tgt = { ...R.pos }; kick();
    };
    const up = () => { removeEventListener('mousemove', mv); removeEventListener('mouseup', up); dragged = false; drag = null; hoverTheme = hoverNode = null; body.style.cursor = ''; kick(); };
    addEventListener('mousemove', mv); addEventListener('mouseup', up);
  });


  // 확대 보기: 고른 업무 하나의 흐름(분야 → 업무 종류 → 업무 → 자료 종류 → 자료 하나하나)을 크게. 왼쪽 위 단추로 전체 보기
  const back = document.createElement('button');
  back.textContent = '‹ 전체 보기';
  back.style.cssText = 'position:absolute;z-index:4;left:20px;top:' + (STRIP + 8) + 'px;display:none;border:0;border-radius:999px;background:#EFEAE5;color:#4A3E37;font:600 12px "SUIT",-apple-system,sans-serif;padding:6px 12px;cursor:pointer';
  back.addEventListener('click', () => { ui.select?.(null); zoomSwap(null); });
  wrap.appendChild(back);
  const nameOf = it => typeof it === 'string' ? it : (it.name ?? it.title ?? String(it.id ?? ''));
  function drawFocus(W, H) {
    const x = ts.find(q => q.t.id === pinId); if (!x) { pinId = null; return false; }
    const BH = H - STRIP, V0 = 30, VH = BH - V0 - 30;
    svg.setAttribute('width', W); svg.setAttribute('height', BH); svg.innerHTML = ''; vg = el('g', {}, svg);
    back.style.display = 'block';
    const th = data.themes.find(q => q.id === x.t.theme) || { name: x.t.theme, color: x.t.color }, col = x.t.color;
    const fs = 12.5, measure = el('text', { 'font-size': fs }, vg);
    const fitText = (str, maxW) => { measure.textContent = str; if (measure.getComputedTextLength() <= maxW) return str; let k = str.length; while (k > 1) { k--; measure.textContent = str.slice(0, k) + '…'; if (measure.getComputedTextLength() <= maxW) break; } return measure.textContent; };
    // 열: 분야 | 업무 종류 | 업무 | 자료 종류 | 자료 이름(남는 폭 전부)
    const cB = 40, cM = W * .2, cT = W * .38, cK = W * .55, cI = cK + 10, nameMax = W - cI - 28;
    stripSvg.innerHTML = '';
    [['분야', cB, 'start'], ['업무 종류', cM, 'middle'], ['업무', cT, 'middle'], ['자료 종류', cK - 10, 'end'], ['자료', cI, 'start']].forEach(([t, xx, a]) => { const e = el('text', { x: xx, y: STRIP / 2 + 4, 'text-anchor': a, 'font-size': 11, 'letter-spacing': 1.5, fill: '#8a827b' }, stripSvg); e.textContent = t; });
    // 자료 줄: 다 보이게(칸이 모자라면 줄 높이를 줄임, 최소 13px 아래로는 종류마다 '외 n개')
    const KS = Object.keys(data.kinds || {}).map(k => ({ k, items: (x.t.items?.[k] || []).map(nameOf) })).filter(o => o.items.length);
    const KGAP = 12, total = KS.reduce((q, o) => q + o.items.length, 0) || 1;
    let rowH = Math.min(26, (VH - KGAP * (KS.length - 1)) / total);
    if (rowH < 13) { rowH = 13; const cap = Math.max(KS.length, Math.floor((VH - KGAP * (KS.length - 1)) / 13) - KS.length); KS.forEach(o => { const n = Math.max(1, Math.round(cap * o.items.length / total)); o.show = o.items.slice(0, n); o.more = o.items.length - o.show.length; }); }
    else KS.forEach(o => { o.show = o.items; o.more = 0; });
    KS.forEach(o => o.rows = o.show.length + (o.more ? 1 : 0));
    const listH = KS.reduce((q, o) => q + o.rows * rowH, 0) + KGAP * (KS.length - 1);
    let yy = V0 + Math.max(0, (VH - listH) / 2); KS.forEach(o => { o.y = yy; o.h = o.rows * rowH; yy += o.h + KGAP; });
    const T = Math.min(VH * .42, Math.max(80, listH * .6)), t0 = V0 + (VH - T) / 2;
    const dOf = g => { const h = (g.x1 + g.x2) / 2; return `M${g.x1},${g.a1}C${h},${g.a1} ${h},${g.a2} ${g.x2},${g.a2}L${g.x2},${g.b2}C${h},${g.b2} ${h},${g.b1} ${g.x1},${g.b1}Z`; };
    const segs = [], bandG = el('g', {}, vg), extras = el('g', {}, vg);
    const band = (x1, a1, b1, x2, a2, b2, op, from) => { const to = { x1, a1, b1, x2, a2, b2 }; const e = el('path', { d: dOf(to), fill: col, 'fill-opacity': op }, bandG); segs.push({ e, to, from }); return e; };
    const ov = morphFrom === x.t.id && ovGeo && x.by != null ? ovGeo : null;   // 전체 보기에서 막 넘어왔으면 그 좌표
    const bar = (xx, y, h, fill) => el('rect', { x: xx - 2, y, width: 4, height: h, rx: 2, fill }, vg);
    band(cB + 2, t0, t0 + T, cM - 2, t0, t0 + T, .78, ov && { x1: ov.xB, a1: x.by, b1: x.by + x.w, x2: ov.xM, a2: x.my, b2: x.my + x.w });
    band(cM + 2, t0, t0 + T, cT - 2, t0, t0 + T, .78, ov && { x1: ov.xM, a1: x.my, b1: x.my + x.w, x2: ov.xT, a2: x.y0, b2: x.y0 + x.w });
    let ty = t0; const tot = KS.reduce((q, o) => q + o.items.length, 0) || 1;
    KS.forEach(o => {
      const tw = T * o.items.length / tot, kg = x.kseg?.[o.k]; band(cT + 2, ty, ty + tw, cK - 2, o.y, o.y + o.h, .55, ov && kg && { x1: ov.xL, a1: kg.a1, b1: kg.b1, x2: ov.xK, a2: kg.a2, b2: kg.b2 }); ty += tw;
      bar(cK, o.y, o.h, data.kinds[o.k].color);   // 자료 종류 색은 막대에만, 이름은 막대 바로 옆에 선 없이
      const kl = el('text', { x: cK - 10, y: o.y + o.h / 2 + 4, 'text-anchor': 'end', 'font-size': 12, 'font-weight': 700, fill: '#4A3E37' }, vg); kl.textContent = `${data.kinds[o.k].name} ${o.items.length}`;
      // 종류 → 자료: 이름은 남는 폭 안에서 말줄임
      o.show.forEach((nm, q) => {
        const ry = o.y + q * rowH + rowH / 2;
        const t = el('text', { x: cI, y: ry + 4.3, 'font-size': Math.min(fs, rowH * .72), fill: '#2A201B' }, vg); t.textContent = fitText(nm, nameMax);
      });
      if (o.more) { const t = el('text', { x: cI, y: o.y + o.show.length * rowH + rowH / 2 + 4, 'font-size': 11, fill: '#8C837C' }, vg); t.textContent = `외 ${o.more}개`; }
    });
    bar(cB, t0, T, th.color); bar(cM, t0, T, '#CFC8C1'); bar(cT, t0, T, '#CFC8C1');
    // 이름표: 분야는 막대 아래, 업무 종류는 막대 아래, 업무 이름과 요약은 띠 위
    const lab = (xx, y, a, txt, size, w, fill) => { const e = el('text', { x: xx, y, 'text-anchor': a, 'font-size': size, 'font-weight': w, fill }, vg); e.textContent = txt; return e; };
    lab(cB, t0 + T + 20, 'start', th.name, 13, 700, th.color);
    lab(cM, t0 + T + 20, 'middle', x.type, 13, 700, '#2A201B');
    const tl = lab(cT, t0 - 34, 'middle', fitText(x.t.title, (cK - cM) * 1.6), 16, 700, '#2A201B'); tl.style.cursor = 'pointer'; tl.addEventListener('click', () => ui.open(x.t.id));
    lab(cT, t0 - 14, 'middle', `${hm(x.mins)}, 세션 ${x.t.sessions.length}회, 자료 ${tot}개`, 11.5, 400, '#8C837C');
    measure.remove();
    // 띠 말고 나머지(막대, 이름, 자료 목록)는 한 묶음으로: 띠가 옮겨 가는 동안 늦게 나타남
    [...vg.children].forEach(c => { if (c !== bandG && c !== extras) extras.appendChild(c); });
    if (ov) {
      morphFrom = null;
      const tm0 = performance.now(), D = 720, lerp = (p2, q2, k) => p2 + (q2 - p2) * k;
      segs.forEach(sg => { if (!sg.from) sg.from = { x1: ov.xL, a1: x.y0, b1: x.y0 + x.w, x2: ov.xL + 1, a2: x.y0, b2: x.y0 + x.w }; sg.e.setAttribute('d', dOf(sg.from)); });
      extras.setAttribute('opacity', 0);
      const st = now => { const k = Math.min(1, (now - tm0) / D), e = 1 - Math.pow(1 - k, 3);
        segs.forEach(sg => { const gq = {}; for (const key in sg.to) gq[key] = lerp(sg.from[key], sg.to[key], e); sg.e.setAttribute('d', dOf(gq)); });
        extras.setAttribute('opacity', Math.max(0, (k - .45) / .55).toFixed(2)); if (k < 1) requestAnimationFrame(st); };
      requestAnimationFrame(st);
    }
    return true;
  }
  // 전체 ↔ 확대 전환: 앞 그림은 흐려지며 사라지고, 고른 업무의 띠가 제자리에서 확대 보기 자리로 옮겨 감(돌아갈 때는 전체가 서서히 나타남)
  const ghostOut = () => { const gh = svg.cloneNode(true); gh.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;transition:opacity .35s ease'; body.appendChild(gh); requestAnimationFrame(() => { gh.style.opacity = 0; }); setTimeout(() => gh.remove(), 420); };
  // 업무를 누르면 확대만 한다(업무 상세 칸은 확대 보기의 업무 이름을 누를 때 연다)
  const zoomSwap = toId => {
    hoverId = null; tip.style.display = 'none'; ghostOut(); svg.style.transform = '';
    if (toId) { morphFrom = toId; pinId = toId; svg.style.transition = 'none'; svg.style.opacity = 1; draw(); return; }
    pinId = null; svg.style.transition = 'none'; svg.style.opacity = 0; draw();
    requestAnimationFrame(() => requestAnimationFrame(() => { svg.style.transition = 'opacity .45s ease'; svg.style.opacity = 1; }));
  };

  function draw(fromAnim) {
    const W = wrap.clientWidth, H = wrap.clientHeight;
    if (!W || !H) return;
    if (pinId && drawFocus(W, H)) return;   // 업무 하나를 고르면 그 업무만 크게(확대 보기)
    back.style.display = 'none';
    const BH = H - STRIP, V0 = 14, VH = BH - V0 - 18;
    const xB = 24 + 90;
    WW = BH; svg.setAttribute('width', W); svg.setAttribute('height', BH); svg.innerHTML = ''; vg = el('g', {}, svg);
    // 이름 열 폭: 가장 긴 이름과 260px(좁은 화면은 화면 폭의 26%) 중 작은 값, 넘치면 말줄임. 폭이 바뀔 때만 다시 잼
    const NC = Math.round(Math.min(220, W * .17)), tm = el('text', { 'font-size': 11 }, vg);
    ts.forEach(x => {
      if (x.cap === NC) return; x.cap = NC;
      let k = x.t.title.length; tm.textContent = x.t.title; let w = tm.getComputedTextLength() || 11 * k;
      if (w > NC) { k = Math.max(1, Math.floor(k * NC / w)); do { tm.textContent = x.t.title.slice(0, k).trimEnd() + '…'; w = tm.getComputedTextLength() || 11 * (k + 1); } while (w > NC && --k > 0); }
      x.txt = tm.textContent; x.nw = w;
    });
    tm.remove();
    // 오른쪽 끝에 업무 막대와 그 오른쪽 이름 열을 두고, 남는 폭이 모두 흐름
    // 자료 종류 막대는 오른쪽 끝(이름은 그 오른쪽 KW), 업무 막대와 이름은 가운데. 흐르는 세 구간 폭 3.5 : 3.5 : 3
    const KW = 96, nameW = 10 + Math.ceil(Math.max(...ts.map(x => x.nw))) + 8, xK = W - 20 - KW, F = xK - xB - nameW;
    const xM = xB + F * .35, xT = xB + F * .70, xL = xT + nameW;   // xL: 업무 이름 끝, 여기서 자료 쪽 띠 시작
    // 열 이름(맨 위 고정)
    stripSvg.innerHTML = '';
    const hdr = (x, a, t) => { const e = el('text', { x, y: STRIP / 2 + 4, 'text-anchor': a, 'font-size': 11, 'letter-spacing': 1.5, fill: '#8a827b' }, stripSvg); e.textContent = t; };
    hdr(xT + 10, 'start', '업무'); hdr(xM, 'middle', '업무 종류'); hdr(xK + 12, 'start', '자료 종류');   // 머리는 열 이름만(레퍼런스처럼 숫자 없이)
    // 분야 순서: 가장 이른 시작 기준
    const themes = data.themes.filter(th => ts.some(x => x.t.theme === th.id));
    ts.forEach(x => { if (!themes.find(th => th.id === x.t.theme)) themes.push({ id: x.t.theme, name: x.t.theme, color: x.t.color }); });
    const ord = th => Math.min(...ts.filter(x => x.t.theme === th.id).map(x => x.first));
    themes.sort((a, b) => ord(a) - ord(b));
    hdr(xB - 14, 'end', '분야');
    // 왼쪽 열: 시작일 순으로 한 줄씩, 날짜가 바뀌면 약간 띄움
    const nFirst = {}; ts.forEach(x => { nFirst[x.nk] = Math.min(nFirst[x.nk] ?? Infinity, x.first); });
    const thIdx = id => themes.findIndex(th => th.id === id);
    const L = ts.slice().sort((a, b) => thIdx(a.t.theme) - thIdx(b.t.theme) || nFirst[a.nk] - nFirst[b.nk] || (a.nk < b.nk ? -1 : a.nk > b.nk ? 1 : 0) || a.first - b.first || b.mins - a.mins), n = L.length;
    const sq = x => Math.sqrt(x.mins), maxSq = Math.max(...ts.map(sq));
    let sc = 60 / maxSq, minSlot = 13, gBig = 9; const wOf = x => Math.max(2.5, sq(x) * sc), slot = x => Math.max(wOf(x), minSlot);
    const gapAt = i => i ? (L[i].nk !== L[i - 1].nk ? gBig : 0) : 0;   // 업무 종류 묶음 사이만 띄움
    const tot = () => L.reduce((q, x, i) => q + slot(x) + gapAt(i), 0), flo = () => L.reduce((q, x, i) => q + minSlot + gapAt(i), 0);
    while (flo() > VH * .98 && gBig > 2) gBig--;        // 줄이 많아 최소 높이로도 넘치면 날짜 간격을 먼저 줄이고
    while (flo() > VH * .98 && minSlot > 4) minSlot -= .5;   // 그래도 넘치면 줄 높이를 줄임
    while (tot() > VH * .98 && sc > .01) sc *= .94;
    const fs = minSlot >= 13 ? 11 : 10;   // 줄이 좁으면 글자 10px
    const extra = n > 1 ? Math.max(0, (VH - tot()) / (n - 1)) : 0;
    let yy = V0;
    // 줄 높이를 띠 두께로 다 씀(레퍼런스처럼 띠끼리 붙게): 남는 높이(extra)도 줄 두께에 더함
    L.forEach((x, i) => { yy += i ? gapAt(i) : 0; x.slotTop = yy; x.y0 = yy; x.w = slot(x) + extra; yy += x.w; });
    // 가운데 마디 사이 틈(BG)까지 들어가게 두께를 조금 줄임: 마디끼리 겹치지 않게
    { const nN = new Set(ts.map(x => x.nk)).size, sumW = L.reduce((q, x) => q + x.w, 0), fit = Math.min(1, (VH - BG * (nN - 1) - 6 * (themes.length - 1) - 8) / sumW); if (fit < 1) L.forEach(x => { x.w *= fit; }); }
    if (!R1.order) R1.order = themes.map(th => th.id);
    themes.sort((a, b) => R1.order.indexOf(a.id) - R1.order.indexOf(b.id)); R1.order = themes.map(th => th.id);
    // 업무 종류 마디
    const nmap = {};
    ts.forEach(x => { (nmap[x.nk] = nmap[x.nk] || { id: x.nk, theme: x.t.theme, type: x.type, list: [], color: x.t.color }).list.push(x); });
    const nodes = Object.values(nmap);
    nodes.forEach(q => { q.list.sort((a, b) => a.y0 - b.y0); q.first = q.list[0].first; R2.w[q.id] = q.list.reduce((t, x) => t + x.w, 0); });
    themes.forEach(th => { R1.w[th.id] = nodes.filter(q => q.theme === th.id).reduce((t, q) => t + R2.w[q.id], 0); });
    R1.tgt = {};
    if (!R1.pos) {
      const sb = themes.reduce((q, th) => q + R1.w[th.id], 0), span = sb + 6 * (themes.length - 1);   // 분야 막대끼리 붙임
      const gp = themes.length > 1 ? (span - sb) / (themes.length - 1) : 0; let bx = V0;   // 위에서부터
      themes.forEach(th => { R1.tgt[th.id] = bx; bx += R1.w[th.id] + gp; });
    } else { themes.forEach(th => { if (R1.pos[th.id] == null) R1.pos[th.id] = 4; }); resolve(R1, R1.order[0]); themes.forEach(th => { R1.tgt[th.id] = R1.pos[th.id]; }); }
    themes.forEach(th => { if (R1.disp[th.id] == null) { R1.disp[th.id] = R1.tgt[th.id]; R1.vel[th.id] = 0; } });
    const keep = R2.order ? R2.order.filter(i => nmap[i]) : [];
    if (!R2.pos || !R2.order) R2.order = nodes.slice().sort((a, b) => R1.order.indexOf(a.theme) - R1.order.indexOf(b.theme) || a.first - b.first).map(q => q.id);
    else { nodes.forEach(q => { if (!keep.includes(q.id)) keep.push(q.id); }); R2.order = keep; }
    R2.tgt = {};
    if (!R2.pos) {
      let end = -1e9;
      themes.forEach(th => {
        const ns = R2.order.filter(i => nmap[i].theme === th.id), nw = ns.reduce((q, i) => q + R2.w[i], 0) + BG * (ns.length - 1);
        let ny = Math.max(R1.tgt[th.id] + (R1.w[th.id] - nw) / 2, end + BG, 4);
        ns.forEach(i => { R2.tgt[i] = ny; ny += R2.w[i] + BG; end = ny - BG; });
      });
    } else { nodes.forEach(q => { if (R2.pos[q.id] == null) R2.pos[q.id] = 4; }); resolve(R2, R2.order[0]); nodes.forEach(q => { R2.tgt[q.id] = R2.pos[q.id]; }); }
    nodes.forEach(q => { if (R2.disp[q.id] == null) { R2.disp[q.id] = R2.tgt[q.id]; R2.vel[q.id] = 0; } });
    nodes.forEach(q => { let m = R2.disp[q.id]; q.y = m; q.list.forEach(x => { x.my = m; m += x.w; }); });
    const bars = themes.map(th => {
      const b = { th, y0: R1.disp[th.id] }; let by = b.y0;
      nodes.filter(q => q.theme === th.id).sort((a, c) => a.y - c.y).forEach(q => q.list.forEach(x => { x.by = by; by += x.w; }));
      b.y1 = by; return b;
    });
    const g = el('g', {}, vg); hlG = el('g', { 'pointer-events': 'none' }, vg); const lg = el('g', {}, vg); ribs = []; bands = [];
    // 그 업무 몫의 왼쪽 두 구간 띠
    pathOf = id => { const x = ts.find(q => q.t.id === id); if (!x || x.by == null) return; const w = x.w, b = x.by, m = x.my, a = x.y0, hA2 = (xM + xT) / 2;
      el('path', { d: `M${xB},${b}C${h1},${b} ${h1},${m} ${xM},${m}L${xM},${m + w}C${h1},${m + w} ${h1},${b + w} ${xB},${b + w}Z`, fill: x.t.color, 'fill-opacity': .95 }, hlG);
      el('path', { d: `M${xM},${m}C${hA2},${m} ${hA2},${a} ${xT},${a}L${xT},${a + w}C${hA2},${a + w} ${hA2},${m + w} ${xM},${m + w}Z`, fill: x.t.color, 'fill-opacity': .95 }, hlG); };
    const h1 = (xB + xM) / 2, h2 = (xM + xT) / 2;
    const over = x => { if (dragged) return; hoverId = x.t.id; apply(); tip.style.display = 'block'; tip.innerHTML = `<b>${x.t.title}</b><br>${x.type}, ${hm(x.mins)}, 세션 ${x.t.sessions.length}회<br>${x.fw} ~ ${x.lw}`; };
    const mvT = e => { const q = wrap.getBoundingClientRect(); tip.style.left = Math.min(e.clientX - q.left + 14, W - 270) + 'px'; tip.style.top = (e.clientY - q.top + 14) + 'px'; };
    const out = () => { hoverId = null; apply(); tip.style.display = 'none'; };
    // 왼쪽 반(분야 → 업무 종류)은 업무 종류마다 한 덩어리 띠로 합침
    nodes.forEach(q => {
      const t0 = Math.min(...q.list.map(x => x.by)), t1 = Math.max(...q.list.map(x => x.by + x.w)), m0 = q.y, m1 = q.y + q.list.reduce((s2, x) => s2 + x.w, 0);
      el('path', { d: `M${xB},${t0}C${h1},${t0} ${h1},${m0} ${xM},${m0}L${xM},${m1}C${h1},${m1} ${h1},${t1} ${xB},${t1}Z`, fill: q.color, 'fill-opacity': .82, 'pointer-events': 'none' }, g); bands.push({ e: g.lastChild, nk: q.id, theme: q.theme, base: .82 });
    });
    // 자료 종류: 업무마다 쓴 자료를 종류별로 세고, 업무 두께(x.w)를 종류별 비율로 나눔
    const kindKeys = Object.keys(data.kinds || {});
    const NONE = '\u0000none', kInfo = k => k === NONE ? { name: '자료 없음', color: '#E2DCD6' } : data.kinds[k];
    ts.forEach(x => { x.kc = kindKeys.map(k => [k, (x.t.items?.[k] || []).length]).filter(([, c]) => c > 0); if (!x.kc.length) x.kc = [[NONE, 1]]; x.kt = x.kc.reduce((q, [, c]) => q + c, 0); });
    const kTot = {}; ts.forEach(x => x.kc.forEach(([k, c]) => { kTot[k] = (kTot[k] || 0) + x.w * c / x.kt; }));
    const kOrder = Object.keys(kTot).sort((a, b) => kTot[b] - kTot[a]);
    const kSum = kOrder.reduce((q, k) => q + kTot[k], 0), KG = 4, kScale = Math.min(1, (VH - KG * (kOrder.length - 1)) / (kSum || 1));
    const kPos = {}; { let ky = V0; kOrder.forEach(k => { kPos[k] = { y: ky, inC: ky, outC: ky, h: kTot[k] * kScale }; ky += kTot[k] * kScale + KG; }); }
    const hA = (xM + xT) / 2, hB = (xL + xK) / 2;
    ovGeo = { xB, xM, xT, xL, xK };   // 확대 보기로 바뀔 때 이 자리에서부터 띠가 옮겨 간다
    // 업무 종류 -> 업무: 덩어리 띠(업무 열이 업무 종류끼리 묶여 있어 이어짐)
    nodes.forEach(q => {
      const m0 = q.y, m1 = q.y + q.list.reduce((s2, x) => s2 + x.w, 0), a0 = Math.min(...q.list.map(x => x.y0)), a1 = Math.max(...q.list.map(x => x.y0 + x.w));
      el('path', { d: `M${xM},${m0}C${hA},${m0} ${hA},${a0} ${xT},${a0}L${xT},${a1}C${hA},${a1} ${hA},${m1} ${xM},${m1}Z`, fill: q.color, 'fill-opacity': .78, 'pointer-events': 'none' }, g); bands.push({ e: g.lastChild, nk: q.id, theme: q.theme, base: .78 });
    });
    // 업무 -> 자료 종류: 업무마다(업무 칸을 종류별로 나눠 보냄)
    L.forEach(x => {
      let ty = x.y0; x.kseg = {};
      x.kc.slice().sort((a, b) => kOrder.indexOf(a[0]) - kOrder.indexOf(b[0])).forEach(([k, c]) => {
        const tw = x.w * c / x.kt, kw = tw * kScale, ky = kPos[k].inC; kPos[k].inC += kw; x.kseg[k] = { a1: ty, b1: ty + tw, a2: ky, b2: ky + kw };
        const d = `M${xL},${ty}C${hB},${ty} ${hB},${ky} ${xK},${ky}L${xK},${ky + kw}C${hB},${ky + kw} ${hB},${ty + tw} ${xL},${ty + tw}Z`;
        const p = el('path', { d, fill: x.t.color, 'fill-opacity': .8, style: 'cursor:pointer' }, g);
        ribs.push({ t: x.t, p, lab: null, x, nk: x.nk });
        p.addEventListener('mouseenter', () => over(x)); p.addEventListener('mousemove', mvT); p.addEventListener('mouseleave', out);
        p.addEventListener('click', () => { if (!dragged) { ui.select?.(x.t.id); zoomSwap(x.t.id); } });
        p.addEventListener('contextmenu', ev => ui.menu?.({ task: x.t.id }, ev));
        ty += tw;
      });
    });
    // 자료 종류 막대(연한 회색) + 이름(막대 오른쪽)
    let lastLy = -1e9;
    kOrder.forEach(k => {
      const kp = kPos[k], cy = Math.max(kp.y + kp.h / 2, lastLy + 15); lastLy = cy;   // 이름끼리 15px 안이면 아래로 비킴
      el('rect', { x: xK, y: kp.y, width: 6, height: Math.max(kp.h, 2), fill: '#CFC8C1' }, vg);
      const t = el('text', { x: xK + 12, y: cy + 4, 'font-size': 12, 'font-weight': 700, fill: '#2A201B', 'pointer-events': 'none' }, vg); t.textContent = kInfo(k).name;
    });
    // 오른쪽: 업무 막대와 이름
    L.forEach(x => {
      const w = x.w, cy = x.y0 + w / 2, rb = ribs.find(q => q.x === x);
      el('rect', { x: xT, y: x.y0, width: 5, height: w, fill: '#CFC8C1', 'pointer-events': 'none' }, vg);
      el('line', { x1: xT + 5, x2: xT + 14, y1: cy, y2: cy, stroke: '#CFC8C1', 'stroke-width': .8, 'pointer-events': 'none' }, vg);   // 리더선
      // 이름은 막대 오른쪽 열에 왼쪽 정렬. 글자는 이벤트 없음, 같은 크기 투명 칸이 받음
      const t = el('text', { x: xT + 17, y: cy + fs * .36, 'font-size': Math.min(fs + 1, 11.5), fill: '#2A201B', 'pointer-events': 'none' }, lg);
      t.textContent = x.txt; rb.lab = t;
      const hh = Math.min(16, Math.max(8, minSlot)), hit = el('rect', { x: xT + 13, y: cy - hh / 2, width: x.nw + 8, height: hh, fill: 'transparent', style: 'cursor:pointer' }, lg);
      hit.addEventListener('mouseenter', () => over(x)); hit.addEventListener('mousemove', mvT); hit.addEventListener('mouseleave', out); hit.addEventListener('click', () => { if (!dragged) { ui.select?.(x.t.id); zoomSwap(x.t.id); } });
      hit.addEventListener('contextmenu', ev => ui.menu?.({ task: x.t.id }, ev));
    });
    // 가운데 마디: 검은 얇은 막대 + 이름표, 위아래로 끎
    const chips = [];
    R2.order.forEach(id => {
      const q = nmap[id]; if (!q) return; const h = Math.max(R2.w[id], 2), y = q.y;
      el('rect', { x: xM - 3, y, width: 6, height: h, fill: '#CFC8C1' }, vg);
      const label = `${q.type} ${q.list.length}`, cwid = label.length * 10.5 + 14, cy = y + h / 2;
      let ly = cy; chips.forEach(c => { if (Math.abs(c.cy - ly) < 14) ly = c.cy + 14; });   // 앞 이름과 14px 안이면 아래로 비킨다
      chips.push({ cy: ly });
      const cx = xM;
      const hit = el('rect', { x: Math.min(xM - 6, cx - cwid / 2), y: Math.min(y - 3, cy - 10), width: Math.max(12, cx + cwid / 2 - Math.min(xM - 6, cx - cwid / 2)), height: Math.max(h + 6, 20), fill: 'transparent', style: 'cursor:pointer' }, vg);
      const t = el('text', { x: cx - 8, y: ly + 4, 'text-anchor': 'end', 'font-size': 12, 'font-weight': 700, fill: '#2A201B', 'pointer-events': 'none' }, vg); t.textContent = label;   // 막대 왼쪽, 흰 테두리로 띠 위에서 읽힘
      hit.addEventListener('mouseenter', () => { if (dragged) return; hoverNode = id; apply(); });
      hit.addEventListener('mouseleave', () => { if (!dragged) { hoverNode = null; apply(); } });
      hit.addEventListener('click', () => { if (!dragged) ui.node?.({ type: q.type }); });   // 업무 종류 상세 (끌어 옮긴 뒤가 아니면)
      hit.addEventListener('contextmenu', ev => ui.menu?.({ type: q.type }, ev));
      grab(hit, R2, id, R2.order.slice());
    });
    // 오른쪽 분야 막대
    bars.forEach(b => {
      const h = Math.max(b.y1 - b.y0, 2), cy = b.y0 + h / 2;
      el('rect', { x: xB - 6, y: b.y0, width: 6, height: h, fill: b.th.color }, vg);   // 분야 열만 분야 색 막대
      const hit = el('rect', { x: xB - 110, y: Math.min(b.y0 - 4, cy - 12), width: 114, height: Math.max(h + 8, 24), fill: 'transparent', style: 'cursor:pointer' }, vg);
      const t = el('text', { x: xB - 14, y: cy + 5, 'text-anchor': 'end', 'font-size': 13, 'font-weight': 700, fill: b.th.color, 'pointer-events': 'none' }, vg); t.textContent = b.th.name;
      hit.addEventListener('mouseenter', () => { if (dragged) return; hoverTheme = b.th.id; apply(); });
      hit.addEventListener('mouseleave', () => { if (!dragged) { hoverTheme = null; apply(); } });
      hit.addEventListener('click', () => { if (!dragged) ui.node?.({ theme: b.th.id }); });   // 분야 상세
      hit.addEventListener('contextmenu', ev => ui.menu?.({ theme: b.th.id }, ev));
      grab(hit, R1, b.th.id, R1.order.slice());
    });
    ribs.forEach(r => { if (!r.lab) r.lab = el('g', {}); });
    apply();
    if (!fromAnim && !raf && ([R1, R2].some(R => Object.keys(R.tgt).some(i => Math.abs(R.disp[i] - R.tgt[i]) > .3)))) kick();
  }
  if (ui.sel && ts.some(q => q.t.id === ui.sel)) pinId = ui.sel;   // 다른 보기에서 고른 업무면 바로 확대 보기
  const ro = new ResizeObserver(draw); ro.observe(wrap); draw();
  return () => { cancelAnimationFrame(raf); ro.disconnect(); wrap.remove(); };
};
