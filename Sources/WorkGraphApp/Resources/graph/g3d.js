/* 입체 보기 공용 틀: 캔버스 하나에 3D 점을 돌려 원근으로 그린다.
   끌면 돌고, 놓으면 관성으로 돌다 천천히 혼자 돈다. 휠은 확대. 보기 파일(v3d_*.js)은 draw 만 쓴다.
   G3D(main, draw) → { view, destroy }
     draw(ctx, view, t): 매 프레임. view.project([x,y,z]) → { x, y, s, z, d } (좌표는 지름 2인 구 기준,
       s = 원근 배율, d = 0 먼 쪽 … 1 가까운 쪽). view.mouse = 커서 위치(밖이면 null), view.w, view.h
     view.onClick(fn): 끌지 않고 누른 위치 (x, y) 를 받는다. view.hold = true 면 혼자 돌기와 관성을 멈춘다 */
window.G3D = function (main, draw, opts = {}) {      // opts.mesh: 바탕 색 묶음 이름('brown' 기본, 'sky')
  const cv = document.createElement('canvas');
  cv.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;cursor:grab;touch-action:none';
  main.style.position = 'relative';
  const mesh = window.G3D.mesh(main, 0.8, opts.mesh);    // 캔버스 아래 흐르는 바탕
  main.appendChild(cv);
  const ctx = cv.getContext('2d');
  const v = { yaw: 0.5, pitch: -0.3, zoom: 1, dist: 2.4, w: 0, h: 0, mouse: null, dragging: false };   // dist: 작을수록 원근이 세다(앞뒤 크기 약 2.4배)
  let vy = 0.0012, vp = 0, raf = 0, drag = null, clickFn = null, moved = 0;

  v.project = p => {
    const cy = Math.cos(v.yaw), sy = Math.sin(v.yaw), cp = Math.cos(v.pitch), sp = Math.sin(v.pitch);
    const x = p[0] * cy - p[2] * sy, z1 = p[0] * sy + p[2] * cy;
    const y = p[1] * cp - z1 * sp, z = p[1] * sp + z1 * cp;
    const s = v.dist / (v.dist + z), R = Math.min(v.w, v.h) * 0.4 * v.zoom;
    return { x: v.w / 2 + x * s * R, y: v.h / 2 + y * s * R, s, z, d: (1 - z) / 2 };
  };
  v.onClick = fn => { clickFn = fn; };

  const size = () => {
    const r = main.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    v.w = r.width; v.h = r.height;
    cv.width = Math.round(v.w * dpr); cv.height = Math.round(v.h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    mesh?.size(v.w, v.h);
  };
  const ro = new ResizeObserver(size); ro.observe(main); size();

  const pos = e => { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  cv.addEventListener('pointerdown', e => { drag = pos(e); moved = 0; v.dragging = true; cv.setPointerCapture(e.pointerId); cv.style.cursor = 'grabbing'; });
  cv.addEventListener('pointermove', e => {
    const p = pos(e); v.mouse = p;
    if (!drag) return;
    const dx = p.x - drag.x, dy = p.y - drag.y; moved += Math.abs(dx) + Math.abs(dy);
    vy = dx * 0.006; vp = dy * 0.006;
    v.yaw += vy; v.pitch = Math.max(-1.4, Math.min(1.4, v.pitch + vp)); drag = p;
  });
  const up = e => {
    if (drag && moved < 4 && clickFn) clickFn(pos(e).x, pos(e).y);
    drag = null; v.dragging = false; cv.style.cursor = 'grab';
  };
  cv.addEventListener('pointerup', up);
  cv.addEventListener('pointercancel', up);
  cv.addEventListener('pointerleave', () => { if (!drag) v.mouse = null; });
  cv.addEventListener('wheel', e => { e.preventDefault(); v.zoom = Math.max(0.5, Math.min(4, v.zoom * Math.exp(-e.deltaY * 0.0015))); }, { passive: false });

  const frame = t => {
    if (!drag && !v.hold) {                              // 관성은 줄고, 혼자 도는 속도로 돌아간다 (view.hold = true 면 멈춘다: 확대해 볼 때)
      vy += (0.0012 - vy) * 0.04; vp *= 0.92;
      v.yaw += vy; v.pitch = Math.max(-1.4, Math.min(1.4, v.pitch + vp));
    }
    mesh?.draw(t);
    ctx.clearRect(0, 0, v.w, v.h);
    draw(ctx, v, t);
    raf = requestAnimationFrame(frame);
  };
  raf = requestAnimationFrame(frame);

  return { view: v, destroy() { cancelAnimationFrame(raf); ro.disconnect(); cv.remove(); mesh?.destroy(); } };
};
/* 입체 보기 바탕: 캔버스는 칠하지 않는다. 아래 갈색 흐름(G3D.mesh)과 창 유리가 그대로 보인다 */
window.G3D.glass = () => {};

/* 갈색 흐름 바탕: 포트폴리오 배경의 MeshGradient(speed .15)를 실록 갈색과 흰색 다섯 점으로, 일렁임은 조금 크게(distortion .7, swirl .35), 경계는 흐리게.
   Mesh gradient shader adapted from Paper Shaders (https://github.com/paper-design/shaders),
   Copyright 2026 Paper, Apache License 2.0 (vendor/paper-shaders-LICENSE, vendor/paper-shaders-NOTICE).
   바꾼 점: 입자(grain) 제거, 크기 맞춤 정점 셰이더를 단순한 전체 화면 사각형으로 */
window.G3D.mesh = function (main, OPACITY = 0.8, TONE = 'brown') {   // 진하기: 입체 보기 .8, 짙은 점 보기(연결망) .34. TONE: 'brown' | 'sky'
  const BROWN = [0x24 / 255, 0x15 / 255, 0x0f / 255], SPEED = 0.15, SCALE = 0.08;   // SCALE: 아주 작게 그려 늘이면 흐림 효과가 공짜로 난다(CSS blur 는 매 장면 무거웠다)
  const cv = document.createElement('canvas');
  cv.className = 'g3dmesh';
  cv.style.cssText = `position:absolute;inset:0;width:100%;height:100%;pointer-events:none;opacity:${OPACITY}`;
  const gl = cv.getContext('webgl2', { premultipliedAlpha: true, alpha: true, antialias: false });
  if (!gl) return null;
  main.appendChild(cv);
  const VS = `#version 300 es
in vec2 a; uniform vec2 u_aspect; out vec2 v_objectUV;
void main() { v_objectUV = a * .5 * u_aspect; gl_Position = vec4(a, 0., 1.); }`;
  const FS = `#version 300 es
precision mediump float;
uniform float u_time; uniform vec4 u_colors[5]; uniform float u_distortion; uniform float u_swirl;
in vec2 v_objectUV; out vec4 fragColor;
vec2 rotate(vec2 uv, float th) { return mat2(cos(th), sin(th), -sin(th), cos(th)) * uv; }
vec2 getPosition(int i, float t) {
  float a = float(i) * .37; float b = .6 + fract(float(i) / 3.) * .9; float c = .8 + fract(float(i + 1) / 4.);
  return .5 + .5 * vec2(sin(t * b + a), cos(t * c + a * 1.5));
}
void main() {
  vec2 uv = v_objectUV + .5;
  float t = .5 * (u_time + 41.5);
  float radius = smoothstep(0., 1., length(uv - .5)), center = 1. - radius;
  for (float i = 1.; i <= 2.; i++) {
    uv.x += u_distortion * center / i * sin(t + i * .4 * smoothstep(.0, 1., uv.y)) * cos(.2 * t + i * 2.4 * smoothstep(.0, 1., uv.y));
    uv.y += u_distortion * center / i * cos(t + i * 2. * smoothstep(.0, 1., uv.x));
  }
  vec2 r = rotate(uv - .5, -3. * u_swirl * radius) + .5;
  vec3 color = vec3(0.); float opacity = 0., total = 0.;
  for (int i = 0; i < 5; i++) {
    float w = 1. / (pow(length(r - getPosition(i, t)), 1.5) + 1e-3);   // 낮을수록 색이 고르게 섞인다(원본 3.5)
    color += u_colors[i].rgb * u_colors[i].a * w; opacity += u_colors[i].a * w; total += w;
  }
  fragColor = vec4(color / total, clamp(opacity / total, 0., 1.));
}`;
  const sh = (type, src) => { const x = gl.createShader(type); gl.shaderSource(x, src); gl.compileShader(x); return x; };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { cv.remove(); return null; }
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'a'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = n => gl.getUniformLocation(prog, n);
  const WHITE = [0.98, 0.96, 0.93], SKY = [0xB4 / 255, 0xD0 / 255, 0xE4 / 255], SKY_DEEP = [0x5E / 255, 0x8F / 255, 0xB3 / 255];
  const TONES = {
    brown: [...BROWN, 0.85, ...WHITE, 0.9, ...BROWN, 0.55, ...WHITE, 0.8, ...BROWN, 0.7],   // 갈색과 흰빛이 고르게 섞이게 진하기 차이를 줄임   // 갈색 셋, 흰색 둘: 갈색 위주에 흰빛이 섞여 흐른다
    sky: [...SKY, 1, ...SKY_DEEP, 0.85, ...SKY, 1, ...SKY_DEEP, 0.7, ...WHITE, 0.35],   // 하늘: 연한 파랑과 짙은 하늘 위주, 흰빛은 조금(흰 구름이 묻히지 않게)
  };
  gl.uniform4fv(U('u_colors'), TONES[TONE] || TONES.brown);
  gl.uniform1f(U('u_distortion'), 0.7); gl.uniform1f(U('u_swirl'), 0.35);
  const uTime = U('u_time'), uAspect = U('u_aspect');
  let t0 = 0;
  return {
    size(w, h) { cv.width = Math.max(1, Math.round(w * SCALE)); cv.height = Math.max(1, Math.round(h * SCALE)); gl.viewport(0, 0, cv.width, cv.height); const m = Math.min(w, h) || 1; gl.uniform2f(uAspect, w / m, h / m); },
    draw(t) { if (!t0) t0 = t; gl.uniform1f(uTime, (t - t0) * 1e-3 * SPEED); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4); },
    destroy() { cv.remove(); gl.getExtension('WEBGL_lose_context')?.loseContext(); },
  };
};
/* 다른 보기 밑에 갈색 흐름만 깐다: 자기 rAF 로 돌고, 끌 함수를 돌려준다 */
window.G3D.meshBg = function (el, opacity) {
  el.style.position = 'relative';
  const m = window.G3D.mesh(el, opacity); if (!m) return () => {};
  el.prepend(el.lastChild);                               // 맨 아래 층으로
  const ro = new ResizeObserver(() => { const r = el.getBoundingClientRect(); m.size(r.width, r.height); }); ro.observe(el);
  let raf = 0; const f = t => { m.draw(t); raf = requestAnimationFrame(f); }; raf = requestAnimationFrame(f);
  return () => { cancelAnimationFrame(raf); ro.disconnect(); m.destroy(); };
};
window.V3D = window.V3D || {};
