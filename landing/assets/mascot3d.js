/* SILLOG mascot3d.js - 실록 랜딩 소개 구역 solo 마스코트 (순수 WebGL, SDF 레이마칭)
 * 바뀔 때만 그린다: 처음 보일 때, 크기가 바뀔 때, 깜빡임(3~5초, 4프레임), 마우스 따라 보기(20fps 이하, 1도 넘게 어긋났을 때만).
 * 상시 rAF 루프 없음. 스크롤 중에는 모두 쉬고 마지막 스크롤 150ms 뒤에 재개. 들썩임과 폴짝은 페이지가 CSS로 한다.
 * 컨텍스트 1개(숨은 캔버스)에 그린 뒤 각 canvas[data-m3d="solo"]의 2D 컨텍스트로 drawImage.
 * hero, row, icon 장면은 이 판에 없다(구운 그림을 쓴다). 전역: window.SillogMascot = { supported, refresh(), stats } */
(function () {
  'use strict';
  var W = window, D = document, PI = Math.PI;
  var API = W.SillogMascot = { supported: false, refresh: function () {}, error: '', stats: { draws: 0, raf: 0, ms: {} } };
  var RM = !!(W.matchMedia && W.matchMedia('(prefers-reduced-motion: reduce)').matches);
  var DPRMAX = Math.min(W.devicePixelRatio || 1, 2);
  var VS = 'attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}';

  var FS_M = [
'precision highp float;',
'uniform vec2 uVp,uOrigin;uniform float uPpu,uAlpha,uSteps,uAO;',
'uniform mat3 uRot;uniform vec3 uCol;uniform vec4 uA,uB,uFog;',
'float smin(float a,float b,float k){float h=max(k-abs(a-b),0.)/k;return min(a,b)-h*h*k*.25;}',
'float sdE(vec3 p,vec3 r){float k0=length(p/r);float k1=length(p/(r*r));return k0*(k0-1.)/max(k1,1e-4);}',
'float sdCap(vec3 p,float hl,float r){p.y-=clamp(p.y,-hl,hl);return length(p)-r;}',
'float sdArc(vec2 p,vec2 sc,float ra,float rb){p.x=abs(p.x);return((sc.y*p.x>sc.x*p.y)?length(p-sc*ra):abs(length(p)-ra))-rb;}',
'float sdRB(vec3 p,vec3 b,float r){vec3 q=abs(p)-b+r;return length(max(q,0.))+min(max(q.x,max(q.y,q.z)),0.)-r;}',
'mat2 rot2(float a){float c=cos(a),s=sin(a);return mat2(c,-s,s,c);}',
'float pill2(vec2 p,float hw,float hh){return length(vec2(max(abs(p.x)-(hw-hh),0.),p.y))-hh;}',
'float ext(float d2,float z,float th,float r){vec2 w=vec2(d2+r,abs(z)-th+r);return min(max(w.x,w.y),0.)+length(max(w,0.))-r;}',
/* 눈 */
'float eyeD(vec3 p,float sx){',
'  vec2 c=vec2(sx*(uA.w<.5?.33:.4)+uB.x*.04,.21+uB.y*.03);',
'  float zs=.95*sqrt(max(1.-p.x*p.x-pow((p.y+.03)/.98,2.),.02));',
'  vec3 q=vec3(p.xy-c,p.z-zs+.05);',
'  if(uA.w<.5){q.z*=1.3;q.y/=max(uA.z,.1);return sdCap(q,.18,.17)*.75;}',
'  q.z-=.075;vec2 a2=q.xy+vec2(0.,.045);',
'  float da=sdArc(a2,vec2(sin(1.25),cos(1.25)),.275,.052);',
'  vec2 w=vec2(da,abs(q.z)-.055);return(min(max(w.x,w.y),0.)+length(max(w,0.)))*.75;}',
/* 마스코트 */
'vec2 mapM(vec3 p){',
'  p.y-=uA.x;p.y/=(1.+uA.y);p.xz/=(1.-.5*uA.y);',
'  float db=sdE(p-vec3(0.,-.03,0.),vec3(1.02,.98,.95));',
'  vec3 q=p-vec3(0.,1.04,.02);q.yz=rot2(.10)*q.yz;',
'  q.y+=.10*q.x*q.x+.16*q.z*q.z;q.z*=.44;q.x-=clamp(q.x,-.62,.62);',
'  float dbr=(length(q)-.41)*.8;',
'  float dk=sdE(p-vec3(.08,1.46,-.04),vec3(.5,.33,.44));',
'  float d=smin(db,dbr,.06);d=smin(d,dk,.14);',
'  float w=uB.z;',
'  d=smin(d,length(p-vec3(-1.18,.10+w*.05,0.))-.25,.16);',
'  d=smin(d,length(p-vec3(1.2,.12-w*.05,0.))-.245,.16);',
'  d=smin(d,sdE(p-vec3(-.45,-1.0,.1),vec3(.33,.3,.35)),.06);',
'  d=smin(d,sdE(p-vec3(.41,-1.01,.1),vec3(.33,.3,.35)),.06);',
'  vec3 eq=abs(p-vec3(0.,.3,.7))-vec3(.9,.6,.45);float eb=length(max(eq,0.))+min(max(eq.x,max(eq.y,eq.z)),0.);',
'  float de=eb>.12?eb:min(eyeD(p,-1.),eyeD(p,1.));',
'  float kk=uPpu*1.6;return vec2(min(de,d),smoothstep(-kk,kk,d-de));}',
'vec2 map(vec3 p){return mapM(p);}',
'vec3 nrm(vec3 p,float e){vec2 k=vec2(1.,-1.);',
'  return normalize(k.xyy*map(p+k.xyy*e).x+k.yyx*map(p+k.yyx*e).x+k.yxy*map(p+k.yxy*e).x+k.xxx*map(p+k.xxx*e).x);}',
'void main(){',
'  vec2 px=(gl_FragCoord.xy-uVp-uOrigin)*uPpu;',
'  vec3 ro=vec3(0.,0.,9.);vec3 rd=normalize(vec3(px,0.)-ro);',
'  vec3 rl=ro*uRot,dl=rd*uRot;',
'  vec3 bc=vec3(0.,.35,0.);vec3 br=vec3(1.55,1.85,1.15);',
'  vec3 oc=(rl-bc)/br,dd=dl/br;float qa=dot(dd,dd);float bq=dot(oc,dd);float cq=dot(oc,oc)-1.;float disc=bq*bq-qa*cq;',
'  if(disc<0.){gl_FragColor=vec4(0.);return;}',
'  float sq=sqrt(disc);float t=(-bq-sq)/qa,tf=(-bq+sq)/qa;',
'  float pw=uPpu;float mind=1e9,tm=t;bool hit=false;',
'  for(int i=0;i<64;i++){',
'    if(float(i)>=uSteps)break;',
'    vec2 h=map(rl+dl*t);',
'    if(h.x<mind){mind=h.x;tm=t;}',
'    if(h.x<pw*.45){hit=true;tm=t;break;}',
'    t+=h.x*.95;if(t>tf)break;}',
'  float al=hit?1.:1.-smoothstep(pw*.3,pw*1.5,mind);',
'  if(al<=0.){gl_FragColor=vec4(0.);return;}',
'  vec3 p=rl+dl*tm;vec2 hm=map(p);vec3 n=nrm(p,pw*.6);',
'  vec3 nv=uRot*n;vec3 V=-rd;',
'  float ao=0.;if(uAO>.5){for(int i=1;i<3;i++){float s=.07*float(i);ao+=(s-max(map(p+n*s).x,0.))/s*(.6/float(i));}}',
'  ao=clamp(1.-.85*ao,0.,1.);',
'  vec3 L=normalize(vec3(-.45,.75,.55));',
'  float nl=dot(nv,L);float fr=pow(1.-max(dot(nv,V),0.),2.2);',
'  vec3 col;',
'  {',
'    float df=nl*.5+.5;df*=df;',
'    float pa=smoothstep(.1,.6,uCol.r);vec3 S=uCol*mix(vec3(.42,.58,.58),vec3(.72,.8,.8),pa);',
'    float lf=pow(clamp(nl*.5+.65,0.,1.),2.2);vec3 cb=mix(S,uCol,.40*lf)*mix(.74,1.,ao);',
'    cb+=uCol*fr*.5*mix(.6,1.,ao)+vec3(.035)*fr;',
'    float up=clamp(n.y*.5+.5,0.,1.);',
'    vec3 ce=mix(vec3(.80,.84,.86),vec3(1.),up)*mix(.78,1.,ao);',
'    ce+=pow(max(dot(reflect(-L,nv),V),0.),24.)*.15;',
'    col=mix(cb,ce,hm.y);',
'  }',
'  col=mix(col,uFog.rgb,uFog.a);',
'  col=min(col,vec3(1.));',
'  gl_FragColor=vec4(col*al,al)*uAlpha;}'
  ].join('\n');

  /* ---------------- GL ---------------- */
  var gl, GC, PM, GW = 0, GH = 0, stopped = false;
  function mk(type, src) {
    var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function init() {
    GC = D.createElement('canvas'); GC.width = GC.height = 16;
    var at = { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: 'high-performance' };
    gl = GC.getContext('webgl2', at) || GC.getContext('webgl', at);
    if (!gl) return false;
    PM = gl.createProgram();
    gl.attachShader(PM, mk(gl.VERTEX_SHADER, VS)); gl.attachShader(PM, mk(gl.FRAGMENT_SHADER, FS_M));
    gl.bindAttribLocation(PM, 0, 'a'); gl.linkProgram(PM);
    if (!gl.getProgramParameter(PM, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(PM));
    PM.u = {}; 'uVp uOrigin uPpu uAlpha uSteps uAO uRot uCol uA uB uFog'.split(' ').forEach(function (n) { PM.u[n] = gl.getUniformLocation(PM, n); });
    var b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); gl.enable(gl.SCISSOR_TEST);
    GC.addEventListener('webglcontextlost', function (e) {
      e.preventDefault(); API.supported = false; stopped = true;
      targets.forEach(function (t) { t.cv.parentNode && t.cv.parentNode.classList.remove('m3d-on'); });
    });
    return true;
  }
  function hex(s, d) {
    s = (s || d).replace('#', ''); if (s.length === 3) s = s.replace(/./g, '$&$&');
    var n = parseInt(s, 16); if (isNaN(n)) n = parseInt(d.replace('#', ''), 16);
    return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
  }
  function mmul(a, b) {
    var r = [];
    for (var i = 0; i < 3; i++) for (var j = 0; j < 3; j++) r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    return r;
  }
  /* yaw+ = 얼굴이 보는 사람 오른쪽으로, pitch+ = 위를 봄, roll+ = 시계 방향 (도) */
  function rot(yaw, pitch, roll) {
    var y = yaw * PI / 180, p = -pitch * PI / 180, r = -roll * PI / 180;
    var Ry = [Math.cos(y), 0, Math.sin(y), 0, 1, 0, -Math.sin(y), 0, Math.cos(y)];
    var Rx = [1, 0, 0, 0, Math.cos(p), -Math.sin(p), 0, Math.sin(p), Math.cos(p)];
    var Rz = [Math.cos(r), -Math.sin(r), 0, Math.sin(r), Math.cos(r), 0, 0, 0, 1];
    var m = mmul(Rz, mmul(Rx, Ry));
    return new Float32Array([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);
  }

  /* 한 마리를 그린다. open: 눈 뜬 정도(1 뜸, .12 감김). 반환: GPU 시간 측정 시 ms */
  function drawOne(T, open, measure) {
    var w = T.w, h = T.h, o = T.o, unit = Math.min(w, h) / 3.6;
    if (w > GW || h > GH) { GW = GC.width = Math.max(GW, w); GH = GC.height = Math.max(GH, h); }
    var vy = GH - h;
    gl.viewport(0, vy, w, h); gl.scissor(0, vy, w, h); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    var u = PM.u, t0 = 0;
    if (measure) { gl.finish(); t0 = performance.now(); }
    gl.useProgram(PM);
    gl.uniform2f(u.uVp, 0, vy); gl.uniform2f(u.uOrigin, w / 2, h / 2 - .29 * unit);
    gl.uniform1f(u.uPpu, 1 / unit); gl.uniform1f(u.uAlpha, 1); gl.uniform1f(u.uSteps, T.steps); gl.uniform1f(u.uAO, 1);
    gl.uniformMatrix3fv(u.uRot, false, rot(o.yaw + T.ly, o.pitch + T.lp, o.roll));
    gl.uniform3fv(u.uCol, o.col);
    gl.uniform4fv(u.uA, [0, 0, o.expr === 'closed' ? .2 : open, o.expr === 'smile' ? 1 : 0]);
    gl.uniform4fv(u.uB, [T.lex, T.ley, 0, 0]); gl.uniform4fv(u.uFog, [0, 0, 0, 0]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    var ms = 0; if (measure) { gl.finish(); ms = performance.now() - t0; }
    T.ctx.clearRect(0, 0, w, h); T.ctx.drawImage(GC, 0, 0, w, h, 0, 0, w, h);
    API.stats.draws++;
    if (!T.on) { T.on = true; T.cv.parentNode && T.cv.parentNode.classList.add('m3d-on'); }
    return ms;
  }

  /* ---------------- 일정 관리 ---------------- */
  var targets = [], raf = 0, scrolling = false, scrollTimer = 0, mx = 0, my = 0, lastPtr = 0;
  var BLINK = [.55, .12, .55, 1]; /* 감기는 중, 감김, 뜨는 중, 뜸: 4프레임 */

  function parse(cv) {
    var d = cv.dataset, n = function (v, def) { v = parseFloat(v); return isNaN(v) ? def : v; };
    return { yaw: n(d.yaw, 0), pitch: n(d.pitch, 0), roll: n(d.roll, 0), col: hex(d.color, '#0AFFF7'), expr: d.expr || 'idle', look: d.look === 'pointer' };
  }
  function sizeOf(T) {
    if (T.cv.clientWidth < 1 || T.cv.clientHeight < 1) return false;
    var w = Math.max(1, Math.round(T.cv.clientWidth * T.ratio)), h = Math.max(1, Math.round(T.cv.clientHeight * T.ratio));
    if (T.cv.width !== w || T.cv.height !== h) { T.cv.width = w; T.cv.height = h; T.need = true; }
    T.w = w; T.h = h; return true;
  }
  function canRun() { return !stopped && !D.hidden && !scrolling; }
  function wake() { if (!raf && !stopped) raf = requestAnimationFrame(frame); }
  var wakeRM = wake;

  function frame(ts) {
    raf = 0; API.stats.raf++;
    if (stopped || D.hidden || scrolling) return; /* 스크롤 중: 쉼. 끝나면 onScroll 타이머가 wake() */
    var again = false, first = false, look = null;
    targets.forEach(function (T) {
      if (!T.vis) return;
      if (T.need) { /* 첫 그리기와 크기 변경: 한 프레임에 한 마리 */
        if (first) { again = true; return; }
        first = true; T.need = false;
        if (!sizeOf(T)) return;
        var measured = !T.measured, ms = drawOne(T, T.open, measured);
        if (measured) {
          T.measured = true; API.stats.ms[T.w + 'x' + T.h] = +ms.toFixed(2);
          if (ms > 8) { /* 8ms 넘으면 단계 수를 줄이고, 그래도 넘으면 그 캔버스만 1.5배 */
            if (T.steps > 40) { T.steps = 40; T.measured = false; T.need = true; }
            else if (T.ratio > 1.5) { T.ratio = 1.5; T.measured = false; T.need = true; }
          }
        }
        if (T.need) again = true;
        return;
      }
      if (T.bPend) { /* 깜빡임 프레임: 다음 프레임은 타이머로 55ms 뒤에 예약(그 사이 rAF 없음) */
        T.bPend = false; T.open = BLINK[T.blinkIdx]; drawOne(T, T.open);
        if (++T.blinkIdx < BLINK.length) T.bt2 = setTimeout(function () { T.bPend = true; wake(); }, 55);
        else { T.blinkIdx = -1; T.open = 1; }
      }
      if (T.lookOn && ts >= T.lookAt && (!look || T.lookAt < look.lookAt)) look = T;
      if (T.lookOn) again = true;
    });
    if (look) { /* 마우스 따라 보기: 프레임당 한 마리, 마리당 20fps 이하 */
      var T = look; T.lookAt = ts + 50;
      var k = .4, dy = T.ty - T.ly, dp = T.tp - T.lp;
      if (Math.abs(dy) < .25 && Math.abs(dp) < .12) { T.ly = T.ty; T.lp = T.tp; T.lex = T.tex; T.ley = T.tey; T.lookOn = false; }
      else { T.ly += dy * k; T.lp += dp * k; T.lex += (T.tex - T.lex) * k; T.ley += (T.tey - T.ley) * k; }
      drawOne(T, T.open);
    }
    if (again) wake();
  }

  function scheduleBlink(T) { /* 3~5초 간격, 마스코트마다 어긋나게 */
    clearTimeout(T.bt);
    T.bt = setTimeout(function () {
      if (T.vis && canRun() && T.blinkIdx < 0 && !T.need && T.o.expr === 'idle') { T.blinkIdx = 0; T.bPend = true; wake(); }
      scheduleBlink(T);
    }, 3000 + Math.random() * 2000);
  }

  function onPointer(e) {
    var now = performance.now(); if (now - lastPtr < 50) return; lastPtr = now;
    mx = (e.clientX / W.innerWidth - .5) * 2; my = (e.clientY / W.innerHeight - .5) * 2;
    if (scrolling) return;
    aimAll();
  }
  function aimAll() {
    var any = false;
    targets.forEach(function (T) {
      if (!T.o.look || !T.vis) return;
      var ty = mx * 10, tp = -my * 5;
      if (Math.max(Math.abs(ty - T.ly), Math.abs(tp - T.lp) * 2) > 1 || T.lookOn) {
        T.ty = ty; T.tp = tp; T.tex = mx; T.tey = -my; T.lookOn = true; any = true;
      }
    });
    if (any) wake();
  }
  function onScroll() {
    scrolling = true; clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () { scrolling = false; aimAll(); wake(); }, 150);
  }

  function attach(cv) {
    var ctx = cv.getContext('2d'); if (!ctx) return;
    var T = { cv: cv, ctx: ctx, o: parse(cv), vis: false, on: false, need: true, w: 0, h: 0, ratio: DPRMAX, steps: 64, measured: false, open: 1,
      blinkIdx: -1, bPend: false, lookOn: false, lookAt: 0, ly: 0, lp: 0, lex: 0, ley: 0, ty: 0, tp: 0, tex: 0, tey: 0, bt: 0 };
    targets.push(T);
    if (W.ResizeObserver) new ResizeObserver(function () { if (sizeOf(T) && T.vis) { T.need = true; RM ? wakeRM() : wake(); } }).observe(cv);
    var io = function (vis) { T.vis = vis; if (vis) { T.need = T.need || !T.on; wake(); if (!RM) aimAll(); } };
    if (W.IntersectionObserver) new IntersectionObserver(function (es) { io(es[es.length - 1].isIntersecting); }, { rootMargin: '200px' }).observe(cv);
    else io(true);
    if (!RM) scheduleBlink(T);
  }

  function start() {
    try { if (!init()) return; } catch (e) { API.error = String(e && e.message || e); return; }
    API.supported = true;
    function scan() {
      var cs = D.querySelectorAll('canvas[data-m3d="solo"]');
      for (var i = 0; i < cs.length; i++) if (!targets.some(function (T) { return T.cv === cs[i]; })) { try { attach(cs[i]); } catch (e) { API.error = String(e); } }
    }
    scan();
    if (!RM) {
      W.addEventListener('pointermove', onPointer, { passive: true });
      W.addEventListener('scroll', onScroll, { passive: true, capture: true });
      D.addEventListener('visibilitychange', function () { if (!D.hidden) wake(); });
    }
    API.refresh = function () { scan(); targets.forEach(function (T) { T.o = parse(T.cv); T.need = true; }); RM ? wakeRM() : wake(); };
  }
  if (D.readyState === 'loading') D.addEventListener('DOMContentLoaded', start); else start();
})();
