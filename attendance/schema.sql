CREATE TABLE IF NOT EXISTS employees (
    employee_id VARCHAR(64) NOT NULL PRIMARY KEY,
    password_hash VARCHAR(255) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS employee_shifts (
    employee_id VARCHAR(64) NOT NULL,
    day_of_week TINYINT UNSIGNED NOT NULL,
    shift_start TIME NOT NULL,
    shift_end TIME NOT NULL,
    PRIMARY KEY (employee_id, day_of_week),
    CONSTRAINT employee_shifts_weekday CHECK (day_of_week BETWEEN 0 AND 6),
    CONSTRAINT employee_shifts_employee_fk
        FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS attendance (
    attendance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(64) NOT NULL,
    attendance_date DATE NOT NULL,
    shift_start TIME NOT NULL,
    shift_end TIME NOT NULL,
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
    password_hash VARCHAR(255) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
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
