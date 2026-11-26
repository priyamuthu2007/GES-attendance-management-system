CREATE TABLE IF NOT EXISTS employees (
<<<<<<< HEAD
    employee_id VARCHAR(64) PRIMARY KEY,
    password_hash VARCHAR(255) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS employee_roles (
    employee_id VARCHAR(64) PRIMARY KEY
        REFERENCES employees(employee_id) ON DELETE CASCADE,
    role VARCHAR(16) NOT NULL DEFAULT 'employee'
        CHECK (role IN ('admin', 'manager', 'hr', 'auditor', 'employee')),
    updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS employee_profiles (
    employee_id VARCHAR(64) PRIMARY KEY
        REFERENCES employees(employee_id) ON DELETE CASCADE,
    full_name VARCHAR(160) NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS audit_logs (
    audit_id BIGSERIAL PRIMARY KEY,
    actor_employee_id VARCHAR(64) NOT NULL,
    actor_role VARCHAR(16) NOT NULL,
    action VARCHAR(64) NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id VARCHAR(128),
    details TEXT,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS audit_logs_created
    ON audit_logs (created_at);
CREATE INDEX IF NOT EXISTS audit_logs_actor
    ON audit_logs (actor_employee_id, audit_id);

CREATE TABLE IF NOT EXISTS location_risk_events (
    risk_event_id BIGSERIAL PRIMARY KEY,
    employee_id VARCHAR(64) NOT NULL
        REFERENCES employees(employee_id),
    signals TEXT NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS location_risk_employee_created
    ON location_risk_events (employee_id, created_at);
=======
    employee_id VARCHAR(64) NOT NULL PRIMARY KEY,
    email VARCHAR(254) NULL,
    password_hash VARCHAR(255) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY employees_email_unique (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891

CREATE TABLE IF NOT EXISTS employee_shifts (
    employee_id VARCHAR(64) NOT NULL
        REFERENCES employees(employee_id) ON DELETE CASCADE,
    day_of_week SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    shift_start TIME NOT NULL,
    shift_end TIME NOT NULL,
    PRIMARY KEY (employee_id, day_of_week)
);

ALTER TABLE employee_shifts ALTER COLUMN shift_start DROP NOT NULL;
ALTER TABLE employee_shifts ALTER COLUMN shift_end DROP NOT NULL;

CREATE TABLE IF NOT EXISTS employee_offices (
    employee_id VARCHAR(64) NOT NULL
        REFERENCES employees(employee_id) ON DELETE CASCADE,
    office_id VARCHAR(64) NOT NULL,
    PRIMARY KEY (employee_id, office_id)
);

CREATE TABLE IF NOT EXISTS attendance (
    attendance_id BIGSERIAL PRIMARY KEY,
    employee_id VARCHAR(64) NOT NULL
        REFERENCES employees(employee_id),
    attendance_date DATE NOT NULL,
    shift_start TIME NOT NULL,
    shift_end TIME NOT NULL,
<<<<<<< HEAD
    check_in_at TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    check_in_latitude DOUBLE PRECISION NOT NULL
        CHECK (check_in_latitude BETWEEN -90 AND 90),
    check_in_longitude DOUBLE PRECISION NOT NULL
        CHECK (check_in_longitude BETWEEN -180 AND 180),
    check_in_accuracy_meters DOUBLE PRECISION NOT NULL
        CHECK (check_in_accuracy_meters BETWEEN 0 AND 25),
    check_in_distance_meters DOUBLE PRECISION NOT NULL
        CHECK (check_in_distance_meters >= 0),
    check_in_office_id VARCHAR(64) NOT NULL,
    check_in_office_name VARCHAR(160) NOT NULL,
    check_out_at TIMESTAMP WITHOUT TIME ZONE,
    check_out_latitude DOUBLE PRECISION
        CHECK (check_out_latitude IS NULL OR check_out_latitude BETWEEN -90 AND 90),
    check_out_longitude DOUBLE PRECISION
        CHECK (check_out_longitude IS NULL OR check_out_longitude BETWEEN -180 AND 180),
    check_out_accuracy_meters DOUBLE PRECISION
        CHECK (check_out_accuracy_meters IS NULL OR check_out_accuracy_meters BETWEEN 0 AND 25),
    check_out_distance_meters DOUBLE PRECISION
        CHECK (check_out_distance_meters IS NULL OR check_out_distance_meters >= 0),
    check_out_office_id VARCHAR(64),
    check_out_office_name VARCHAR(160),
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (employee_id, attendance_date)
);

CREATE INDEX IF NOT EXISTS attendance_open_checkin
    ON attendance (employee_id, check_out_at, attendance_date);

ALTER TABLE attendance ALTER COLUMN shift_start DROP NOT NULL;
ALTER TABLE attendance ALTER COLUMN shift_end DROP NOT NULL;
=======
    check_in_at DATETIME NOT NULL COMMENT 'Stored in UTC',
    check_in_latitude DOUBLE NULL,
    check_in_longitude DOUBLE NULL,
    check_in_accuracy_meters DOUBLE NULL,
    check_in_distance_meters DOUBLE NULL,
    check_in_office_id VARCHAR(64) NOT NULL,
    check_in_office_name VARCHAR(160) NOT NULL,
    check_in_source VARCHAR(24) NOT NULL DEFAULT 'gps',
    check_out_at DATETIME NULL COMMENT 'Stored in UTC',
    check_out_latitude DOUBLE NULL,
    check_out_longitude DOUBLE NULL,
    check_out_accuracy_meters DOUBLE NULL,
    check_out_distance_meters DOUBLE NULL,
    check_out_office_id VARCHAR(64) NULL,
    check_out_office_name VARCHAR(160) NULL,
    check_out_source VARCHAR(24) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY attendance_employee_day (employee_id, attendance_date),
    KEY attendance_open_checkin (employee_id, check_out_at, attendance_date),
    CONSTRAINT attendance_employee_fk
        FOREIGN KEY (employee_id) REFERENCES employees(employee_id),
    CONSTRAINT attendance_latitude CHECK (check_in_latitude BETWEEN -90 AND 90),
    CONSTRAINT attendance_longitude CHECK (check_in_longitude BETWEEN -180 AND 180),
    CONSTRAINT attendance_accuracy CHECK (check_in_accuracy_meters BETWEEN 0 AND 25),
    CONSTRAINT attendance_distance CHECK (check_in_distance_meters >= 0),
    CONSTRAINT attendance_checkout_latitude CHECK (
        check_out_latitude IS NULL OR check_out_latitude BETWEEN -90 AND 90
    ),
    CONSTRAINT attendance_checkout_longitude CHECK (
        check_out_longitude IS NULL OR check_out_longitude BETWEEN -180 AND 180
    ),
    CONSTRAINT attendance_checkout_accuracy CHECK (
        check_out_accuracy_meters IS NULL OR check_out_accuracy_meters BETWEEN 0 AND 25
    ),
    CONSTRAINT attendance_checkout_distance CHECK (
        check_out_distance_meters IS NULL OR check_out_distance_meters >= 0
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS managers (
    manager_id VARCHAR(64) NOT NULL PRIMARY KEY,
    email VARCHAR(254) NULL,
    password_hash VARCHAR(255) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY managers_email_unique (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS attendance_exception_requests (
    request_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(64) NOT NULL,
    attendance_date DATE NOT NULL,
    action ENUM('check-in', 'check-out') NOT NULL,
    requested_at DATETIME NOT NULL COMMENT 'Stored in UTC',
    shift_start TIME NOT NULL,
    shift_end TIME NOT NULL,
    reason VARCHAR(500) NOT NULL,
    status ENUM('pending', 'approved', 'rejected') NOT NULL DEFAULT 'pending',
    manager_id VARCHAR(64) NULL,
    decided_at DATETIME NULL COMMENT 'Stored in UTC',
    decision_note VARCHAR(500) NULL,
    attendance_id BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY exception_pending_queue (status, created_at),
    KEY exception_employee_status (employee_id, attendance_date, status),
    CONSTRAINT exception_employee_fk
        FOREIGN KEY (employee_id) REFERENCES employees(employee_id),
    CONSTRAINT exception_manager_fk
        FOREIGN KEY (manager_id) REFERENCES managers(manager_id),
    CONSTRAINT exception_attendance_fk
        FOREIGN KEY (attendance_id) REFERENCES attendance(attendance_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
