import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const base='http://127.0.0.1:4173';
async function call(route,body,cookie){const r=await fetch(base+route,{method:body?'POST':'GET',headers:{...(body?{'Content-Type':'application/json'}:{}),...(cookie?{Cookie:cookie}:{})},body:body?JSON.stringify(body):undefined});return {status:r.status,data:await r.json(),cookie:r.headers.get('set-cookie')?.split(';')[0]};}
const results=[],cases=[];
function ok(name,evidence={}){results.push(name);cases.push({name,passed:true,...evidence});console.log('PASS '+name);}
assert.equal((await call('/api/book',{doctorId:1,date:'2026-12-01',time:'09:00'})).status,401);ok('booking requires login');
assert.equal((await call('/api/login',{username:'patient1',password:'wrong'})).status,401);ok('wrong password rejected');
const p1=(await call('/api/login',{username:'patient1',password:'Demo2026!'})).cookie;
const p2=(await call('/api/login',{username:'patient2',password:'Demo2026!'})).cookie;
const staff=(await call('/api/login',{username:'staff1',password:'Demo2026!'})).cookie;
assert.equal((await call('/api/database',null,p1)).status,403);ok('patient cannot inspect database');
assert.equal((await call('/api/schema',null,p1)).status,403);ok('patient cannot inspect schema');
const schema=(await call('/api/schema',null,staff)).data;
const ddl=await fs.readFile(new URL('sql/clinic_17_entities.sql',import.meta.url),'utf8');
assert.equal(schema.ddlHash,createHash('sha256').update(ddl).digest('hex'));ok('server loads latest canonical DDL',{ddlHash:schema.ddlHash});
const constraint=name=>schema.constraints.find(c=>c.conname===name);
assert.match(constraint('ck_queue_received_day').definition,/queue_date.*time_received.*Asia\/Bangkok/s);ok('ck_queue_received_day exists');
assert.match(constraint('fk_queue_appointment_patient').definition,/FOREIGN KEY \(appointment_id, patient_id\).*appointment\(appointment_id, patient_id\)/s);ok('fk_queue_appointment_patient uses composite key');
assert(!schema.paymentColumns.includes('change_amount'));ok('payment.change_amount is absent');
const state=(await call('/api/state',null,p1)).data;
assert(state.occupied.some(a=>Number(a.doctor_id)===1&&a.time==='10:00:00'));
assert(!state.occupied.some(a=>Number(a.doctor_id)===1&&a.time==='09:00:00'));
const second=(await call('/api/state',null,p2)).data;
assert(second.appointments.some(a=>a.date===state.defaultDate&&a.time==='10:00:00'&&a.doctor_name==='หมอ A'));ok('demo starts with patient2 at 10:00 and 09:00 free',{demoDate:state.defaultDate});
async function tables(){return (await call('/api/database',null,staff)).data.tables;}
const counts=t=>({appointment:t.appointment.length,activity_log:t.activity_log.length});
async function rejectUnchanged(name,body,cookie,pattern){const before=await tables();const r=await call('/api/book',body,cookie);assert.equal(r.status,409);assert.match(r.data.error,pattern);assert.equal(r.data.rolledBack,true);const after=await tables();assert.deepEqual(after.appointment,before.appointment);assert.deepEqual(after.activity_log,before.activity_log);ok(name,{status:r.status,message:r.data.error,constraint:r.data.constraint,before:counts(before),after:counts(after)});}
await rejectUnchanged('patient1 cannot book seeded 10:00; both tables unchanged',{doctorId:1,date:state.defaultDate,time:'10:00'},p1,/ถูกจองแล้ว/);
assert.equal(cases.at(-1).constraint,'uq_doctor_active_slot');
const baseline=await tables();let offset=100,date;
do{date=new Date(Date.parse(state.defaultDate+'T00:00:00Z')+offset++*86400000).toISOString().slice(0,10);}while(baseline.appointment.some(a=>String(a.appoint_date).slice(0,10)===date));
const reserved=await call('/api/book',{doctorId:1,date,time:'10:00'},p2);assert.equal(reserved.status,201);ok('patient2 reserves 10:00 on isolated test date');
const before=await tables();const booked=await call('/api/book',{doctorId:1,date,time:'09:00'},p1);assert.equal(booked.status,201);const after=await tables();assert.equal(after.appointment.length,before.appointment.length+1);assert.equal(after.activity_log.length,before.activity_log.length+1);assert(after.activity_log.some(l=>l.action===`appointment_created:${booked.data.appointment.appointment_id}`));ok('booking commits appointment and activity_log',{appointmentId:booked.data.appointment.appointment_id,before:counts(before),after:counts(after)});
await rejectUnchanged('patient1 booking occupied 10:00 is rejected even after 09:00 booking',{doctorId:1,date,time:'10:00'},p1,/ถูกจองแล้ว/);
await rejectUnchanged('same doctor 09:00 slot rejected for patient2',{doctorId:1,date,time:'09:00'},p2,/ถูกจองแล้ว/);
await rejectUnchanged('one online appointment per patient per day',{doctorId:1,date,time:'09:30'},p1,/หนึ่งนัด/);
const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Bangkok',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
await rejectUnchanged('24-hour advance booking rule',{doctorId:1,date:today,time:'09:00'},p2,/24 ชั่วโมง/);
const summary=(await call('/api/state?date='+date,null,p1)).data;assert(summary.appointments.some(a=>a.appointment_id===booked.data.appointment.appointment_id&&a.time==='09:00:00'));assert.equal(summary.schedule.filter(a=>Number(a.doctor_id)===1).length,2);ok('final result and doctor daily schedule include new appointment');
await call('/api/logout',{},p1);assert.equal((await call('/api/state',null,p1)).status,401);ok('logout invalidates session');
await fs.writeFile(new URL('evidence/verification.json',import.meta.url),JSON.stringify({testedAt:new Date().toISOString(),passed:results.length,failed:0,demoDate:state.defaultDate,testDate:date,schema,results,cases},null,2));
