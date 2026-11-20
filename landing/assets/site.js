// Shared by the Korean (/) and English (/en/) landing pages; text comes from the page's #copy JSON.
(function(){
  var d=document, $=function(s,r){return (r||d).querySelector(s)}, $$=function(s,r){return [].slice.call((r||d).querySelectorAll(s))};
  var copy=JSON.parse($('#copy').textContent);   // this page's language: example requests, scene captions, dot labels
  var reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
  d.documentElement.classList.add('js');

  // Empty links do nothing; in-page links scroll smoothly
  d.addEventListener('click',function(e){var a=e.target.closest('a[href="#"]');if(a)e.preventDefault()});
  d.addEventListener('click',function(e){
    var a=e.target.closest('a[href^="#"]:not([href="#"])');if(!a)return;
    var t=$(a.getAttribute('href'));if(!t)return;e.preventDefault();
    scrollTo({top:t.getBoundingClientRect().top+scrollY-(t.id==='top'?0:60),behavior:reduce?'auto':'smooth'});
  });

  // Top bar: a backdrop after 80px, a light one over the paper sections (only when the value changes)
  var bar=$('.topbar'), sc=false, op=false, p0=$('#intro'), p1=$('#end');
  function onScroll(){
    var y=scrollY, s=y>80, o=y>p0.offsetTop-40&&y<p1.offsetTop+20;
    if(s!==sc){sc=s;bar.classList.toggle('scrolled',s)}
    if(o!==op){op=o;bar.classList.toggle('onpaper',o)}
  }
  addEventListener('scroll',onScroll,{passive:true});onScroll();

  // Organizing effect: scattered record dots gather into the mascot and come out as task cards (only while visible)
  var flow=$('#flow'), FC=['#5B8FD0','#E7B645','#57A377','#8E5A93','#DD6A54'];
  $('#fdots').innerHTML=[[8,22,22,1],[14,34,26,1],[10,50,22,2],[20,28,16,3,0],[23,39,22,0],[21.5,41,14,4],[26,30,14,2],[30,44,18,0,1],[33,56,22,0],[25,58,12,2,2],[32,36,12,4,3],[36,64,22,0],[38,67,14,3],[29,70,12,4,4],[30,73.5,16,4],[8,76,24,4],[36,80,20,1],[38.5,84,18,0,5],[13,86,12,1],[21,84,14,0],[18,91,12,2],[4,94,10,0]].map(function(p,k){
    return '<i class="fd" style="--x:'+p[0]+';--y:'+p[1]+';--s:'+p[2]+'px;--c:'+FC[p[3]]+';--dl:'+(-k*.36).toFixed(2)+'s">'+(p[4]!=null?'<span>'+copy.dots[p[4]]+'</span>':'')+'</i>';
  }).join('');
  new IntersectionObserver(function(es){flow.classList.toggle('run',es[0].isIntersecting)},{threshold:.1}).observe(flow);

  // Example request marquee
  var rows=copy.asks;
  $('#qwall').innerHTML=rows.map(function(r,i){
    var set=r.map(function(p){return '<div class="qp"><i><svg viewBox="0 0 24 24"><use href="#i-'+p[0]+'"/></svg></i>'+p[1]+'</div>'}).join('');
    return '<div class="qrow '+(i==1?'r2':i==2?'r3':'')+'">'+set+set+set+set+'</div>';
  }).join('');

  // Intro: pick a scene from the orbit (next every 5s, only while visible)
  var caps=copy.caps;
  var pls=$$('.pl'), shots=$$('#screens img'), cap=$('#cap'), cur=0, tm, seen=false, warm=false;
  function arm(){clearTimeout(tm);if(!reduce)tm=setTimeout(function(){seen&&!d.hidden?show((cur+1)%pls.length):arm()},5000)}
  function show(i){
    cur=i;
    pls.forEach(function(p,j){p.classList.toggle('on',j===i);p.setAttribute('aria-selected',j===i)});
    shots.forEach(function(s,j){s.classList.toggle('on',j===i)});
    cap.style.opacity=0;setTimeout(function(){cap.innerHTML=caps[cur];cap.style.opacity=1},reduce?0:150);
    arm();
  }
  pls.forEach(function(p,i){p.addEventListener('click',function(){show(i)});p.addEventListener('mouseenter',function(){if(i!==cur)show(i)})});
  // Decode all six screens once visible so switching never stutters
  new IntersectionObserver(function(es){seen=es[0].isIntersecting;if(seen&&!warm){warm=true;shots.forEach(function(s){if(s.decode)s.decode().catch(function(){})})}},{threshold:.2}).observe($('#screens'));
  cap.innerHTML=caps[0];arm();

  // Graph tabs: play only the active video, only while visible
  var tabs=$$('#tabs .tab'), vids=$$('#gshow video'), gi=0, gin=false;
  function gplay(){vids.forEach(function(v,j){if(j===gi&&gin&&!reduce){var p=v.play();if(p&&p.catch)p.catch(function(){})}else v.pause()})}
  tabs.forEach(function(t,i){t.addEventListener('click',function(){
    gi=i;
    tabs.forEach(function(x,j){x.classList.toggle('on',j===i);x.setAttribute('aria-selected',j===i)});
    vids.forEach(function(x,j){x.classList.toggle('on',j===i)});
    try{vids[i].currentTime=0}catch(e){}
    gplay();
  })});
  new IntersectionObserver(function(es){gin=es[0].isIntersecting;gplay()},{threshold:.15}).observe($('#gshow'));

  // FAQ toggles
  $$('.q button').forEach(function(b){b.addEventListener('click',function(){
    var o=b.parentNode.classList.toggle('open');b.setAttribute('aria-expanded',o);
  })});

  // Reveal (90ms per sibling, up to 450ms)
  var groups=new Map();
  $$('.rv').forEach(function(el){
    var p=el.parentNode,n=groups.get(p)||0;groups.set(p,n+1);
    el.style.setProperty('--d',Math.min(n,5)*90+'ms');
  });
  if(reduce){$$('.rv').forEach(function(e){e.classList.add('rv-in')})}
  else{
    var io=new IntersectionObserver(function(es){es.forEach(function(e){
      if(!e.isIntersecting)return;io.unobserve(e.target);e.target.classList.add('rv-in');
      setTimeout(function(){e.target.classList.remove('rv');e.target.style.removeProperty('--d')},1300);
    })},{threshold:.12,rootMargin:'0px 0px -6% 0px'});
    $$('.rv').forEach(function(e){io.observe(e)});
  }
})();
