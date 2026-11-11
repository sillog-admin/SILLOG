/* 원형 비중: 둘레 = 업무 종류(이름을 원 따라 돌려 씀), 점 = 업무(쓴 시간이 많을수록 가운데), 색 덩어리 = 분야(같은 색 반투명 띠가 가운데를 지나 길게 뻗음).
   점에 올리면 말풍선(업무 이름, 분야, 업무 종류, 쓴 시간)과 그 분야 띠만 진하게, 점을 누르면 업무 상세. 치수는 레퍼런스 그림을 픽셀로 재서 원판 반지름(R) 비율로 맞춤. */
window.V3D = window.V3D || {};
window.V3D.radial = function (main, data, ui) {
  const NS = 'http://www.w3.org/2000/svg', FONT = '"SUIT","Apple SD Gothic Neo",sans-serif', RAD = Math.PI / 180;
  const PAL = ['#8E3F8C', '#4A2E1F', '#B08A6A', '#13995A', '#D11F2E', '#E8823A', '#1BA3D6', '#4B3F86'];   // 분야 순서대로 쓰는 색
  const el = (n, a, p) => { const e = document.createElementNS(NS, n); for (const k in a || {}) e.setAttribute(k, a[k]); if (p) p.appendChild(e); return e; };
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const hm = m => m >= 60 ? Math.floor(m / 60) + '시간' + (m % 60 ? ' ' + (m % 60) + '분' : '') : m + '분';
  const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;

  main.innerHTML = '';
  if (!data.tasks.length) return () => {};
  // 분야 순서 = 넘겨 받은 순서, 번호는 "분야번호.분야 안 순번"(분야 안은 시작이 이른 순)
  const themes = data.themes.filter(th => data.tasks.some(t => t.theme === th.id));
  data.tasks.forEach(t => { if (!themes.some(th => th.id === t.theme)) themes.push({ id: t.theme, name: t.theme, color: t.color }); });
  themes.forEach((th, i) => { th.hex = th.color || PAL[i % PAL.length]; });   // 분야에 붙은 색(다른 보기와 같게), 없을 때만 자체 팔레트
  const first = t => Math.min(Infinity, ...t.sessions.map(s => s.d * 1440 + s.start));
  const last = t => Math.max(-Infinity, ...t.sessions.map(s => s.d * 1440 + s.end));   // 마지막 활동 시각(분)
  const rows = [];
  themes.forEach((th, ti) => th.rows = data.tasks.filter(t => t.theme === th.id).sort((a, b) => first(a) - first(b) || a.title.localeCompare(b.title))
    .map((t, k) => { const r = { t, th, ti, no: (ti + 1) + '.' + (k + 1), type: t.type || '기타', mins: Math.max(t.mins || 0, 1) }; rows.push(r); return r; }));
  // 업무 종류 = 둘레 방향. 업무가 많은 종류부터 위쪽에서 시계 방향으로
  const tm = {};
  rows.forEach(r => { const q = tm[r.type] = tm[r.type] || { name: r.type, rows: [], mins: 0 }; q.rows.push(r); q.mins += r.mins; r.ty = q; });
  const types = Object.values(tm).sort((a, b) => b.rows.length - a.rows.length || b.mins - a.mins);
  const S = 360 / types.length;
  types.forEach((q, i) => { q.deg = -90 + S * (i + .5); q.sub = q.rows.slice().sort((a, b) => b.mins - a.mins).slice(0, 3).map(r => r.t.title); });
  // 거리 = 시간. 마지막 활동이 최근일수록 가운데, 오래된 업무일수록 바깥(0.08R~0.95R). 원판 고리는 그 기간의 4등분
  const lastOf = rows.map(r => last(r.t)), tMax = Math.max(...lastOf), tMin = Math.min(...lastOf), span = Math.max(1, tMax - tMin);
  rows.forEach((r, i) => { r.rn = .08 + .87 * (tMax - lastOf[i]) / span; });

  const wrap = document.createElement('div');
  wrap.style.cssText = 'position:absolute;inset:0;overflow:hidden;font-family:' + FONT;
  const svg = el('svg', { style: 'position:absolute;left:0;top:0;display:block;user-select:none' });
  const tip = document.createElement('div');
  tip.style.cssText = 'position:absolute;z-index:5;pointer-events:none;display:none;background:#24150F;color:#fff;font-size:12px;line-height:1.5;padding:7px 10px;border-radius:8px;max-width:260px';
  wrap.append(svg, tip); main.appendChild(wrap);

  // 점을 자기 종류 칸 안에 넓게 흩고, 겹치면 각도와 반지름으로 조금씩 벌림
  const place = (R, d) => {
    const D = 2 * d + 3, one = types.length < 2, wid = q => S * Math.min(1.1, .55 + .02 * q.rows.length);   // 업무가 많은 종류는 칸 경계를 넘어 옆 칸까지 펼침
    rows.forEach((r, i) => { const a = (r.ty.deg + ((i * .618) % 1 - .5) * wid(r.ty) * 1.6) * Math.PI / 180; r.x = r.rn * R * Math.cos(a); r.y = r.rn * R * Math.sin(a); });
    for (let it = 0; it < 260; it++) {
      for (let i = 0; i < rows.length; i++) for (let j = i + 1; j < rows.length; j++) {
        const a = rows[i], b = rows[j]; let dx = b.x - a.x, dy = b.y - a.y, ds = Math.hypot(dx, dy);
        if (ds >= D * 2.6) continue;
        if (ds < 1e-6) { dx = Math.cos(i * 2.4); dy = Math.sin(i * 2.4); ds = 1; }
        const k = (ds < D ? (D - ds) / ds / 2 : (D * 2.6 - ds) / ds * .02); a.x -= dx * k; a.y -= dy * k; b.x += dx * k; b.y += dy * k;   // 겹치면 세게, 가까우면 약하게 밀어 고르게 퍼지게
      }
      rows.forEach(r => {   // 자기 종류 칸 안, 원판 안으로 되돌림. 반지름은 시간 순위 자리로 약하게 끌어당김
        let rr = Math.hypot(r.x, r.y), df = (Math.atan2(r.y, r.x) / RAD - r.ty.deg + 540) % 360 - 180;
        rr += (r.rn * R - rr) * .3;   // 시간 자리로 세게 당긴다(순서가 뜻이므로)
        if (!one) df = Math.max(-wid(r.ty), Math.min(wid(r.ty), df));
        rr = Math.max(R * .07, d * 1.4, Math.min(R * .96, rr));
        const a = (r.ty.deg + df) * RAD; r.x = rr * Math.cos(a); r.y = rr * Math.sin(a);
      });
    }
  };

  // 띠: 분야마다 점들과 원판 가운데(그리지 않는 가짜 점, 거리를 0.8배로 쳐 가지가 가운데로 모이게)를 최소 신장 트리로 잇고,
  // 각 변을 매끈한 3차 곡선으로 그린 뒤, 곡선을 따라 폭이 변하는 원 여러 개로 채우고 가까운 점 둘레끼리 감싸 이어 홈과 구멍을 메운다(아메바처럼 점 둘레는 불룩, 점 사이는 가늘게, 가지 끝은 둥글게 부풀게).
  // 곡선에는 저주파 흔들림을 더하고 점은 곡선 꼭짓점에서 조금 어긋나게 해서 반듯한 관 모양을 피한다. 흔들림과 어긋남은 업무 id 로 정해 다시 그려도 같다.
  const hs = s => { let h = 2166136261; for (const c of String(s)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } return h >>> 0; };
  const rng = s => () => { s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  const circle = c => `M${c.x.toFixed(1)},${(c.y).toFixed(1)}m${-c.r.toFixed(1)},0a${c.r.toFixed(1)},${c.r.toFixed(1)} 0 1 0 ${(2 * c.r).toFixed(1)},0a${c.r.toFixed(1)},${c.r.toFixed(1)} 0 1 0 ${(-2 * c.r).toFixed(1)},0Z`;
  const hull = (a, b) => {   // 두 원을 감싸는 띠 조각
    const dx = b.x - a.x, dy = b.y - a.y, dd = Math.hypot(dx, dy);
    if (dd <= Math.abs(a.r - b.r) + .3) return circle(a.r > b.r ? a : b);
    const base = Math.atan2(dy, dx), an = Math.acos((a.r - b.r) / dd), P = (c, t) => (c.x + c.r * Math.cos(t)).toFixed(1) + ',' + (c.y + c.r * Math.sin(t)).toFixed(1);
    return `M${P(a, base + an)}L${P(b, base + an)}A${b.r.toFixed(1)},${b.r.toFixed(1)} 0 ${an > Math.PI / 2 ? 1 : 0} 0 ${P(b, base - an)}L${P(a, base - an)}A${a.r.toFixed(1)},${a.r.toFixed(1)} 0 ${an < Math.PI / 2 ? 1 : 0} 0 ${P(a, base + an)}Z`;
  };
  // 자기 교차로 둘러싸인 빈틈 메우기: 띠가 덮는 칸을 표시하고, 바깥에서 이어지지 않는 빈 칸과 그 둘레 한 칸(실금 방지)을 줄 단위 사각형으로 채운다
  const holes = (segs, d) => {
    const G = Math.max(2, d * .3); let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    segs.forEach(s => s.forEach(c => { x0 = Math.min(x0, c.x - c.r); x1 = Math.max(x1, c.x + c.r); y0 = Math.min(y0, c.y - c.r); y1 = Math.max(y1, c.y + c.r); }));
    x0 -= G; y0 -= G;
    const w = Math.ceil((x1 - x0) / G) + 2, h = Math.ceil((y1 - y0) / G) + 2, cov = new Uint8Array(w * h);
    segs.forEach(([a, b]) => {
      const n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / (G * .5)));
      for (let k = 0; k <= n; k++) {
        const t = k / n, x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, r = a.r + (b.r - a.r) * t;
        for (let j = Math.max(0, Math.floor((y - r - y0) / G)); j <= Math.min(h - 1, Math.ceil((y + r - y0) / G)); j++)
          for (let i = Math.max(0, Math.floor((x - r - x0) / G)); i <= Math.min(w - 1, Math.ceil((x + r - x0) / G)); i++)
            if (Math.hypot(x0 + (i + .5) * G - x, y0 + (j + .5) * G - y) < r) cov[j * w + i] = 1;
      }
    });
    const seen = new Uint8Array(w * h), st = [0]; seen[0] = 1;   // 0번 칸은 띠 바깥(위에서 한 칸 비워 둠)
    while (st.length) {
      const c = st.pop(), i = c % w;
      [i > 0 ? c - 1 : -1, i < w - 1 ? c + 1 : -1, c - w, c + w].forEach(q => { if (q >= 0 && q < w * h && !seen[q] && !cov[q]) { seen[q] = 1; st.push(q); } });
    }
    const fill = new Uint8Array(w * h);
    for (let c = 0; c < w * h; c++) if (!cov[c] && !seen[c]) for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) fill[c + dj * w + di] = 1;   // 빈 칸은 바깥 한 칸 안쪽에만 있어 둘레가 격자 밖으로 나가지 않음
    let dd = '';
    for (let j = 0; j < h; j++) for (let i = 0, e; i < w; i = e + 1) {
      for (e = i; e < w && fill[j * w + e]; e++);   // 이어진 채울 칸 한 줄
      if (e > i) dd += `M${(x0 + i * G).toFixed(1)},${(y0 + j * G).toFixed(1)}h${((e - i) * G).toFixed(1)}v${(G * 1.5).toFixed(1)}h${(-(e - i) * G).toFixed(1)}Z`;   // 아래 줄과 반 칸 겹쳐 줄 사이 실금이 안 생김
    }
    return dd;
  };
  const band = (rs, d) => {
    const ns = [{ x: 0, y: 0, id: 'c' }, ...rs.map(r => ({ x: r.x, y: r.y, id: r.t.id }))], n = rs.length, par = ns.map((_, i) => i ? 0 : -1), key = ns.map((p, i) => i ? Math.hypot(p.x, p.y) * .8 : 0), done = ns.map(() => false), ch = ns.map(() => []);
    for (let k = 0; k <= n; k++) {
      let u = -1; ns.forEach((_, i) => { if (!done[i] && (u < 0 || key[i] < key[u])) u = i; });
      done[u] = true;
      ns.forEach((p, i) => { if (!done[i]) { const v = Math.hypot(p.x - ns[u].x, p.y - ns[u].y); if (v < key[i]) { key[i] = v; par[i] = u; } } });
    }
    for (let i = 1; i <= n; i++) ch[par[i]].push(i);
    const root = ch[0].length === 1 ? ch[0][0] : 0;   // 가운데에 가지가 하나뿐이면 가운데에서 끊고 그 점부터
    // 곡선 꼭짓점: 점에서 점 지름의 0.3~0.5배쯤 어긋나게. 굵기: 점 둘레 2.2d, 가지 끝과 가지가 만나는 곳은 더 불룩, 점 사이는 1.15d
    const V = ns.map((p, i) => { if (!i) return { x: 0, y: 0 }; const r = rng(hs(p.id)), a = r() * 6.2832, m = d * (.3 + r() * .5); return { x: p.x + Math.cos(a) * m, y: p.y + Math.sin(a) * m }; });
    const rad = ns.map((_, i) => { const inc = ch[i].length + (i === root ? 0 : 1); return !ch[i].length ? 2.5 * d : inc >= 3 ? 2.5 * d : 2.1 * d; });
    const cl = (dx, dy, m) => { const l = Math.hypot(dx, dy); return l > m ? [dx * m / l, dy * m / l] : [dx, dy]; }, gs = x => Math.exp(-x * x);
    const parts = [], segs = [], add = c => { parts.push(circle(c)); segs.push([c, c]); };
    ns.forEach((_, i) => { if (i && (i !== 0) && !(root && i === 0)) add({ x: V[i].x, y: V[i].y, r: rad[i] }); });
    if (!root) add({ x: 0, y: 0, r: rad[0] });
    const cs0 = ns.map((_, i) => ({ x: V[i].x, y: V[i].y, r: rad[i] })).filter((_, i) => i || !root);
    for (let i = 0; i < cs0.length; i++) for (let j = i + 1; j < cs0.length; j++) {   // 가까운 점 둘레끼리는 감싸 이어서 사이의 홈과 구멍을 메움(틈이 점 지름의 1.8배보다 좁을 때)
      const a = cs0[i], b = cs0[j];
      if (Math.hypot(b.x - a.x, b.y - a.y) < a.r + b.r + 3.6 * d) { parts.push(hull(a, b)); segs.push([a, b]); }
    }
    for (let i = 0; i <= n; i++) {
      const p = par[i]; if (p < 0 || i === root || (root && (i === 0 || p === 0))) continue;
      const a = V[p], b = V[i], L = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      let before = p !== root && par[p] >= 0 && !(root && par[p] === 0) ? V[par[p]] : a;
      if (p === 0 && root === 0) {   // 가운데에서 갈라지는 가지는 가장 반대쪽 가지와 한 줄로 매끈하게 이어지게(꺾이지 않고 가로지름)
        let bo = 2; ch[0].forEach(c => { if (c !== i) { const dt = (V[c].x * b.x + V[c].y * b.y) / (Math.hypot(V[c].x, V[c].y) * Math.hypot(b.x, b.y) || 1); if (dt < bo) { bo = dt; before = V[c]; } } });
      }
      let after = b, best = -2;   // 이어지는 가지 중 가장 곧게 이어지는 쪽으로 접선을 잡음
      ch[i].forEach(c => { const dt = ((V[c].x - b.x) * (b.x - a.x) + (V[c].y - b.y) * (b.y - a.y)) / (Math.hypot(V[c].x - b.x, V[c].y - b.y) * L || 1); if (dt > best) { best = dt; after = V[c]; } });
      const h1 = cl((b.x - before.x) / 6, (b.y - before.y) / 6, L * .45), h2 = cl((after.x - a.x) / 6, (after.y - a.y) / 6, L * .45);
      const c1 = [a.x + h1[0], a.y + h1[1]], c2 = [b.x - h2[0], b.y - h2[1]];
      const r = rng(hs(ns[i].id + '|' + ns[p].id)), fit = Math.min(1, L / (12 * d));   // 짧은 변은 굽이 진폭을 줄여 급하게 꺾이지 않게
      const A1 = (r() < .5 ? -1 : 1) * d * 1.2 * (.35 + r() * .65) * fit, A2 = (r() < .5 ? -1 : 1) * d * .6 * r() * fit, ph = r() * 6.2832;
      const N = Math.max(5, Math.ceil(L / (d * .6))), T = 4 * d, rm = 1.0 * d, ss = x => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x), cs = [];
      for (let k = 0; k <= N; k++) {
        const t = k / N, u = 1 - t;
        let x = u * u * u * a.x + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * b.x, y = u * u * u * a.y + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * b.y;
        const tx = 3 * u * u * (c1[0] - a.x) + 6 * u * t * (c2[0] - c1[0]) + 3 * t * t * (b.x - c2[0]), ty = 3 * u * u * (c1[1] - a.y) + 6 * u * t * (c2[1] - c1[1]) + 3 * t * t * (b.y - c2[1]), tl = Math.hypot(tx, ty) || 1;
        const w = A1 * Math.sin(Math.PI * t) + A2 * Math.sin(2 * Math.PI * t); x += -ty / tl * w; y += tx / tl * w;   // 느슨한 굽이
        // 점 둘레는 불룩, 점 사이는 가늘게: 점에서 4d 안에서 ease-in-out 로 전환(양쪽 점 중 더 큰 쪽), 느린 결(파장 13d)로 조금 출렁
        const bump = Math.max((rad[p] - rm) * (1 - ss(t * L / T)), (rad[i] - rm) * (1 - ss((1 - t) * L / T)));
        cs.push({ x, y, r: (rm + bump) * (1.05 + .22 * Math.sin(t * L / (13 * d) + ph)) });
      }
      for (let k = 1; k < cs.length; k++) cs[k].r = Math.min(cs[k].r, cs[k - 1].r * 1.12);   // 샘플 사이 폭 변화는 12% 안으로(앞에서 뒤로, 뒤에서 앞으로)
      for (let k = cs.length - 2; k >= 0; k--) cs[k].r = Math.min(cs[k].r, cs[k + 1].r * 1.12);
      for (let k = 0; k < cs.length - 1; k++) { parts.push(hull(cs[k], cs[k + 1])); segs.push([cs[k], cs[k + 1]]); }
    }
    return { parts, segs };
  };

  let hoverTheme = null, hoverTask = null, blobs = [], dots = [];
  const apply = () => {
    const any = hoverTheme != null;
    blobs.forEach(b => b.g.setAttribute('opacity', any ? (b.ti === hoverTheme ? .78 : .1) : .42));
    dots.forEach(q => { q.g.setAttribute('opacity', !any || q.r.ti === hoverTheme ? 1 : .22); q.c.setAttribute('stroke', hoverTask === q.r ? '#24150F' : 'none'); });
  };
  const over = r => { hoverTheme = r.ti; hoverTask = r; apply(); tip.style.display = 'block'; tip.innerHTML = `<b>${esc(r.t.title)}</b><br>분야 ${esc(r.th.name)}, 업무 종류 ${esc(r.type)}<br>쓴 시간 ${hm(r.mins)}`; };
  const out = () => { hoverTheme = hoverTask = null; apply(); tip.style.display = 'none'; };
  const mvT = e => { const q = wrap.getBoundingClientRect(); tip.style.left = Math.max(4, Math.min(e.clientX - q.left + 14, q.width - 270)) + 'px'; tip.style.top = (e.clientY - q.top + 14) + 'px'; };

  function draw() {
    const W = wrap.clientWidth, H = wrap.clientHeight;
    if (!W || !H) return;
    // 둘레 글자: 돌리지 않고 가로로. 종류 이름(13px 600)과 아래에 작은 업무 이름(9.5px, 최대 3줄)을 한 블록으로 묶어 종류 방향의 원 바깥에 놓는다
    const fs = 13, sfs = 9.5, cx = W / 2, cy = H / 2, tw = (t, z) => [...t].reduce((a, c) => a + (c.charCodeAt(0) > 0x2e80 ? z : z * .56), 0);
    types.forEach(q => {
      q.lines = q.sub.map(t => cut(t, 18)); q.w = Math.max(tw(q.name, fs) * 1.05, ...q.lines.map(t => tw(t, sfs)));
      q.h = fs * 1.25 + q.lines.length * (sfs + 3.5) + 3;
    });
    const layout = R => {
      const bl = types.map(q => ({ q, r: R + 14, c: Math.cos(q.deg * RAD), s: Math.sin(q.deg * RAD) }));
      const box = b => {   // 오른쪽 반원은 왼쪽 정렬, 왼쪽 반원은 오른쪽 정렬, 위아래 끝은 가운데 정렬로 위나 아래에
        const ax = cx + b.r * b.c, ay = cy + b.r * b.s, w = b.q.w, h = b.q.h, side = Math.abs(b.c) > .35;
        b.al = side ? (b.c > 0 ? 'start' : 'end') : 'middle';
        b.x = side ? ax + (b.c > 0 ? 5 : -5) : ax; b.y = side ? ay - h / 2 : b.s < 0 ? ay - h - 4 : ay + 4;
        const x0 = b.al === 'start' ? b.x : b.al === 'end' ? b.x - w : b.x - w / 2;
        return [x0, b.y, x0 + w, b.y + h];
      };
      let rc = bl.map(box);
      for (let it = 0; it < 60; it++) {   // 겹치면 뒤쪽 블록을 바깥으로 조금씩 밂
        let moved = false;
        for (let i = 0; i < bl.length; i++) for (let j = i + 1; j < bl.length; j++)
          if (rc[i][0] < rc[j][2] + 4 && rc[j][0] < rc[i][2] + 4 && rc[i][1] < rc[j][3] + 3 && rc[j][1] < rc[i][3] + 3) { bl[j].r += 6; rc[j] = box(bl[j]); moved = true; }
        if (!moved) break;
      }
      const over = Math.max(0, 6 - Math.min(...rc.map(r => r[0])), Math.max(...rc.map(r => r[2])) - (W - 6), 6 - Math.min(...rc.map(r => r[1])), Math.max(...rc.map(r => r[3])) - (H - 6));
      return { bl, over };
    };
    let R = Math.max(80, Math.min(cx, cy) - 30), lay = layout(R);
    for (let k = 0; k < 8 && lay.over > .5 && R > 80; k++) { R = Math.max(80, R - lay.over - 1); lay = layout(R); }   // 글자가 화면 밖으로 나가면 원판을 그만큼 줄임
    const d = Math.max(5, R * .027) * (rows.length > 150 ? .8 : rows.length > 60 ? .9 : 1);   // 점 반지름 d(원판 지름의 2.7%)
    svg.setAttribute('width', W); svg.setAttribute('height', H); svg.innerHTML = '';
    place(R, d);
    const g = el('g', { transform: `translate(${cx},${cy})` }, svg);
    // 원판: 한 톤. 거리 = 시간(가운데 = 최근). 흰 고리는 기간 4등분 눈금
    el('circle', { r: R, fill: '#EEEDEC' }, g);
    [.25, .5, .75].forEach(k => el('circle', { r: R * k, fill: 'none', stroke: '#fff', 'stroke-width': 1.2 }, g));
    // 분야 색 띠: 같은 색 반투명, 폭은 불규칙하게 불룩했다 가늘어짐. 한 분야 안은 한 장으로 겹쳐 그림
    blobs = themes.map((th, ti) => {
      const bg = el('g', { opacity: .42, fill: th.hex }, g), ps = th.rows;
      if (ps.length === 1) el('circle', { cx: ps[0].x.toFixed(1), cy: ps[0].y.toFixed(1), r: 2.2 * d }, bg);
      else { const bd = band(ps, d); bd.parts.forEach(pd => el('path', { d: pd }, bg)); const hd = holes(bd.segs, d); if (hd) el('path', { d: hd }, bg); }
      return { g: bg, ti };
    });
    // 종류 이름과 작은 업무 이름: 모두 가로 글자
    lay.bl.forEach(b => {
      const t = (txt, y, size, fill, w) => { const e = el('text', { x: (b.x - cx).toFixed(1), y: (y - cy).toFixed(1), 'text-anchor': b.al, 'font-size': size, fill, 'font-weight': w, 'pointer-events': 'none' }, g); e.textContent = txt; };
      t(b.q.name, b.y + fs, fs, '#24150F', 600);
      b.q.lines.forEach((l, i) => t(l, b.y + fs * 1.25 + 3 + (i + 1) * (sfs + 3.5) - 3.5 + sfs * .2, sfs, '#666', 400));
    });
    // 점: 분야 색 원 + 작은 흰 번호(점 지름의 40%)
    dots = rows.map(r => {
      const dg = el('g', { transform: `translate(${r.x.toFixed(1)},${r.y.toFixed(1)})`, style: 'cursor:pointer' }, g);
      const c = el('circle', { r: d, fill: r.th.hex, 'stroke-width': 1.2 }, dg);
      el('circle', { r: d + 2, fill: 'transparent' }, dg);
      const t = el('text', { y: d * .28, 'text-anchor': 'middle', 'font-size': (d * .8).toFixed(1), fill: '#fff', 'pointer-events': 'none' }, dg); t.textContent = r.no;
      dg.addEventListener('mouseenter', () => over(r)); dg.addEventListener('mousemove', mvT); dg.addEventListener('mouseleave', out);
      dg.addEventListener('click', () => ui.open(r.t.id));
      return { r, g: dg, c };
    });
    apply();
  }
  const ro = new ResizeObserver(draw); ro.observe(wrap); draw();
  return () => { ro.disconnect(); wrap.remove(); };
};
