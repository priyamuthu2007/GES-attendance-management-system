import getpass
import sys

import pymysql
from dotenv import dotenv_values


DATABASE = "ges_attendance_pilot"
APP_USER = "ges_staging_app"
MIGRATION_USER = "ges_staging_migrator"


def main():
    config = dotenv_values(".env")
    if config.get("MYSQL_DATABASE") != DATABASE:
        raise ValueError(f"MYSQL_DATABASE must be {DATABASE}.")
    if config.get("MYSQL_USER") != APP_USER:
        raise ValueError(f"MYSQL_USER must be {APP_USER}.")
    if config.get("MYSQL_MIGRATION_USER") != MIGRATION_USER:
        raise ValueError(f"MYSQL_MIGRATION_USER must be {MIGRATION_USER}.")
    if config.get("MYSQL_HOST") not in {"127.0.0.1", "localhost"}:
        raise ValueError("This helper only connects to a local MySQL server.")

    app_password = config.get("MYSQL_PASSWORD")
    migration_password = config.get("MYSQL_MIGRATION_PASSWORD")
    if not app_password or not migration_password:
        raise ValueError("Set both staging passwords in the project .env first.")
    if app_password == migration_password:
        raise ValueError("Use different passwords for the staging app and migration users.")

    admin_password = getpass.getpass("MySQL root password: ")
    if not admin_password:
        raise ValueError("MySQL root password cannot be empty.")

    connection = pymysql.connect(
        host="127.0.0.1",
        port=int(config.get("MYSQL_PORT") or 3306),
        user="root",
        password=admin_password,
        charset="utf8mb4",
        autocommit=True,
        connect_timeout=5,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                f"CREATE DATABASE IF NOT EXISTS `{DATABASE}` "
                "CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
            )
            for username, password in (
                (APP_USER, app_password),
                (MIGRATION_USER, migration_password),
            ):
                cursor.execute(
                    f"CREATE USER IF NOT EXISTS '{username}'@'localhost' IDENTIFIED BY %s",
                    (password,),
                )
                cursor.execute(
                    f"ALTER USER '{username}'@'localhost' IDENTIFIED BY %s",
                    (password,),
                )
            cursor.execute(
                f"GRANT SELECT, INSERT, UPDATE, DELETE ON `{DATABASE}`.* "
                f"TO '{APP_USER}'@'localhost'"
            )
            cursor.execute(
                f"GRANT CREATE, ALTER, INDEX, REFERENCES ON `{DATABASE}`.* "
                f"TO '{MIGRATION_USER}'@'localhost'"
            )
    finally:
        connection.close()

    for label, username, password in (
        ("app", APP_USER, app_password),
        ("migration", MIGRATION_USER, migration_password),
    ):
        test_connection = pymysql.connect(
            host="127.0.0.1",
            port=int(config.get("MYSQL_PORT") or 3306),
            user=username,
            password=password,
            database=DATABASE,
            charset="utf8mb4",
            connect_timeout=5,
        )
        test_connection.close()
        print(f"{label} database login verified.")

    print("Pilot database users and least-privilege grants are synchronized.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Pilot database setup failed: {error}", file=sys.stderr)
        raise SystemExit(1)
