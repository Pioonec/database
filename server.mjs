import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {argon2Sync,randomBytes,timingSafeEqual,createHash} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
const root=path.dirname(fileURLToPath(import.meta.url));
const db=new PGlite(path.join(root,'data'));
await db.waitReady;
const ddl=await fs.readFile(path.join(root,'sql/clinic_17_entities.sql'),'utf8');
const ddlHash=createHash('sha256').update(ddl).digest('hex');
const sessions=new Map(),slots=Array.from({length:16},(_,i)=>`${String(9+Math.floor(i/2)).padStart(2,'0')}:${i%2?'30':'00'}`);
function hash(password,salt=randomBytes(16)){const digest=argon2Sync('argon2id',{message:password,nonce:salt,parallelism:1,tagLength:32,memory:19456,passes:2});return `$argon2id$v=19$m=19456,t=2,p=1$${salt.toString('base64')}$${digest.toString('base64')}`;}
function verify(password,stored){try{const salt=Buffer.from(stored.split('$')[4],'base64');const a=Buffer.from(hash(password,salt)),b=Buffer.from(stored);return a.length===b.length&&timingSafeEqual(a,b);}catch{return false;}}
if(!(await db.query("SELECT 1 FROM information_schema.schemata WHERE schema_name='clinic17'")).rows.length){
 await db.exec(ddl);
 await db.transaction(async tx=>{
  await tx.exec('SET LOCAL search_path=clinic17,public');
  for(const [name,role] of [['patient1','patient'],['patient2','patient'],['doctor1','doctor'],['staff1','receptionist']])await tx.query('INSERT INTO users(username,password_hash,role) VALUES($1,$2,$3)',[name,hash('Demo2026!'),role]);
  await tx.exec(`INSERT INTO patient(user_id,name,citizen_id,date_of_birth,phone,gender,identity_verified_at)
   SELECT user_id,CASE username WHEN 'patient1' THEN 'คนไข้สาธิต ก' ELSE 'คนไข้สาธิต ข' END,CASE username WHEN 'patient1' THEN '1000000000001' ELSE '1000000000002' END,'2000-01-01','0000000000','unknown',now() FROM users WHERE role='patient';
   INSERT INTO doctor(user_id,doctor_name,license_number,doctor_phone,specialty) SELECT user_id,'หมอ A','DEMO-001','0000000000','เวชปฏิบัติทั่วไป' FROM users WHERE role='doctor';
   INSERT INTO receptionist(user_id,staff_name,staff_phone) SELECT user_id,'พนักงานสาธิต','0000000000' FROM users WHERE role='receptionist';`);
  const seeded=(await tx.query(`INSERT INTO appointment(patient_id,doctor_id,appoint_date,appoint_time,booking_source)
   SELECT p.patient_id,d.doctor_id,(now() AT TIME ZONE 'Asia/Bangkok')::date+7,'10:00','online'
   FROM patient p JOIN users u USING(user_id) CROSS JOIN doctor d WHERE u.username='patient2'
   RETURNING appointment_id,patient_id`)).rows[0];
  await tx.query('INSERT INTO activity_log(user_id,action) SELECT user_id,$1 FROM patient WHERE patient_id=$2',
   [`appointment_created:${seeded.appointment_id}`,seeded.patient_id]);
 });
}
const q=(sql,args=[])=>db.query(sql,args);
async function schemaState(){
 const constraints=(await q(`SELECT conname,pg_get_constraintdef(c.oid) AS definition FROM pg_constraint c
 JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='clinic17'
 AND conname IN ('ck_queue_received_day','fk_queue_appointment_patient') ORDER BY conname`)).rows;
 const columns=(await q("SELECT column_name FROM information_schema.columns WHERE table_schema='clinic17' AND table_name='payment' ORDER BY ordinal_position")).rows.map(r=>r.column_name);
 return {ddlHash,constraints,paymentColumns:columns};
}
const schema=await schemaState();
if(schema.constraints.length!==2||schema.paymentColumns.includes('change_amount'))throw Error('Demo database is outdated: back up data and recreate from the latest DDL');
const demoDate=(await q(`SELECT a.appoint_date::text AS day FROM clinic17.appointment a
 JOIN clinic17.patient p USING(patient_id) JOIN clinic17.users u ON u.user_id=p.user_id
 WHERE u.username='patient2' AND a.appoint_time='10:00' ORDER BY a.appointment_id LIMIT 1`)).rows[0]?.day
 ||(await q("SELECT ((now() AT TIME ZONE 'Asia/Bangkok')::date+7)::text AS day")).rows[0].day;
