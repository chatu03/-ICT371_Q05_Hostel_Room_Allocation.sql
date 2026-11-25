-- ICT371 Advanced Databases | Question 5
-- Hostel Room Allocation
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q05.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The allocation constraint ties status to the release date. A partial unique index
-- enforces at most one ACTIVE allocation per student. Load the sample allocations after
-- parts (b)–(d).
CREATE SCHEMA ict371_q05;
SET search_path = ict371_q05, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE students (
    student_id integer PRIMARY KEY,
    student_number text NOT NULL UNIQUE,
    full_name text NOT NULL
);

CREATE TABLE rooms (
    room_id integer PRIMARY KEY,
    room_number text NOT NULL UNIQUE,
    capacity integer NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id integer NOT NULL REFERENCES students,
    room_id integer NOT NULL REFERENCES rooms,
    allocated_on date NOT NULL CHECK (isfinite(allocated_on)),
    released_on date CHECK (isfinite(released_on) AND released_on >= allocated_on),
    status text NOT NULL CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE UNIQUE INDEX uq_allocations_active_student ON allocations (student_id)
WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date date,
    room_id integer REFERENCES rooms,
    occupied_beds bigint NOT NULL CHECK (occupied_beds >= 0),
    free_beds bigint NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students VALUES
    (1, 'ST001', 'Ruth Banda'), (2, 'ST002', 'David Phiri'),
    (3, 'ST003', 'Mary Zulu'), (4, 'ST004', 'Joseph Tembo');

INSERT INTO rooms VALUES (1, 'A01', 2), (2, 'A02', 3), (3, 'A03', 2);

-- (b) Function
-- The count includes only ACTIVE rows. Room A03 has two free beds even though it has an
-- ended allocation.
CREATE FUNCTION fn_free_beds(p_room_id integer)
RETURNS bigint LANGUAGE plpgsql SET search_path = ict371_q05, pg_catalog AS $$
DECLARE
    v_capacity integer;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    RETURN v_capacity - (
        SELECT COUNT(*) FROM allocations
        WHERE room_id = p_room_id AND status = 'ACTIVE'
    );
END;
$$;

-- (c) Procedure
-- Check availability while holding the destination room lock. The trigger and unique
-- index also protect inserts and updates made directly.
CREATE PROCEDURE pr_allocate_room(
    p_student_id integer, p_room_id integer, p_allocated_on date
)
LANGUAGE plpgsql SET search_path = ict371_q05, pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;
    IF p_allocated_on IS NULL OR NOT isfinite(p_allocated_on) THEN
        RAISE EXCEPTION 'A valid allocation date is required';
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an active allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger
-- The trigger locks the destination room before counting other active allocations. The
-- count excludes the row being updated. Concurrent counts for the same room run in turn
-- at the default READ COMMITTED isolation level.
CREATE FUNCTION fn_check_active_allocation()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q05, pg_catalog AS $$
DECLARE
    v_capacity integer;
    v_existing_id bigint;
BEGIN
    IF NEW.status IS DISTINCT FROM 'ACTIVE' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        v_existing_id := OLD.allocation_id;
    END IF;

    SELECT capacity INTO v_capacity FROM rooms
    WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', NEW.room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations AS a
        WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
          AND (v_existing_id IS NULL OR a.allocation_id <> v_existing_id)
    ) THEN
        RAISE EXCEPTION 'Student % already has an active allocation', NEW.student_id;
    END IF;

    IF (
        SELECT COUNT(*) FROM allocations AS a
        WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
          AND (v_existing_id IS NULL OR a.allocation_id <> v_existing_id)
    ) >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full', NEW.room_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_active_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION fn_check_active_allocation();

-- (a) Deferred seed data, loaded after the routines and trigger
CALL pr_allocate_room(1, 1, CURRENT_DATE);
CALL pr_allocate_room(2, 1, CURRENT_DATE);
CALL pr_allocate_room(3, 2, CURRENT_DATE);

INSERT INTO allocations
    (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 5, CURRENT_DATE - 1, 'ENDED');

-- (e) View
-- The LEFT JOIN keeps every room in the report. COUNT of allocation_id gives zero if
-- there is no active allocation.
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms AS r
LEFT JOIN allocations AS a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index and execution plan
-- The partial index stores the room IDs for active allocations only. It supports
-- availability and occupancy queries for one room.
CREATE INDEX idx_allocations_active_room ON allocations (room_id)
WHERE status = 'ACTIVE';

EXPLAIN (COSTS OFF)
SELECT allocation_id, student_id FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';

-- Plan observed on the seed dataset:
-- Seq Scan on allocations
--   Filter: ((room_id = 1) AND (status = 'ACTIVE'::text))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_allocations_active_room on allocations
--   Index Cond: (room_id = 1)

-- (g) Scheduled job
-- The job takes a snapshot at 23:55. The composite primary key identifies one row per
-- date and room.
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql SET search_path = ict371_q05, pg_catalog AS $$
BEGIN
    INSERT INTO occupancy_snapshot
        (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;
ROLLBACK;

-- The seeded counts are 2 occupied and 0 free in A01, 1 occupied and 2 free in A02, and
-- 0 occupied and 2 free in A03.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q05',
    '55 23 * * *',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q05.pr_refresh_occupancy();
    $job$
);
*/
