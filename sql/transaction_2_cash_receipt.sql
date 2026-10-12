BEGIN;
SET LOCAL search_path = clinic17, public;

DO $$
DECLARE
    v_queue_id bigint := 1;
    v_staff_id bigint := 1;
    v_medical_fee numeric(12,2) := 300.00;
    v_lab_fee numeric(12,2) := 0.00;
    v_received numeric(12,2) := 500.00;
    v_record_id bigint;
    v_patient_id bigint;
    v_user_id bigint;
    v_drug_total numeric(12,2);
    v_total numeric(12,2);
    v_payment_id bigint;
    item record;
BEGIN
    PERFORM 1 FROM queue
    WHERE queue_id = v_queue_id AND status = 'awaiting_payment' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'คิวไม่ได้อยู่ในสถานะรอชำระเงิน';
    END IF;
    SELECT record_id, patient_id INTO v_record_id, v_patient_id
    FROM medical_record WHERE queue_id = v_queue_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ไม่พบเวชระเบียนของคิวนี้'; END IF;

    SELECT user_id INTO v_user_id FROM receptionist WHERE staff_id = v_staff_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'ไม่พบพนักงานผู้รับชำระ'; END IF;
    IF EXISTS (SELECT 1 FROM payment WHERE record_id = v_record_id) THEN
        RAISE EXCEPTION 'การตรวจครั้งนี้มีรายการชำระเงินแล้ว';
    END IF;

    SELECT coalesce(sum(amount),0) INTO v_drug_total
    FROM prescription_total WHERE record_id = v_record_id;
    v_total := v_medical_fee + v_lab_fee + v_drug_total;
    IF v_medical_fee < 0 OR v_lab_fee < 0 OR v_total < 0 OR v_received < v_total THEN
        RAISE EXCEPTION 'ค่าบริการไม่ถูกต้อง หรือรับเงินไม่ครบ';
    END IF;

    -- ล็อกและตัดสต็อกเรียง DrugID; การตรวจที่ไม่มีใบสั่งยาจะข้ามลูปนี้
    FOR item IN
        SELECT d.drug_id, d.stock_quantity, pd.quantity
        FROM prescription p
        JOIN prescription_detail pd USING (prescription_id)
        JOIN drug d USING (drug_id)
        WHERE p.record_id = v_record_id
        ORDER BY d.drug_id FOR UPDATE OF d
    LOOP
        IF item.stock_quantity < item.quantity THEN
            RAISE EXCEPTION 'ยา % มีสต็อกไม่พอ', item.drug_id;
        END IF;
        UPDATE drug SET stock_quantity = stock_quantity - item.quantity
        WHERE drug_id = item.drug_id;
    END LOOP;

    INSERT INTO payment
        (record_id, patient_id, staff_id, payment_method, payment_date,
         amount, medical_fee, lab_fee, received_amount, status)
    VALUES
        (v_record_id, v_patient_id, v_staff_id, 'cash', current_timestamp,
         v_total, v_medical_fee, v_lab_fee, v_received, 'paid')
    RETURNING payment_id INTO v_payment_id;

    INSERT INTO receipt (payment_id, staff_id, total_price)
    VALUES (v_payment_id, v_staff_id, v_total);
    UPDATE queue SET status = 'completed' WHERE queue_id = v_queue_id;
    INSERT INTO activity_log (user_id, action)
    VALUES (v_user_id, 'cash_payment_receipt_and_dispensing_completed');
END $$;
COMMIT;
