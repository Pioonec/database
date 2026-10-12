-- PostgreSQL. Run once in a new database or a database without schema clinic17.
-- Matches the latest 17 original ER entities; no additional entity tables.
-- Run: psql -X -v ON_ERROR_STOP=1 -d clinic_project -f clinic_17_entities.sql
BEGIN;
CREATE SCHEMA clinic17;
SET LOCAL search_path = clinic17, public;

-- 1. Users
CREATE TABLE users (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username varchar(80) NOT NULL CHECK (btrim(username) <> ''),
    password_hash text NOT NULL CHECK (
        password_hash LIKE '$argon2id$%' OR password_hash ~ '^\$2[aby]\$'),
    role varchar(20) NOT NULL CHECK (role IN ('patient','doctor','receptionist','admin')),
    UNIQUE (user_id, role)
);
CREATE UNIQUE INDEX uq_users_username ON users (lower(username));

-- 2. Patient. Optional online account; one patient-role account belongs to one patient.
CREATE TABLE patient (
    patient_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint UNIQUE,
    account_role varchar(20) NOT NULL DEFAULT 'patient' CHECK (account_role = 'patient'),
    name varchar(160) NOT NULL CHECK (btrim(name) <> ''),
    citizen_id varchar(13) NOT NULL UNIQUE CHECK (citizen_id ~ '^[0-9]{13}$'),
    date_of_birth date NOT NULL CHECK (date_of_birth >= DATE '1900-01-01'),
    phone varchar(20) NOT NULL CHECK (btrim(phone) <> ''),
    gender varchar(10) NOT NULL CHECK (gender IN ('male','female','other','unknown')),
    address text,
    identity_verified_at timestamptz,
    FOREIGN KEY (user_id, account_role) REFERENCES users(user_id, role)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- 3. Doctor
CREATE TABLE doctor (
    doctor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL UNIQUE,
    account_role varchar(20) NOT NULL DEFAULT 'doctor' CHECK (account_role = 'doctor'),
    doctor_name varchar(160) NOT NULL CHECK (btrim(doctor_name) <> ''),
    license_number varchar(50) NOT NULL UNIQUE CHECK (btrim(license_number) <> ''),
    doctor_phone varchar(20) NOT NULL,
    specialty varchar(120) NOT NULL,
    FOREIGN KEY (user_id, account_role) REFERENCES users(user_id, role)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- 4. Receptionist
CREATE TABLE receptionist (
    staff_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL UNIQUE,
    account_role varchar(20) NOT NULL DEFAULT 'receptionist' CHECK (account_role = 'receptionist'),
    staff_name varchar(160) NOT NULL CHECK (btrim(staff_name) <> ''),
    staff_phone varchar(20) NOT NULL,
    FOREIGN KEY (user_id, account_role) REFERENCES users(user_id, role)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- 5. Bank. The retained model supports one receiving account per bank record.
CREATE TABLE bank (
    bank_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bank_name varchar(120) NOT NULL CHECK (btrim(bank_name) <> ''),
    account_number varchar(40) NOT NULL CHECK (btrim(account_number) <> ''),
    UNIQUE (bank_name, account_number)
);

-- 6. Drug
CREATE TABLE drug (
    drug_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    drug_name varchar(160) NOT NULL CHECK (btrim(drug_name) <> ''),
    unit varchar(30) NOT NULL CHECK (btrim(unit) <> ''),
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    stock_quantity integer NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    UNIQUE (drug_name, unit)
);

-- 7. External lab
CREATE TABLE external_lab (
    lab_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lab_name varchar(160) NOT NULL CHECK (btrim(lab_name) <> ''),
    lab_address text NOT NULL
);

-- 8. Appointment. One appointment = one date and start time.
CREATE TABLE appointment (
    appointment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id bigint NOT NULL REFERENCES patient(patient_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    doctor_id bigint NOT NULL REFERENCES doctor(doctor_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    appoint_date date NOT NULL,
    appoint_time time NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'scheduled'
        CHECK (status IN ('scheduled','checked_in','completed','cancelled','no_show')),
    booking_source varchar(10) NOT NULL CHECK (booking_source IN ('online','counter')),
    reschedule_count integer NOT NULL DEFAULT 0 CHECK (reschedule_count >= 0),
    UNIQUE (appointment_id, patient_id)
);
CREATE UNIQUE INDEX uq_doctor_active_slot ON appointment (doctor_id, appoint_date, appoint_time)
    WHERE status IN ('scheduled','checked_in');
CREATE UNIQUE INDEX uq_patient_online_day ON appointment (patient_id, appoint_date)
    WHERE booking_source = 'online' AND status IN ('scheduled','checked_in');
CREATE INDEX ix_appointment_patient_date ON appointment (patient_id, appoint_date);

-- 9. Queue. Supply sequence_number within a transaction that serializes daily allocation.
CREATE TABLE queue (
    queue_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id bigint,
    patient_id bigint NOT NULL REFERENCES patient(patient_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    doctor_id bigint NOT NULL REFERENCES doctor(doctor_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    queue_date date NOT NULL DEFAULT ((current_timestamp AT TIME ZONE 'Asia/Bangkok')::date),
    sequence_number integer NOT NULL CHECK (sequence_number > 0),
    time_received timestamptz NOT NULL DEFAULT current_timestamp,
    status varchar(20) NOT NULL DEFAULT 'waiting'
        CHECK (status IN ('waiting','called','in_service','awaiting_payment','completed','cancelled')),
    UNIQUE (queue_date, sequence_number),
    UNIQUE (queue_id, patient_id, doctor_id),
    CONSTRAINT ck_queue_received_day CHECK
        (queue_date = (time_received AT TIME ZONE 'Asia/Bangkok')::date),
    -- MATCH SIMPLE permits walk-ins with a NULL appointment_id.
    -- Queue doctor may differ from the appointment doctor by business rule.
    CONSTRAINT fk_queue_appointment_patient FOREIGN KEY (appointment_id, patient_id)
        REFERENCES appointment(appointment_id, patient_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);
CREATE UNIQUE INDEX uq_patient_active_queue ON queue (patient_id)
    WHERE status IN ('waiting','called','in_service','awaiting_payment');
CREATE INDEX ix_queue_doctor_day_status ON queue (doctor_id, queue_date, status);
CREATE INDEX ix_queue_appointment ON queue (appointment_id);

-- 10. Medical record. One queue has zero or one record.
CREATE TABLE medical_record (
    record_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    queue_id bigint NOT NULL UNIQUE,
    patient_id bigint NOT NULL,
    doctor_id bigint NOT NULL,
    record_date timestamptz NOT NULL DEFAULT current_timestamp,
    symptoms text NOT NULL CHECK (btrim(symptoms) <> ''),
    diagnosis text NOT NULL CHECK (btrim(diagnosis) <> ''),
    treatment_detail text NOT NULL,
    UNIQUE (record_id, patient_id),
    FOREIGN KEY (queue_id, patient_id, doctor_id)
        REFERENCES queue(queue_id, patient_id, doctor_id) ON DELETE RESTRICT ON UPDATE RESTRICT
);
CREATE INDEX ix_record_patient_date ON medical_record (patient_id, record_date DESC);

-- 11. Prescription. Amount is calculated from details when reading; it is not stored twice.
-- Doctor is obtained from the medical record; a duplicate doctor_id is unnecessary.
CREATE TABLE prescription (
    prescription_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prescription_date timestamptz NOT NULL DEFAULT current_timestamp,
    record_id bigint NOT NULL UNIQUE REFERENCES medical_record(record_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- 12. Prescription detail
CREATE TABLE prescription_detail (
    prescription_detail_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prescription_id bigint NOT NULL REFERENCES prescription(prescription_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    drug_id bigint NOT NULL REFERENCES drug(drug_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_price_at_prescription numeric(12,2) NOT NULL CHECK (unit_price_at_prescription >= 0),
    dosage_detail text NOT NULL CHECK (btrim(dosage_detail) <> ''),
    UNIQUE (prescription_id, drug_id)
);
CREATE INDEX ix_detail_drug ON prescription_detail (drug_id);

-- 13. Lab request. One request represents one test.
-- Ordering doctor is obtained from the medical record; a duplicate doctor_id would be
-- a transitive dependency (request_id -> record_id -> doctor_id), as with prescription.
CREATE TABLE lab_request (
    request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    record_id bigint NOT NULL REFERENCES medical_record(record_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    lab_id bigint NOT NULL REFERENCES external_lab(lab_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    request_date timestamptz NOT NULL DEFAULT current_timestamp,
    request_detail text NOT NULL CHECK (btrim(request_detail) <> '')
);
CREATE INDEX ix_request_record ON lab_request (record_id);

-- 14. Lab result. Lab and medical record are obtained through the request.
CREATE TABLE lab_result (
    result_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id bigint NOT NULL UNIQUE REFERENCES lab_request(request_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    test_type varchar(160) NOT NULL,
    test_result_detail text,
    test_status varchar(15) NOT NULL DEFAULT 'pending'
        CHECK (test_status IN ('pending','completed','cancelled')),
    result_date timestamptz,
    CHECK ((test_status = 'completed' AND result_date IS NOT NULL AND test_result_detail IS NOT NULL)
        OR (test_status <> 'completed' AND result_date IS NULL))
);

-- 15. Payment. Exactly one retained payment record per medical record.
CREATE TABLE payment (
    payment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    record_id bigint NOT NULL UNIQUE,
    patient_id bigint NOT NULL,
    staff_id bigint NOT NULL REFERENCES receptionist(staff_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    bank_id bigint REFERENCES bank(bank_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    payment_method varchar(10) NOT NULL CHECK (payment_method IN ('cash','qr')),
    payment_date timestamptz,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    medical_fee numeric(12,2) NOT NULL DEFAULT 0 CHECK (medical_fee >= 0),
    lab_fee numeric(12,2) NOT NULL DEFAULT 0 CHECK (lab_fee >= 0),
    received_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (received_amount >= 0),
    -- Change is computed as received_amount - amount when reading paid payments.
    status varchar(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paid','failed','cancelled')),
    CHECK ((payment_method = 'cash' AND bank_id IS NULL) OR (payment_method = 'qr' AND bank_id IS NOT NULL)),
    CHECK ((status = 'paid' AND payment_date IS NOT NULL AND received_amount >= amount)
        OR (status <> 'paid' AND payment_date IS NULL)),
    CHECK (status <> 'paid' OR payment_method <> 'qr' OR received_amount = amount),
    FOREIGN KEY (record_id, patient_id) REFERENCES medical_record(record_id, patient_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);
CREATE INDEX ix_payment_date_status ON payment (payment_date, status);

-- 16. Receipt. No duplicate patient_id; patient is obtained through payment.
CREATE TABLE receipt (
    receipt_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id bigint NOT NULL UNIQUE REFERENCES payment(payment_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    staff_id bigint NOT NULL REFERENCES receptionist(staff_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    issue_date timestamptz NOT NULL DEFAULT current_timestamp,
    total_price numeric(12,2) NOT NULL CHECK (total_price >= 0)
);

-- 17. Activity log. Do not log passwords or clinical text in action.
CREATE TABLE activity_log (
    log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    logged_at timestamptz NOT NULL DEFAULT current_timestamp,
    action varchar(200) NOT NULL CHECK (btrim(action) <> '')
);
CREATE INDEX ix_log_user_time ON activity_log (user_id, logged_at DESC);

-- A view is not an additional entity table. Amount comes from historical unit prices.
CREATE VIEW prescription_total AS
SELECT p.prescription_id, p.record_id,
       coalesce(sum(d.quantity::numeric * d.unit_price_at_prescription), 0)::numeric(12,2) AS amount
FROM prescription p LEFT JOIN prescription_detail d USING (prescription_id)
GROUP BY p.prescription_id, p.record_id;

-- Cross-table checks that cannot be expressed with a simple CHECK.
CREATE FUNCTION validate_patient() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
BEGIN
    IF NEW.date_of_birth > (current_timestamp AT TIME ZONE 'Asia/Bangkok')::date THEN
        RAISE EXCEPTION 'Birth date cannot be in the future';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_patient_birth BEFORE INSERT OR UPDATE ON patient
FOR EACH ROW EXECUTE FUNCTION validate_patient();

CREATE FUNCTION validate_queue() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
BEGIN
    PERFORM 1 FROM patient WHERE patient_id = NEW.patient_id AND identity_verified_at IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Patient identity must be verified before opening a queue'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_queue_identity BEFORE INSERT ON queue
FOR EACH ROW EXECUTE FUNCTION validate_queue();

CREATE FUNCTION validate_appointment() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
DECLARE target_at timestamptz;
BEGIN
    target_at := (NEW.appoint_date + NEW.appoint_time) AT TIME ZONE 'Asia/Bangkok';
    IF TG_OP = 'INSERT' THEN
        IF NEW.reschedule_count <> 0 THEN RAISE EXCEPTION 'New appointment reschedule count must be zero'; END IF;
        IF NEW.status <> 'scheduled' THEN RAISE EXCEPTION 'New appointment must be scheduled'; END IF;
        IF target_at < current_timestamp + interval '24 hours' THEN
            RAISE EXCEPTION 'Appointment must be booked at least 24 hours ahead';
        END IF;
    ELSE
        IF (NEW.patient_id, NEW.booking_source) IS DISTINCT FROM (OLD.patient_id, OLD.booking_source) THEN
            RAISE EXCEPTION 'Appointment patient and booking source cannot change';
        END IF;
        IF NEW.reschedule_count <> OLD.reschedule_count THEN RAISE EXCEPTION 'Reschedule count is maintained by the database'; END IF;
        IF OLD.status IN ('completed','cancelled','no_show') AND NEW IS DISTINCT FROM OLD THEN
            RAISE EXCEPTION 'Closed appointment cannot change';
        END IF;
        IF (NEW.appoint_date, NEW.appoint_time, NEW.doctor_id)
            IS DISTINCT FROM (OLD.appoint_date, OLD.appoint_time, OLD.doctor_id) THEN
            IF OLD.status <> 'scheduled' OR NEW.status <> 'scheduled' THEN
                RAISE EXCEPTION 'Only scheduled appointments can be rescheduled';
            END IF;
            IF ((OLD.appoint_date + OLD.appoint_time) AT TIME ZONE 'Asia/Bangkok')
                < current_timestamp + interval '24 hours' OR target_at < current_timestamp + interval '24 hours' THEN
                RAISE EXCEPTION 'Reschedule requires 24 hours before both appointment times';
            END IF;
            IF OLD.booking_source = 'online' AND OLD.reschedule_count >= 2 THEN
                RAISE EXCEPTION 'Online reschedule limit is two';
            END IF;
            NEW.reschedule_count := OLD.reschedule_count + 1;
        END IF;
        IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' AND
            ((OLD.appoint_date + OLD.appoint_time) AT TIME ZONE 'Asia/Bangkok') < current_timestamp + interval '24 hours' THEN
            RAISE EXCEPTION 'Cancellation requires at least 24 hours notice';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_appointment_rules BEFORE INSERT OR UPDATE ON appointment
FOR EACH ROW EXECUTE FUNCTION validate_appointment();

-- Lock the record before changing charges/details or taking payment. This serializes
-- these operations for one visit and stops prescription edits after successful payment.
CREATE FUNCTION protect_prescription() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
DECLARE rid bigint; pid bigint;
BEGIN
    IF TG_TABLE_NAME = 'prescription' THEN
        IF TG_OP = 'UPDATE' AND NEW.record_id <> OLD.record_id THEN RAISE EXCEPTION 'Prescription record cannot change'; END IF;
        rid := CASE WHEN TG_OP = 'DELETE' THEN OLD.record_id ELSE NEW.record_id END;
    ELSE
        IF TG_OP = 'UPDATE' AND NEW.prescription_id <> OLD.prescription_id THEN RAISE EXCEPTION 'Prescription detail cannot move to another prescription'; END IF;
        pid := CASE WHEN TG_OP = 'DELETE' THEN OLD.prescription_id ELSE NEW.prescription_id END;
        SELECT record_id INTO rid FROM prescription WHERE prescription_id = pid;
    END IF;
    PERFORM 1 FROM medical_record WHERE record_id = rid FOR UPDATE;
    IF EXISTS (SELECT 1 FROM payment WHERE record_id = rid AND status = 'paid') THEN
        RAISE EXCEPTION 'Prescription cannot change after payment';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_protect_prescription BEFORE INSERT OR UPDATE OR DELETE ON prescription
FOR EACH ROW EXECUTE FUNCTION protect_prescription();
CREATE TRIGGER trg_protect_detail BEFORE INSERT OR UPDATE OR DELETE ON prescription_detail
FOR EACH ROW EXECUTE FUNCTION protect_prescription();

CREATE FUNCTION validate_payment() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
DECLARE drug_total numeric(12,2);
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.record_id <> OLD.record_id THEN RAISE EXCEPTION 'Payment record cannot change'; END IF;
        IF OLD.status = 'paid' AND NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'Paid payment is immutable'; END IF;
    END IF;
    PERFORM 1 FROM medical_record WHERE record_id = NEW.record_id FOR UPDATE;
    IF NEW.status = 'paid' THEN
        SELECT coalesce(sum(amount),0) INTO drug_total FROM prescription_total WHERE record_id = NEW.record_id;
        IF NEW.amount <> NEW.medical_fee + NEW.lab_fee + drug_total THEN
            RAISE EXCEPTION 'Payment amount must equal medical fee, lab fee and prescription total';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_payment_total BEFORE INSERT OR UPDATE ON payment
FOR EACH ROW EXECUTE FUNCTION validate_payment();

CREATE FUNCTION validate_receipt() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
DECLARE p payment%ROWTYPE;
BEGIN
    SELECT * INTO p FROM payment WHERE payment_id = NEW.payment_id FOR UPDATE;
    IF p.status IS DISTINCT FROM 'paid' THEN RAISE EXCEPTION 'Receipt requires a paid payment'; END IF;
    IF NEW.total_price <> p.amount THEN RAISE EXCEPTION 'Receipt total must match payment amount'; END IF;
    IF NEW.issue_date < p.payment_date THEN RAISE EXCEPTION 'Receipt cannot precede payment'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_payment BEFORE INSERT ON receipt
FOR EACH ROW EXECUTE FUNCTION validate_receipt();

CREATE FUNCTION immutable_history() RETURNS trigger LANGUAGE plpgsql
SET search_path = clinic17, pg_temp AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;
CREATE TRIGGER trg_receipt_immutable BEFORE UPDATE OR DELETE ON receipt
FOR EACH ROW EXECUTE FUNCTION immutable_history();
CREATE TRIGGER trg_log_immutable BEFORE UPDATE OR DELETE ON activity_log
FOR EACH ROW EXECUTE FUNCTION immutable_history();

COMMIT;

-- Backend still supplies authentication, actor permissions, inventory transactions,
-- provider verification, queue status transitions and appointment working hours.
-- Only equal start-time conflicts are checked: this retained ER has no slot duration.
-- Payment/receipt/inventory must be changed together using BEGIN/COMMIT/ROLLBACK.
-- The 17-entity scope has no separate allergy, certificate, notification, audit-change
-- or stock-movement entity; do not claim that these SA features are fully implemented.