const cookie=req=>req.headers.cookie?.split(';').map(s=>s.trim()).find(s=>s.startsWith('sid='))?.slice(4);
function reply(res,status,data,extra={}){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store',...extra});res.end(JSON.stringify(data));}
async function body(req){let s='';for await(const c of req){s+=c;if(s.length>12000)throw Error('ข้อมูลมากเกินไป');}return JSON.parse(s||'{}');}
const server=http.createServer(async(req,res)=>{
 try{
 const url=new URL(req.url,'http://127.0.0.1');
 if(req.method==='GET'&&url.pathname==='/'){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});return res.end(await fs.readFile(path.join(root,'index.html')));}
 if(req.method==='POST'&&req.headers.origin&&req.headers.origin!==`http://${req.headers.host}`)return reply(res,403,{error:'ไม่อนุญาตคำขอจากเว็บไซต์อื่น'});
 if(req.method==='POST'&&url.pathname==='/api/login'){
  const b=await body(req);const u=(await q('SELECT * FROM clinic17.users WHERE lower(username)=lower($1)',[b.username])).rows[0];
  if(!u||typeof b.password!=='string'||!verify(b.password,u.password_hash))return reply(res,401,{error:'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง'});
  if(!['patient','receptionist'].includes(u.role))return reply(res,403,{error:'บัญชีนี้ไม่รองรับหน้าสาธิต'});
  const sid=randomBytes(24).toString('hex');sessions.set(sid,{id:u.user_id,username:u.username,role:u.role,expires:Date.now()+4*3600000});
  return reply(res,200,{ok:true},{'Set-Cookie':`sid=${sid}; HttpOnly; SameSite=Strict; Path=/`});
 }
 const session=sessions.get(cookie(req));if(!session||session.expires<Date.now())return reply(res,401,{error:'กรุณาเข้าสู่ระบบ'});
 if(req.method==='POST'&&url.pathname==='/api/logout'){sessions.delete(cookie(req));return reply(res,200,{ok:true},{'Set-Cookie':'sid=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict'});}
 if(url.pathname==='/api/state'&&req.method==='GET'){
  const today=demoDate;
  const date=url.searchParams.get('date')||today;
  if(!/^\d{4}-\d{2}-\d{2}$/.test(date))return reply(res,400,{error:'วันที่ไม่ถูกต้อง'});
  const doctors=(await q('SELECT doctor_id,doctor_name,specialty FROM clinic17.doctor ORDER BY doctor_id')).rows;
  const occupied=(await q("SELECT doctor_id,appoint_time::text AS time FROM clinic17.appointment WHERE appoint_date=$1 AND status IN ('scheduled','checked_in')",[date])).rows;
  const mine=(await q(`SELECT a.appointment_id,p.name,d.doctor_name,a.appoint_date::text AS date,a.appoint_time::text AS time,a.status FROM clinic17.appointment a JOIN clinic17.patient p USING(patient_id) JOIN clinic17.doctor d USING(doctor_id) WHERE ($1='receptionist' OR p.user_id=$2) AND a.appoint_date=$3 ORDER BY a.appointment_id DESC`,[session.role,session.id,date])).rows;
  const schedule=(await q(`SELECT a.appointment_id,a.doctor_id,a.appoint_time::text AS time,a.status
   FROM clinic17.appointment a WHERE a.appoint_date=$1 AND a.status IN ('scheduled','checked_in','completed') ORDER BY a.appoint_time`,[date])).rows;
  return reply(res,200,{session,defaultDate:today,date,doctors,slots,occupied,appointments:mine,schedule});
 }
 if(req.method==='POST'&&url.pathname==='/api/book'){
  if(session.role!=='patient')return reply(res,403,{error:'กรุณาใช้บัญชีคนไข้เพื่อจองออนไลน์'});
  const b=await body(req);
  if(!Number.isSafeInteger(b.doctorId)||!/^\d{4}-\d{2}-\d{2}$/.test(b.date)||!slots.includes(b.time))return reply(res,400,{error:'เลือกแพทย์ วันที่ และเวลาจากช่องที่เปิดรับ'});
  const p=(await q('SELECT patient_id FROM clinic17.patient WHERE user_id=$1',[session.id])).rows[0];
  if(!p)return reply(res,403,{error:'บัญชีนี้ไม่มีข้อมูลคนไข้'});
  try{
   const result=await db.transaction(async tx=>{
    await tx.exec('SET LOCAL search_path=clinic17,public');
    const a=(await tx.query("INSERT INTO appointment(patient_id,doctor_id,appoint_date,appoint_time,booking_source) VALUES($1,$2,$3,$4,'online') RETURNING appointment_id,appoint_date::text AS date,appoint_time::text AS time,status",[p.patient_id,b.doctorId,b.date,b.time])).rows[0];
    await tx.query("INSERT INTO activity_log(user_id,action) VALUES($1,$2)",[session.id,`appointment_created:${a.appointment_id}`]);
    return a;
   });return reply(res,201,{appointment:result});
  }catch(e){let error='บันทึกนัดหมายไม่สำเร็จ';if(e.constraint==='uq_doctor_active_slot')error='เวลานี้ถูกจองแล้ว กรุณาเลือกเวลาอื่น';else if(e.constraint==='uq_patient_online_day')error='คุณมีนัดออนไลน์ในวันที่เลือกแล้ว จองได้ไม่เกินหนึ่งนัดต่อวัน';else if(e.code==='P0001')error='ต้องจองล่วงหน้าอย่างน้อย 24 ชั่วโมง';else if(e.code==='23503')error='ไม่พบแพทย์ที่เลือก';return reply(res,409,{error,rolledBack:true,constraint:e.constraint||(e.code==='P0001'?'trg_appointment_rules':e.code)});}
 }
 if(req.method==='GET'&&url.pathname==='/api/database'){
  if(session.role!=='receptionist')return reply(res,403,{error:'เฉพาะพนักงานสาธิตที่ตรวจข้อมูลฐานข้อมูลได้'});
  const tables={};for(const name of ['appointment','activity_log'])tables[name]=(await q(`SELECT * FROM clinic17.${name} ORDER BY 1`)).rows;
  tables.patient=(await q('SELECT patient_id,user_id,name FROM clinic17.patient ORDER BY 1')).rows;
  tables.doctor=(await q('SELECT doctor_id,user_id,doctor_name FROM clinic17.doctor ORDER BY 1')).rows;
  return reply(res,200,{tables});
 }
 if(req.method==='GET'&&url.pathname==='/api/schema'){
  if(session.role!=='receptionist')return reply(res,403,{error:'เฉพาะพนักงานสาธิตที่ตรวจโครงสร้างฐานข้อมูลได้'});
  return reply(res,200,await schemaState());
 }
 return reply(res,404,{error:'ไม่พบหน้า'});
 }catch(e){console.error(e.message);reply(res,500,{error:'ระบบไม่สามารถทำรายการได้'});}
});
server.listen(4173,'127.0.0.1',()=>console.log('Clinic demo: http://127.0.0.1:4173'));
