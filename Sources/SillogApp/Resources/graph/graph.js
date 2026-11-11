/* Sillog 그래프 뷰. Swift(WKWebView)와는 window.WG.setGraph(data) / postMessage 로만 대화한다. */
(() => {
  'use strict';

  const GROUPS = {
    Theme:       { name: '분야',        color: '#7c4dff' },
    Task:        { name: '업무',        color: '#a882ff' },
    Session:     { name: '세션',        color: '#7f8ea3' },
    ResourceRef: { name: '참고자료',    color: '#5aa9e6' },
    ResourceOut: { name: '산출물',      color: '#7bc47f' },
    App:         { name: '앱',          color: '#e0a458' },
    Topic:       { name: '주제',        color: '#ef7a9a' },
    Problem:     { name: '문제',        color: '#f2665e' },
    Project:     { name: '프로젝트',    color: '#4fd1c5' },
    LaterItem:   { name: '나중에 할 일', color: '#f6d365' },
    File:        { name: '파일',        color: '#9aa5b1' },
    Class:       { name: '클래스 층',   color: '#c9c9c9' },
  };
  const GROUP_ORDER = Object.keys(GROUPS);
  const OUTPUT_SUBTYPES = new Set(['CodeFile', 'Note', 'Document', 'Design']);
  const LABEL_NAMES = { Theme: '분야', Task: '업무', Session: '세션', Resource: '자료', App: '앱', Topic: '주제', Problem: '문제', Project: '프로젝트',
                        LaterItem: '나중에 할 일', File: '파일', Folder: '폴더', TaskType: '업무 종류', ResourceType: '자료 종류' };
  const EDGE_NAMES = {
    PART_OF:        ['속한 업무', '세션'],
    INSTANCE_OF:    ['종류', '이 종류에 속한 것'],
    SUBCLASS_OF:    ['상위 종류', '하위 종류'],
    USED:           ['사용한 앱', '이 앱을 쓴 세션'],
    TOUCHED:        ['본 자료', '이 자료를 본 세션'],
    ABOUT:          ['주제', '이 주제의 업무'],
    BELONGS_TO:     ['프로젝트', '프로젝트의 자료'],
    ON:             ['프로젝트', '이 프로젝트의 업무'],
    HIT:            ['겪은 문제', '문제를 겪은 세션'],
    RESOLVED_BY:    ['해결한 자료', '해결한 문제'],
    SWITCHED_TO:    ['다음 세션', '이전 세션'],
    FOR:            ['대상 업무', '나중에 할 일'],
    CREATED_DURING: ['만들어진 세션', '이때 만든 파일'],
    DERIVED_FROM:   ['출처', '여기서 받은 파일'],
  };
  // 업무 → 분야 의 PART_OF 는 세션 → 업무 와 이름이 다르다
  function edgeTitle(link, outgoing) {
    if (link.type === 'PART_OF' && state.byId.get(link.target)?.label === 'Theme') return outgoing ? '분야' : '이 분야의 업무';
    return (EDGE_NAMES[link.type] || [link.type, link.type])[outgoing ? 0 : 1];
  }
  const LINK_DISTANCE = { PART_OF: 34, TOUCHED: 48, USED: 62, ABOUT: 58, SWITCHED_TO: 70, INSTANCE_OF: 80, SUBCLASS_OF: 40 };
  const SWITCH_COLORS = { drift: '242,102,94', blocked: '224,164,88', planned: '127,142,163', unknown: '127,142,163' };
  const TIME_PROPS = new Set(['start', 'end', 'last_active', 'started_at', 'at']);
  const PROP_NAMES = { active_seconds: '작업 시간', start: '시작', end: '끝', last_active: '마지막 활동', started_at: '처음 시작',
                       status: '상태', summary: '요약', kind: '종류', done: '완료 여부', at: '시각', source_app: '받은 곳' };
  const HIDDEN_PROPS = new Set(['last_seen', 'summary', 'project_seconds']);
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const $ = id => document.getElementById(id);
  const state = { raw: { nodes: [], links: [] }, byId: new Map(), hidden: new Set(), hours: 0, tbox: false, labels: false,
                  local: false, depth: 2, query: '', selected: null, hover: null, neighbors: new Set(), matched: null,
                  visible: { nodes: [], links: [] }, didFit: false };

  function groupOf(node) {
    if (node.label === 'TaskType' || node.label === 'ResourceType') return 'Class';
    if (node.label === 'Resource') return OUTPUT_SUBTYPES.has(node.subtype) ? 'ResourceOut' : 'ResourceRef';
    if (node.label === 'Folder') return 'File';
    return GROUPS[node.label] ? node.label : 'File';
  }
  const colorOf = node => GROUPS[groupOf(node)].color;

  function post(message) {
    try { window.webkit.messageHandlers.wg.postMessage(message); return true; } catch (_) { return false; }
  }
  // 화면에서 난 오류는 앱 로그로 보낸다 (패널이 비는 식의 문제를 나중에 추적할 수 있게)
  window.addEventListener('error', event => post({ type: 'log', message: `graph.js 오류: ${event.message} (${event.lineno}:${event.colno})` }));
  window.addEventListener('unhandledrejection', event => post({ type: 'log', message: `graph.js 오류: ${event.reason}` }));

  // ── 그래프 ────────────────────────────────────────────────────────────────
  const Graph = ForceGraph()($('graph'))
    .backgroundColor('#1e1e1e')
    .nodeId('id')
    .nodeLabel(() => '')
    .nodeCanvasObject(drawNode)
    .nodePointerAreaPaint((node, color, ctx) => {
      ctx.fillStyle = color;
      ctx.beginPath(); ctx.arc(node.x, node.y, node.r + 3, 0, 2 * Math.PI); ctx.fill();
    })
    .linkColor(linkColor)
    .linkWidth(link => (isLit(link) ? 1.6 : 0.7))
    .linkLineDash(link => (link.type === 'SWITCHED_TO' ? [4, 3] : null))
    .linkDirectionalArrowLength(link => (link.type === 'SWITCHED_TO' ? 5 : 0))
    .linkDirectionalArrowRelPos(1)
    .onNodeHover(node => { state.hover = node || null; refreshHighlight(); $('graph').style.cursor = node ? 'pointer' : 'default'; })
    .onNodeClick(node => select(node, false))
    .onBackgroundClick(() => select(null))
    .onNodeDragEnd(node => { node.fx = node.x; node.fy = node.y; })
    .onEngineStop(() => { if (!state.didFit && state.visible.nodes.length) { state.didFit = true; Graph.zoomToFit(reduceMotion ? 0 : 500, 70); } })
    .warmupTicks(reduceMotion ? 240 : 0)
    .cooldownTicks(reduceMotion ? 0 : 240)
    .d3VelocityDecay(0.35);
  Graph.d3Force('charge').strength(-120).distanceMax(460);
  Graph.d3Force('link').distance(link => {
    // 분야와 업무 사이는 넉넉히 띄운다 (업무 묶음이 분야 둘레에 퍼지게)
    const target = typeof link.target === 'object' ? link.target : state.byId.get(link.target);
    if (link.type === 'PART_OF' && target && target.label === 'Theme') return 90;
    return LINK_DISTANCE[link.type] || 55;
  });

  // 웹뷰는 크기가 0 인 채로 시작했다가 나중에 커진다. 크기가 바뀌면 (노드를 고르지 않은 동안은) 화면에 다시 맞춘다.
  let refitTimer = null;
  function resize() {
    Graph.width(window.innerWidth).height(window.innerHeight);
    clearTimeout(refitTimer);
    refitTimer = setTimeout(() => { if (!state.selected && state.visible.nodes.length) Graph.zoomToFit(0, 70); }, 180);
  }
  window.addEventListener('resize', resize);

  function endpoints(link) {
    return [typeof link.source === 'object' ? link.source.id : link.source, typeof link.target === 'object' ? link.target.id : link.target];
  }

  function focusId() { return state.hover ? state.hover.id : (state.selected ? state.selected.id : null); }

  function isLit(link) {
    const focus = focusId();
    if (focus === null) return false;
    const [s, t] = endpoints(link);
    return s === focus || t === focus;
  }

  function nodeAlpha(node) {
    const focus = focusId();
    if (focus !== null) return node.id === focus || state.neighbors.has(node.id) ? 1 : 0.12;
    if (state.matched) return state.matched.has(node.id) ? 1 : 0.12;
    return 1;
  }

  function linkColor(link) {
    const lit = isLit(link);
    if (link.type === 'SWITCHED_TO') {
      const rgb = SWITCH_COLORS[(link.props && link.props.kind) || 'unknown'] || SWITCH_COLORS.unknown;
      return `rgba(${rgb},${lit ? 0.95 : (focusId() === null && !state.matched ? 0.55 : 0.08)})`;
    }
    if (lit) return 'rgba(168,130,255,0.75)';
    return focusId() !== null || state.matched ? 'rgba(255,255,255,0.03)' : 'rgba(255,255,255,0.11)';
  }

  function drawNode(node, ctx, scale) {
    const alpha = nodeAlpha(node);
    const color = colorOf(node);
    const isClass = groupOf(node) === 'Class';
    ctx.globalAlpha = alpha;
    ctx.beginPath();
    ctx.arc(node.x, node.y, node.r, 0, 2 * Math.PI);
    if (isClass) {                       // 클래스 층은 속이 빈 고리, 인스턴스는 채운 점
      ctx.lineWidth = Math.max(1.4, 1.8 / scale);
      ctx.strokeStyle = color;
      ctx.stroke();
    } else {
      ctx.fillStyle = color;
      ctx.fill();
    }
    if (state.selected && state.selected.id === node.id) {
      ctx.beginPath();
      ctx.arc(node.x, node.y, node.r + 3 / scale, 0, 2 * Math.PI);
      ctx.lineWidth = 1.5 / scale;
      ctx.strokeStyle = '#ffffff';
      ctx.stroke();
    }

    // 라벨: 업무는 멀리서도, 나머지는 줌 인하거나 강조될 때만 (옵시디언처럼 서서히 나타남)
    const focus = focusId();
    const emphasized = focus !== null && (node.id === focus || state.neighbors.has(node.id));
    let labelAlpha = 0;
    if (state.labels || emphasized || (state.matched && state.matched.has(node.id))) labelAlpha = 1;
    else if (node.label === 'Theme') labelAlpha = Math.min(1, Math.max(0, (scale - 0.2) / 0.2));
    else if (node.label === 'Task') labelAlpha = Math.min(1, Math.max(0, (scale - 0.45) / 0.3));
    else labelAlpha = Math.min(1, Math.max(0, (scale - 1.5) / 0.7));
    if (labelAlpha > 0.02 && alpha > 0.5) {
      const size = (node.label === 'Theme' ? 14 : node.label === 'Task' ? 12 : 10.5) / scale;
      ctx.font = `${node.label === 'Theme' ? 700 : node.label === 'Task' ? 600 : 400} ${size}px -apple-system, "Apple SD Gothic Neo", sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      ctx.globalAlpha = alpha * labelAlpha;
      ctx.fillStyle = emphasized ? '#ffffff' : '#c8c8c8';
      ctx.fillText(clip(node.title || node.key, 30), node.x, node.y + node.r + 2.5 / scale);
    }
    ctx.globalAlpha = 1;
  }

  const clip = (text, n) => (text.length > n ? text.slice(0, n - 1) + '…' : text);

  // ── 데이터 → 화면 ─────────────────────────────────────────────────────────
  function setGraph(data) {
    const nodes = (data && data.nodes) || [];
    const links = (data && data.links) || [];
    const next = new Map();
    for (const n of nodes) {
      const previous = state.byId.get(n.id);          // 위치를 유지하려고 같은 객체를 재사용
      next.set(n.id, previous ? Object.assign(previous, n) : Object.assign({}, n));
    }
    state.byId = next;
    state.raw = { nodes: [...next.values()], links };
    if (state.selected) state.selected = next.get(state.selected.id) || null;
    applyFilters();
    if (state.selected) showDetail(state.selected); else $('detail').hidden = true;
  }

  function applyFilters() {
    const cutoff = state.hours > 0 ? Date.now() / 1000 - state.hours * 3600 : 0;
    let allowed = state.raw.nodes.filter(n => {
      const group = groupOf(n);
      if (group === 'Class') return state.tbox;
      if (state.hidden.has(group)) return false;
      return cutoff === 0 || (n.updatedAt || 0) >= cutoff;
    });
    let ids = new Set(allowed.map(n => n.id));

    if (state.local && state.selected && ids.has(state.selected.id)) {
      const adjacency = new Map();
      for (const l of state.raw.links) {
        if (!ids.has(l.source) || !ids.has(l.target)) continue;
        (adjacency.get(l.source) || adjacency.set(l.source, []).get(l.source)).push(l.target);
        (adjacency.get(l.target) || adjacency.set(l.target, []).get(l.target)).push(l.source);
      }
      const reach = new Set([state.selected.id]);
      let frontier = [state.selected.id];
      for (let d = 0; d < state.depth; d++) {
        const nextFrontier = [];
        for (const id of frontier) for (const other of adjacency.get(id) || []) {
          if (!reach.has(other)) { reach.add(other); nextFrontier.push(other); }
        }
        frontier = nextFrontier;
      }
      allowed = allowed.filter(n => reach.has(n.id));
      ids = reach;
    }

    const links = state.raw.links.filter(l => ids.has(l.source) && ids.has(l.target)).map(l => Object.assign({}, l));
    const degree = new Map();
    for (const l of links) { degree.set(l.source, (degree.get(l.source) || 0) + 1); degree.set(l.target, (degree.get(l.target) || 0) + 1); }
    for (const n of allowed) {
      n.degreeVisible = degree.get(n.id) || 0;
      n.r = (n.label === 'Theme' ? 8 : n.label === 'Task' ? 5 : 2.6) + Math.sqrt(n.degreeVisible) * 1.35;
    }
    state.visible = { nodes: allowed, links };
    Graph.graphData(state.visible);
    applySearch();
    refreshHighlight();
    renderLegend();
    const instanceCount = state.raw.nodes.filter(n => groupOf(n) !== 'Class').length;
    $('empty').hidden = instanceCount > 0;
    $('controls').hidden = instanceCount === 0;
    $('stats').textContent = `노드 ${allowed.length}개, 연결 ${links.length}개`;
  }

  function refreshHighlight() {
    const focus = focusId();
    state.neighbors = new Set();
    if (focus !== null) for (const l of state.visible.links) {
      const [s, t] = endpoints(l);
      if (s === focus) state.neighbors.add(t);
      if (t === focus) state.neighbors.add(s);
    }
    // 색·굵기 접근자를 다시 평가시키고, 시뮬레이션이 멈춘 뒤에도 캔버스를 다시 그리게 한다.
    Graph.linkColor(Graph.linkColor()).linkWidth(Graph.linkWidth());
  }

  function applySearch() {
    const q = state.query.trim().toLowerCase();
    state.matched = q ? new Set(state.visible.nodes.filter(n => `${n.title} ${n.key} ${n.subtype || ''}`.toLowerCase().includes(q)).map(n => n.id)) : null;
  }

  function renderLegend() {
    const counts = {};
    for (const n of state.raw.nodes) { const g = groupOf(n); counts[g] = (counts[g] || 0) + 1; }
    const list = $('legend');
    list.textContent = '';
    for (const group of GROUP_ORDER) {
      if (!counts[group] || (group === 'Class' && !state.tbox)) continue;
      const item = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      button.className = state.hidden.has(group) ? 'off' : '';
      button.setAttribute('aria-pressed', String(!state.hidden.has(group)));
      const dot = document.createElement('span');
      dot.className = 'dot' + (group === 'Class' ? ' ring' : '');
      dot.style.background = GROUPS[group].color;
      dot.style.color = GROUPS[group].color;
      const name = document.createElement('span');
      name.textContent = GROUPS[group].name;
      const count = document.createElement('span');
      count.className = 'count';
      count.textContent = counts[group];
      button.append(dot, name, count);
      button.addEventListener('click', () => {
        if (group === 'Class') return;
        state.hidden.has(group) ? state.hidden.delete(group) : state.hidden.add(group);
        applyFilters();
      });
      item.append(button);
      list.append(item);
    }
  }

  // ── 선택 · 상세 패널 ──────────────────────────────────────────────────────
  function select(node, center = true) {
    state.selected = node || null;
    if (state.local) applyFilters(); else refreshHighlight();
    if (!node) { $('detail').hidden = true; return; }
    showDetail(node);
    if (center && Number.isFinite(node.x)) {
      Graph.centerAt(node.x, node.y, reduceMotion ? 0 : 450);
      if (Graph.zoom() < 1.8) Graph.zoom(2.2, reduceMotion ? 0 : 450);
    }
  }

  function duration(seconds) {
    const s = Math.round(seconds || 0);
    if (s < 60) return `${s}초`;
    const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
    return h ? `${h}시간 ${m}분` : `${m}분`;
  }

  function clock(ts) {
    return new Date(ts * 1000).toLocaleString('ko-KR', { month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  }

  function openTarget(key) {
    if (/^https?:\/\//.test(key) || key.startsWith('file:')) return key;
    if (key.startsWith('arxiv:')) return 'https://arxiv.org/abs/' + key.slice(6);
    if (key.startsWith('doi:')) return 'https://doi.org/' + key.slice(4);
    if (key.startsWith('local:')) return 'http://localhost:' + key.slice(6);
    return null;
  }

  function showDetail(node) {
    const group = GROUPS[groupOf(node)];
    const kind = $('detailKind');
    kind.textContent = '';
    const dot = document.createElement('span');
    dot.className = 'dot';
    dot.style.background = group.color;
    kind.append(dot, document.createTextNode([LABEL_NAMES[node.label] || node.label, node.subtype].filter(Boolean).join(' / ')));
    $('detailTitle').textContent = node.title || node.key;
    $('detailKey').textContent = node.title && node.key !== node.title ? node.key : '';

    const target = openTarget(node.key);
    const open = $('openKey');
    open.hidden = !target;
    open.onclick = () => { if (!post({ type: 'open', uri: target }) && /^https?:/.test(target)) window.open(target, '_blank', 'noopener'); };
    const resume = $('resumeKey');                       // 업무·세션: 그때 쓰던 파일·페이지·앱을 다시 연다
    resume.hidden = !(node.label === 'Task' || node.label === 'Session');
    resume.onclick = () => post({ type: 'resume', label: node.label, key: node.key });

    // 속성
    const props = $('detailProps');
    props.textContent = '';
    const rows = [];
    let watched = 0;
    for (const l of state.raw.links) {
      if (l.target === node.id && (l.type === 'TOUCHED' || l.type === 'USED')) watched += l.weight || 0;
    }
    if (watched > 0) rows.push([node.label === 'App' ? '사용 시간' : '본 시간', duration(watched)]);
    for (const [key, value] of Object.entries(node.props || {})) {
      if (HIDDEN_PROPS.has(key) || value === null || value === '') continue;
      if (key === 'summaries') {                        // 세션: 배치마다 쌓인 "한 일" 목록
        if (Array.isArray(value) && value.length) rows.push(['한 일', value.map(v => '· ' + v).join('\n')]);
        continue;
      }
      let text = String(value);
      if (key === 'active_seconds') text = duration(value);
      else if (TIME_PROPS.has(key) && typeof value === 'number') text = clock(value);
      else if (key === 'done') text = value ? '완료' : '아직';
      else if (key === 'status') text = value === 'active' ? '진행 중' : value === 'done' ? '끝남' : text;
      rows.push([PROP_NAMES[key] || key, text]);
    }
    for (const [name, text] of rows) {
      const dt = document.createElement('dt'); dt.textContent = name;
      const dd = document.createElement('dd'); dd.textContent = text;
      props.append(dt, dd);
    }

    // 연결: 방향과 종류별로 묶어서 보여준다
    const groups = new Map();
    for (const l of state.raw.links) {
      const outgoing = l.source === node.id, incoming = l.target === node.id;
      if (!outgoing && !incoming) continue;
      const other = state.byId.get(outgoing ? l.target : l.source);
      if (!other) continue;
      const title = edgeTitle(l, outgoing);
      if (!groups.has(title)) groups.set(title, []);
      groups.get(title).push({ other, link: l });
    }
    const container = $('detailLinks');
    container.textContent = '';
    for (const [title, items] of groups) {
      const heading = document.createElement('h2');
      heading.textContent = `${title} ${items.length}`;
      const list = document.createElement('ul');
      items.sort((a, b) => (b.link.weight || 0) - (a.link.weight || 0) || (b.link.lastAt || 0) - (a.link.lastAt || 0));
      for (const { other, link } of items.slice(0, 40)) {
        const li = document.createElement('li');
        const button = document.createElement('button');
        button.type = 'button';
        const d = document.createElement('span'); d.className = 'dot'; d.style.background = colorOf(other);
        const name = document.createElement('span'); name.className = 'name'; name.textContent = other.title || other.key;
        const meta = document.createElement('span'); meta.className = 'meta';
        if (link.type === 'TOUCHED' || link.type === 'USED' || (link.type === 'ON' && link.weight > 0)) meta.textContent = duration(link.weight);
        else if (link.type === 'SWITCHED_TO') meta.textContent = { drift: '딴짓', blocked: '막혀서', planned: '계획대로', unknown: '' }[(link.props || {}).kind || 'unknown'];
        button.append(d, name, meta);
        button.addEventListener('click', () => {
          const visibleNode = state.visible.nodes.find(n => n.id === other.id);
          select(visibleNode || other, Boolean(visibleNode));
        });
        li.append(button);
        list.append(li);
      }
      container.append(heading, list);
    }
    $('detail').hidden = false;
  }

  // ── 컨트롤 ────────────────────────────────────────────────────────────────
  $('search').addEventListener('input', event => { state.query = event.target.value; applySearch(); refreshHighlight(); });
  $('search').addEventListener('keydown', event => {
    if (event.key === 'Enter' && state.matched && state.matched.size) {
      const first = state.visible.nodes.find(n => state.matched.has(n.id));
      if (first) select(first);
    }
    if (event.key === 'Escape') { event.target.value = ''; state.query = ''; applySearch(); refreshHighlight(); event.target.blur(); }
  });
  document.addEventListener('keydown', event => {
    if (event.key === '/' && document.activeElement !== $('search')) { event.preventDefault(); $('search').focus(); }
    else if (event.key === 'Escape' && document.activeElement !== $('search')) select(null);
  });
  for (const button of $('range').querySelectorAll('button')) {
    button.addEventListener('click', () => {
      for (const other of $('range').querySelectorAll('button')) { other.classList.remove('on'); other.setAttribute('aria-checked', 'false'); }
      button.classList.add('on'); button.setAttribute('aria-checked', 'true');
      state.hours = Number(button.dataset.hours);
      applyFilters();
    });
  }
  $('tbox').addEventListener('change', event => { state.tbox = event.target.checked; state.didFit = false; applyFilters(); });
  $('labels').addEventListener('change', event => { state.labels = event.target.checked; refreshHighlight(); });
  $('local').addEventListener('change', event => { state.local = event.target.checked; syncDepth(); state.didFit = false; applyFilters(); });
  $('depth').addEventListener('input', event => { state.depth = Number(event.target.value); $('depthOut').textContent = event.target.value; if (state.local) applyFilters(); });
  $('closeDetail').addEventListener('click', () => select(null));
  $('runBatch').addEventListener('click', () => post({ type: 'runBatch' }));
  function syncDepth() { $('depthRow').classList.toggle('disabled', !state.local); $('depth').disabled = !state.local; }
  syncDepth();

  // ── 시작 ──────────────────────────────────────────────────────────────────
  resize();
  window.WG = {
    setGraph,
    select(key) { const node = state.raw.nodes.find(n => n.key === key); if (node) select(node); },
  };
  if (window.__WG_DATA__) {
    setGraph(window.__WG_DATA__);
  } else {
    const source = new URLSearchParams(location.search).get('data');
    if (source) fetch(source).then(r => r.json()).then(setGraph).catch(() => setGraph({ nodes: [], links: [] }));
    else setGraph({ nodes: [], links: [] });
  }
  post({ type: 'ready' });
})();
