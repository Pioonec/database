// Drives the real UI in headless Edge (Chrome DevTools Protocol) on a freshly created demo database,
// saves the Demo screenshots and records what the server answered to each UI click.
// Usage: start the server on a NEW data folder, then run: node capture_demo.mjs
import {spawn} from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const base='http://127.0.0.1:4173/',port=9333;
const out=new URL('evidence/screenshots/',import.meta.url);
const browserPath=['C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Google/Chrome/Application/chrome.exe'];
const exe=(await Promise.all(browserPath.map(p=>fs.access(p).then(()=>p,()=>null)))).find(Boolean);
const profile=await fs.mkdtemp(path.join(os.tmpdir(),'clinic-cdp-'));
const browser=spawn(exe,['--headless=new',`--remote-debugging-port=${port}`,`--user-data-dir=${profile}`,'--no-first-run','--hide-scrollbars','about:blank'],{stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let target;
for(let i=0;i<50&&!target;i++){try{target=(await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t=>t.type==='page');}catch{}if(!target)await sleep(200);}
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
let seq=0;const pending=new Map();
ws.onmessage=m=>{const d=JSON.parse(m.data);if(d.id&&pending.has(d.id)){pending.get(d.id)(d);pending.delete(d.id);}};
const send=(method,params={})=>new Promise((res,rej)=>{const id=++seq;pending.set(id,d=>d.error?rej(Error(method+': '+d.error.message)):res(d.result));ws.send(JSON.stringify({id,method,params}));});
const run=async expr=>{const r=await send('Runtime.evaluate',{expression:expr,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description||expr);return r.result.value;};
const waitFor=async(expr,label)=>{for(let i=0;i<100;i++){if(await run(`(()=>{try{return !!(${expr})}catch{return false}})()`))return;await sleep(100);}throw Error('timeout: '+label);};
const width=1264;
async function shot(name){
 await sleep(300);
 const h=await run('Math.ceil(document.documentElement.scrollHeight)');
 await send('Emulation.setDeviceMetricsOverride',{width,height:h,deviceScaleFactor:1,mobile:false});
 const {data}=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});
 await fs.writeFile(new URL(name+'.png',out),Buffer.from(data,'base64'));console.log('saved',name);
}
// Record every /api/book answer the page receives, so the evidence comes from the real click.
const hook=`if(!window.__hooked){window.__hooked=true;window.__book=[];const f=window.fetch;window.fetch=async(u,o)=>{const r=await f(u,o);if(String(u).includes('/api/book')){const c=r.clone();window.__book.push({status:r.status,body:await c.json()});}return r;};}`;
async function open(){await send('Page.navigate',{url:base});await waitFor("document.readyState==='complete'&&document.getElementById('loginForm')",'page load');await run(hook);}
async function login(user){
 await send('Network.clearBrowserCookies');await open();await waitFor("!document.getElementById('login').hidden",'login form');
 await run(`document.getElementById('username').value='${user}';document.getElementById('password').value='Demo2026!';document.getElementById('loginForm').requestSubmit();`);
 await waitFor("!document.getElementById('app').hidden",'logged in');
}
async function patientReady(){await waitFor("document.querySelector('#slots [data-time=\"09:00\"]')",'slots');}
async function inspect(){await run("document.getElementById('inspect').click()");await waitFor("document.querySelectorAll('#database h3').length>=2",'database');}
const slot=t=>run(`(()=>{const b=document.querySelector('#slots [data-time="${t}"]');return {time:'${t}',busy:b.dataset.busy==='true',label:b.querySelector('small').textContent};})()`);
const counts=()=>run(`[...document.querySelectorAll('#database h3')].map(h=>h.textContent)`);
const message=()=>run("document.getElementById('message').textContent");
const evidence={startedAt:new Date().toISOString()};
await send('Page.enable');await send('Runtime.enable');await send('Network.enable');
await send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false});
try{
 // 0. staff counts before
 await login('staff1');await inspect();evidence.databaseBefore=await counts();
 // 1. before
 await login('patient1');await patientReady();
 evidence.before={slot0900:await slot('09:00'),slot1000:await slot('10:00')};
 if(evidence.before.slot0900.busy||!evidence.before.slot1000.busy)throw Error('Demo database is not fresh: 09:00 must be free and 10:00 booked');
 await shot('01_before');
 // 2. book 09:00 through the UI
 await run(`document.querySelector('#slots [data-time="09:00"]').click()`);await run("document.getElementById('book').click()");
 await waitFor("window.__book.length===1&&!document.getElementById('receipt').hidden",'booking result');
 evidence.booking={response:(await run('window.__book'))[0],message:await message()};
 await shot('02_booking_success');
 // 3. database after booking
 await login('staff1');await inspect();evidence.databaseAfterBooking=await counts();await shot('03_database_after');
 // 4. click the occupied 10:00 and confirm: the request reaches the server and PostgreSQL rejects it
 await login('patient1');await patientReady();
 await run(`document.querySelector('#slots [data-time="10:00"]').click()`);
 evidence.rejectedSelection=await run("document.getElementById('selection').textContent");
 await run("document.getElementById('book').click()");
 await waitFor("window.__book.length===1&&document.getElementById('message').className==='error'",'rejection');
 evidence.rejection={response:(await run('window.__book'))[0],message:await message()};
 await shot('04_booking_rejected');
 // 4b. database unchanged after rejection
 await login('staff1');await inspect();evidence.databaseAfterRejection=await counts();await shot('04b_database_after_rejected');
 // 5. final result for patient1
 await login('patient1');await patientReady();
 evidence.final={appointments:await run("document.getElementById('appointments').innerText"),schedule:await run("document.getElementById('schedule').innerText")};
 await shot('05_final_result');
 evidence.finishedAt=new Date().toISOString();
 await fs.writeFile(new URL('ui_click_evidence.json',out),JSON.stringify(evidence,null,2));
 console.log(JSON.stringify(evidence,null,2));
}finally{ws.close();browser.kill();await sleep(500);await fs.rm(profile,{recursive:true,force:true}).catch(()=>{});}
