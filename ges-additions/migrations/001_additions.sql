-- Run ONCE with the schema-migration MySQL account (it has CREATE):
--   mysql -u ges_attendance_migrator -p ges_attendance < migrations/001_additions.sql
-- Existing tables are not touched. employee_id columns carry no foreign key because
-- the type of your employees.id is unknown; add one if you want it.

CREATE TABLE IF NOT EXISTS admin_users (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(100) NOT NULL,
  active        TINYINT(1)   NOT NULL DEFAULT 1,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_admin_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audit_log (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  admin_id   INT UNSIGNED NULL,
  action     VARCHAR(40)  NOT NULL,
  target     VARCHAR(120) NOT NULL,
  details    TEXT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_audit_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS holidays (
  holiday_date DATE NOT NULL PRIMARY KEY,
  name         VARCHAR(120) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS leave_records (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  employee_id BIGINT UNSIGNED NOT NULL,
  leave_date  DATE NOT NULL,
  leave_type  ENUM('full','half') NOT NULL DEFAULT 'full',
  reason      VARCHAR(200) NULL,
  created_by  INT UNSIGNED NULL,
  UNIQUE KEY uq_leave_emp_day (employee_id, leave_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
