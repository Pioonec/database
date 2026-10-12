# Tamyan Clinic — Source Code ของ Demo จองนัดแพทย์

Demo สำหรับ Term Project: คนไข้จองนัดแพทย์ผ่าน UI บนฐานข้อมูล PostgreSQL (PGlite ฝังในแอป)
ใช้ Schema `clinic17` ฉบับเดียวกับรายงาน (`sql/clinic_17_entities.sql`, 17 ตาราง)

## โครงสร้างไฟล์

| ไฟล์ | หน้าที่ |
|---|---|
| `server.mjs` | HTTP server + API (login, ดูนัด, จองนัด, ตรวจฐานข้อมูล) สร้าง Schema จาก DDL ตอนเปิดครั้งแรก |
| `index.html` | หน้าเว็บ (HTML + CSS + JavaScript ในไฟล์เดียว) |
| `sql/clinic_17_entities.sql` | DDL ทั้งหมด: ตาราง, PK/FK, CHECK, UNIQUE index, Trigger |
| `sql/transaction_*.sql` | Transaction ตัวอย่างในรายงานข้อ 3.4 |
| `verify.mjs` | ชุดทดสอบ API 18 กรณี (ต้องรันกับฐานข้อมูลใหม่) |
| `capture_demo.mjs` | เปิด Edge/Chrome แบบ headless คลิก UI จริงและถ่ายภาพ 6 ขั้น |
| `verify_ui_result.mjs` | ตรวจผลจาก capture_demo และต่อท้ายใน `evidence/verification.json` |

## จุดสำคัญในโค้ด (ไว้ชี้ตอนนำเสนอ)

- **Transaction การจอง**: `server.mjs` ส่วน `POST /api/book` ใช้ `db.transaction(...)` INSERT `appointment` แล้ว INSERT `activity_log` ถ้าคำสั่งใดล้มเหลวจะ ROLLBACK ทั้งคู่
- **SQL แบบ parameter** (`$1, $2 ...`) ทุกคำสั่งที่รับค่าจากผู้ใช้ กัน SQL injection
- **ฐานข้อมูลเป็นผู้ตัดสิน**: server ไม่ตรวจเวลาซ้ำเอง ปล่อยให้ `uq_doctor_active_slot`, `uq_patient_online_day` และ Trigger 24 ชั่วโมงปฏิเสธ แล้วแปลง error เป็นข้อความ (HTTP 409)
- **รหัสผ่าน** เก็บเป็น Argon2id (`node:crypto` argon2Sync) ไม่ใช่ข้อความธรรมดา
- **Session** เป็น cookie HttpOnly + SameSite=Strict, ปฏิเสธ POST จาก origin อื่น

## วิธีรัน

ต้องมี Node.js **24.7 ขึ้นไป** (ใช้ `crypto.argon2Sync`)

```
npm install
npm start
```

เปิด http://127.0.0.1:4173/ — บัญชีทดสอบ `patient1`, `patient2`, `staff1` รหัสผ่าน `Demo2026!`

ข้อมูลเก็บใน `data/` (สร้างเองตอนเปิดครั้งแรก) เริ่มใหม่: หยุด server แล้วย้ายโฟลเดอร์ `data` ไปเก็บที่อื่น

## ทดสอบ

```
npm start            # หน้าต่างที่ 1 (ฐานข้อมูลใหม่)
npm run verify       # หน้าต่างที่ 2 -> evidence/verification.json
```

ข้อมูลทั้งหมดเป็นข้อมูลจำลอง

## หลักฐานการทดสอบ

- `evidence/verification.json` — ผลชุดทดสอบ API 18/18 และการคลิก UI จริง (ส่วน `uiDemo`)
- `evidence/screenshots/` — ภาพ Demo 6 ขั้น: ก่อนทำ, จองสำเร็จ, ฐานข้อมูลหลังทำ, ถูกปฏิเสธ, ฐานข้อมูลหลังถูกปฏิเสธ, ผลลัพธ์ปลายทาง
