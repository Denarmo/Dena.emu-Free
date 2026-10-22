// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/web-file-manager.md
// The browser side of the web file manager: one self-contained page in the
// brutalist look (docs/specs/brutalist-ui.md 4.9): grid paper, monospace,
// 3 px ink borders, hard shadows, yellow focus. Plain CSS, no dependencies.

const webPageHtml = r'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Dena.emu Files</title>
<style>
:root{--ground:#f2f2ec;--grid:rgba(0,0,0,.07);--panel:#fff;--ink:#000;--mtext:#5a5a55;--focus:#ffe600;--blue:#1f3bff;--on-blue:#fff;--danger:#e10600;--mono:"IBM Plex Mono",ui-monospace,"SFMono-Regular",Menlo,Consolas,"Liberation Mono",monospace}
@media (prefers-color-scheme:dark){:root{--ground:#0e0e0e;--grid:rgba(255,255,255,.07);--panel:#000;--ink:#f2f2ec;--mtext:#a4a49c;--blue:#4a63ff;--danger:#ff3b30}}
*{box-sizing:border-box;border-radius:0}
body{margin:0;color:var(--ink);font:14px/1.45 var(--mono);background-color:var(--ground);background-image:linear-gradient(var(--grid) 1px,transparent 1px),linear-gradient(90deg,var(--grid) 1px,transparent 1px);background-size:8px 8px}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:var(--ink);color:var(--ground)}
.logo{width:30px;height:30px;background:var(--focus);color:#000;display:grid;place-items:center;font-weight:800;font-size:18px;border:3px solid var(--ground)}
h1{font-size:16px;margin:0;font-weight:800;text-transform:uppercase;letter-spacing:.06em}h1 span{color:var(--focus)}
h2{font-size:16px;text-transform:uppercase;letter-spacing:.06em}
.sub{opacity:.8;font-size:12px;margin-left:auto}
.wrap{display:flex;min-height:calc(100vh - 50px)}
nav{width:200px;padding:12px;flex-shrink:0}
nav button{display:block;width:100%;text-align:left;background:var(--panel);border:3px solid var(--ink);border-top-width:0;color:var(--ink);padding:8px 12px;font:inherit;font-weight:700;text-transform:uppercase;cursor:pointer}
nav button:first-child{border-top-width:3px}
nav button:hover,nav button:focus-visible{background:var(--focus);color:#000;outline:0}
nav button.on{background:var(--blue);color:var(--on-blue)}
nav button.on::before{content:"-> "}
main{flex:1;padding:12px 16px;min-width:0}
.bar{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:12px}
.crumbs{flex:1;min-width:0;font-weight:700;background:var(--panel);border:3px solid var(--ink);padding:6px 10px}
.crumbs::before{content:"/";color:var(--mtext)}
.crumbs a{color:var(--blue);text-decoration:underline;cursor:pointer}
.btn{background:var(--panel);color:var(--ink);border:3px solid var(--ink);box-shadow:4px 4px 0 var(--ink);padding:6px 14px;font:inherit;font-weight:700;text-transform:uppercase;cursor:pointer}
.btn.gold{background:var(--blue);color:var(--on-blue)}
.btn:hover,.btn:focus-visible{background:var(--focus);color:#000;outline:0}
.btn:active{transform:translate(4px,4px);box-shadow:none}
#drop{border:3px dashed var(--ink);background:var(--panel);padding:16px;text-align:center;margin-bottom:12px;text-transform:uppercase;font-weight:700}
#drop::before{content:"[ ";color:var(--mtext)}#drop::after{content:" ]";color:var(--mtext)}
#drop.over{background:var(--focus);color:#000;border-style:solid}
table{width:100%;border-collapse:collapse;background:var(--panel);border:3px solid var(--ink);box-shadow:6px 6px 0 var(--ink)}
td,th{padding:6px 10px;text-align:left;border-bottom:2px solid var(--ink)}
th{background:var(--ink);color:var(--ground);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
tr:last-child td{border-bottom:0}
tr.row:hover{background:var(--focus);color:#000}
tr.row:hover .detail,tr.row:hover .num,tr.row:hover .acts button{color:#000}
.name{cursor:pointer;word-break:break-all}.name b{font-weight:700}
.detail{color:var(--mtext);font-size:12px}
.ic{color:var(--blue);margin-right:8px;font-weight:700}
.num{color:var(--mtext);white-space:nowrap;font-variant-numeric:tabular-nums}
.acts{white-space:nowrap;text-align:right}
.acts button{background:none;border:2px solid transparent;color:var(--ink);cursor:pointer;font:inherit;font-size:12px;font-weight:700;text-transform:uppercase;padding:2px 6px}
.acts button::before{content:"["}.acts button::after{content:"]"}
.acts button:hover,.acts button:focus-visible{border-color:#000;background:var(--panel);color:var(--ink);outline:0}
.acts button.del:hover{background:var(--danger);color:#fff}
.empty{padding:28px;text-align:center;color:var(--mtext);text-transform:uppercase}
#jobs{position:fixed;right:16px;bottom:16px;width:320px;display:flex;flex-direction:column;gap:10px}
.job{background:var(--panel);border:3px solid var(--ink);box-shadow:4px 4px 0 var(--ink);padding:8px 10px;font-size:12px}
.job::before{content:"> ";color:var(--mtext)}
.job>div:first-child{display:inline}
.job .pb{height:12px;border:2px solid var(--ink);margin-top:6px}
.job .pb i{display:block;height:100%;background:var(--blue);width:0}
.job.bad{border-color:var(--danger);box-shadow:4px 4px 0 var(--danger)}
#login{max-width:360px;margin:12vh auto;background:var(--panel);padding:24px;border:3px solid var(--ink);box-shadow:8px 8px 0 var(--ink);text-align:center}
#login input{width:100%;font:800 30px var(--mono);letter-spacing:.4em;text-align:center;background:var(--ground);color:var(--ink);border:3px solid var(--ink);padding:8px;margin:16px 0}
#login input:focus{outline:0;background:var(--focus);color:#000}
.err{color:var(--danger);min-height:20px;font-weight:700}
@media (max-width:700px){.wrap{flex-direction:column}nav{width:auto;display:flex;overflow-x:auto}nav button,nav button:first-child{width:auto;white-space:nowrap;border-width:3px 3px 3px 0}nav button:first-child{border-left-width:3px}.hide-sm{display:none}#jobs{left:16px;width:auto}}
</style></head><body>
<header><div class="logo">D</div><h1>Dena<span>.emu</span> Files</h1><div class="sub" id="sub"></div></header>
<div id="login" hidden><h2 style="margin:0">Enter access code</h2><p class="detail">Shown in Dena.emu under Settings &gt; Web file manager.</p>
<form id="lf"><input id="code" inputmode="numeric" maxlength="4" autocomplete="off" autofocus><div class="err" id="lerr"></div><button class="btn gold" style="width:100%">Connect</button></form></div>
<div class="wrap" id="app" hidden><nav id="roots"></nav><main>
<div class="bar"><div class="crumbs" id="crumbs"></div>
<button class="btn" id="mk">New folder</button><button class="btn gold" id="up">Upload</button><input type="file" id="pick" multiple hidden></div>
<div id="drop">Drop files here to upload</div>
<table><thead><tr><th>Name</th><th class="hide-sm">Size</th><th class="hide-sm">Modified</th><th></th></tr></thead><tbody id="list"></tbody></table>
</main></div><div id="jobs"></div>
<script>
const $=s=>document.querySelector(s);
let root='games',path='';
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const size=n=>n==null?'':n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KB':n<1073741824?(n/1048576).toFixed(1)+' MB':(n/1073741824).toFixed(2)+' GB';
const q=(o)=>new URLSearchParams(Object.assign({root,path},o)).toString();
async function api(url,opt){const r=await fetch(url,opt);if(r.status==401){showLogin();throw new Error('login')}
 const j=r.headers.get('content-type')?.includes('json')?await r.json():{};if(!r.ok||j.ok===false)throw new Error(j.message||r.statusText);return j}
function showLogin(){$('#app').hidden=true;$('#login').hidden=false;$('#code').focus()}
$('#lf').onsubmit=async e=>{e.preventDefault();$('#lerr').textContent='';
 const r=await fetch('/api/login',{method:'POST',body:JSON.stringify({code:$('#code').value})});
 if(r.ok){$('#login').hidden=true;start()}else $('#lerr').textContent='Wrong code'};
async function start(){try{const j=await api('/api/roots');$('#roots').innerHTML=j.roots.map(r=>`<button data-r="${r.id}">${esc(r.label)}</button>`).join('');
 $('#roots').onclick=e=>{const b=e.target.closest('button');if(b){root=b.dataset.r;path='';load()}};$('#app').hidden=false;load()}catch(e){}}
async function load(){document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('on',b.dataset.r==root));
 const games=root=='games';$('#mk').hidden=games;
 $('#drop').textContent=games?'Drop game files here to add them to your library':'Drop files here to upload to this folder';
 const parts=path?path.split('/'):[];let acc='';
 $('#crumbs').innerHTML=`<a data-p="">${esc($('nav .on')?.textContent||root)}</a>`+parts.map(p=>{acc+=(acc?'/':'')+p;return ` &gt; <a data-p="${esc(acc)}">${esc(p)}</a>`}).join('');
 let j;try{j=await api('/api/list?'+q())}catch(e){if(e.message!='login')$('#list').innerHTML=`<tr><td colspan=4 class=empty>${esc(e.message)}</td></tr>`;return}
 $('#list').innerHTML=j.entries.length?j.entries.map(e=>{const full=(path?path+'/':'')+e.name;const leaf=games&&!e.dir;
  const title=e.label&&!e.dir?`<b>${esc(e.label)}</b><div class=detail>${esc(leaf?e.detail:e.name)}</div>`:`<b>${esc(e.dir&&games?e.name.toUpperCase():e.name)}</b>${e.label&&e.dir?`<div class=detail>${esc(e.label)}</div>`:''}`;
  return `<tr class=row data-p="${esc(full)}" data-d="${e.dir?1:0}" data-n="${esc(e.label&&leaf?e.label:e.name)}"><td class=name><span class=ic>${e.dir?'▸':'●'}</span>${title}</td>
  <td class="num hide-sm">${e.dir?'':size(e.size)}</td><td class="num hide-sm">${e.modified?new Date(e.modified).toLocaleString():''}</td>
  <td class=acts>${e.dir?'':'<button data-a=dl>Download</button>'}${games&&e.dir?'':'<button data-a=rn>Rename</button><button class=del data-a=rm>Delete</button>'}</td></tr>`}).join('')
  :`<tr><td colspan=4 class=empty>${games?'No games yet. Drop ROMs above to add them.':'This folder is empty'}</td></tr>`}
$('#crumbs').onclick=e=>{const a=e.target.closest('a');if(a){path=a.dataset.p;load()}};
$('#list').onclick=async e=>{const tr=e.target.closest('tr.row');if(!tr)return;const p=tr.dataset.p,a=e.target.dataset.a;
 try{if(a=='dl'){location.href='/api/file?'+q({path:p})}
 else if(a=='rn'){const n=prompt(root=='games'?'New title':'New name',tr.dataset.n);if(n&&n!=tr.dataset.n){await api('/api/rename?'+q({path:p,name:n}),{method:'POST'});load()}}
 else if(a=='rm'){if(confirm(root=='games'?`Delete "${tr.dataset.n}" with its saves and states?`:`Delete "${tr.dataset.n}"?`)){await api('/api/delete?'+q({path:p}),{method:'POST'});load()}}
 else if(tr.dataset.d=='1'&&e.target.closest('.name')){path=p;load()}}catch(err){if(err.message!='login')alert(err.message)}};
$('#mk').onclick=async()=>{const n=prompt('Folder name');if(n){try{await api('/api/mkdir?'+q({name:n}),{method:'POST'});load()}catch(e){alert(e.message)}}};
$('#up').onclick=()=>$('#pick').click();
$('#pick').onchange=()=>{upload([...$('#pick').files]);$('#pick').value=''};
const drop=$('#drop');
['dragenter','dragover'].forEach(t=>document.addEventListener(t,e=>{e.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(t=>document.addEventListener(t,e=>{e.preventDefault();if(t=='drop'||!e.relatedTarget)drop.classList.remove('over')}));
document.addEventListener('drop',e=>upload([...e.dataTransfer.files]));
let queue=Promise.resolve();
function upload(files){const r=root,p=path;for(const f of files){const el=document.createElement('div');el.className='job';
 el.innerHTML=`<div>${esc(f.name)}</div><div class=detail>Waiting</div><div class=pb><i></i></div>`;$('#jobs').append(el);
 queue=queue.then(()=>new Promise(done=>{const x=new XMLHttpRequest();x.open('PUT','/api/upload?'+new URLSearchParams({root:r,path:p,name:f.name}));
  x.upload.onprogress=e=>{el.querySelector('i').style.width=(e.loaded/e.total*100)+'%';el.querySelector('.detail').textContent=size(e.loaded)+' of '+size(e.total)};
  x.onload=()=>{let j={};try{j=JSON.parse(x.responseText)}catch(e){}el.querySelector('.detail').textContent=j.message||(x.status<300?'Done':'Failed');
   if(x.status>=300||j.ok===false)el.classList.add('bad');else setTimeout(()=>el.remove(),4000);if(root==r&&path==p)load();done()};
  x.onerror=()=>{el.classList.add('bad');el.querySelector('.detail').textContent='Connection lost';done()};x.send(f)}))}}
fetch('/api/roots').then(r=>r.ok?start():showLogin());
</script></body></html>''';
