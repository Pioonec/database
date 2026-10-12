BEGIN;
SET LOCAL search_path = clinic17, public;

DO $$
DECLARE
    v_queue_id bigint := 1;
    v_doctor_id bigint := 1;
    v_drug_id bigint := 1;
    v_quantity integer := 2;
    v_record_id bigint;
    v_prescription_id bigint;
    v_patient_id bigint;
    v_user_id bigint;
    v_price numeric(12,2);
BEGIN
    SELECT patient_id INTO v_patient_id
    FROM queue
    WHERE queue_id = v_queue_id AND doctor_id = v_doctor_id
      AND status = 'in_service'
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ไม่พบคิวที่แพทย์กำลังตรวจ';
    END IF;
    IF EXISTS (SELECT 1 FROM medical_record WHERE queue_id = v_queue_id) THEN
        RAISE EXCEPTION 'คิวนี้มีเวชระเบียนแล้ว';
    END IF;
    SELECT user_id INTO v_user_id FROM doctor WHERE doctor_id = v_doctor_id;
    SELECT unit_price INTO v_price FROM drug WHERE drug_id = v_drug_id FOR SHARE;
    IF NOT FOUND OR v_quantity <= 0 THEN
        RAISE EXCEPTION 'ไม่พบยา หรือจำนวนยาไม่ถูกต้อง';
    END IF;

    INSERT INTO medical_record
        (queue_id, patient_id, doctor_id, symptoms, diagnosis, treatment_detail)
    VALUES
        (v_queue_id, v_patient_id, v_doctor_id,
         'อาการตัวอย่าง', 'ผลวินิจฉัยตัวอย่าง', 'รายละเอียดการรักษาตัวอย่าง')
    RETURNING record_id INTO v_record_id;

    INSERT INTO prescription (record_id)
    VALUES (v_record_id) RETURNING prescription_id INTO v_prescription_id;

    INSERT INTO prescription_detail
        (prescription_id, drug_id, quantity, unit_price_at_prescription, dosage_detail)
    VALUES
        (v_prescription_id, v_drug_id, v_quantity, v_price, 'วิธีใช้ตามแพทย์สั่ง');

    UPDATE queue SET status = 'awaiting_payment' WHERE queue_id = v_queue_id;
    INSERT INTO activity_log (user_id, action)
    VALUES (v_user_id, 'medical_record_and_prescription_created');
END $$;
COMMIT;
