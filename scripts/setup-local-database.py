import getpass
import re
import secrets
import sys
from pathlib import Path

import psycopg
from dotenv import dotenv_values
from psycopg import sql


PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / ".env"
APP_USER = "ges_attendance_app"
MIGRATION_USER = "ges_attendance_migrator"

sys.path.insert(0, str(PROJECT_ROOT))

from attendance.db import connect, init_db


def write_env_file(path, replacements):
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    lines = [line for line in lines if not line.startswith("MYSQL_")]
    for key, value in replacements.items():
        matching_lines = [
            index for index, line in enumerate(lines)
            if re.match(rf"^{re.escape(key)}=", line)
        ]
        if matching_lines:
            for index in matching_lines:
                lines[index] = f"{key}={value}"
        else:
            lines.append(f"{key}={value}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def configure_postgres(config, app_password, migration_password):
    host = config.get("PG_HOST") or "127.0.0.1"
    port = int(config.get("PG_PORT") or "5432")
    database_name = config.get("PG_DATABASE") or "ges"
    if not re.fullmatch(r"[A-Za-z0-9_]+", database_name):
        raise ValueError("PG_DATABASE may contain only letters, numbers, and underscores.")

    admin_user = input("PostgreSQL administrator username [postgres]: ").strip() or "postgres"
    admin_password = getpass.getpass("PostgreSQL administrator password: ")
    admin_connection = psycopg.connect(
        host=host,
        port=port,
        dbname="postgres",
        user=admin_user,
        password=admin_password,
        autocommit=True,
        connect_timeout=5,
    )
    try:
        with admin_connection.cursor() as cursor:
            cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (database_name,))
            if not cursor.fetchone():
                cursor.execute(
                    sql.SQL("CREATE DATABASE {} ENCODING 'UTF8'").format(
                        sql.Identifier(database_name)
                    )
                )

            for username, password in (
                (APP_USER, app_password),
                (MIGRATION_USER, migration_password),
            ):
                cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (username,))
                role_statement = (
                    sql.SQL("ALTER ROLE {} ").format(sql.Identifier(username))
                    if cursor.fetchone()
                    else sql.SQL("CREATE ROLE {} ").format(sql.Identifier(username))
                )
                cursor.execute(
                    role_statement
                    + sql.SQL(
                        "WITH LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB "
                        "NOCREATEROLE NOREPLICATION"
                    ).format(sql.Literal(password))
                )
                cursor.execute(
                    sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                        sql.Identifier(database_name), sql.Identifier(username)
                    )
                )
    finally:
        admin_connection.close()

    admin_database = psycopg.connect(
        host=host,
        port=port,
        dbname=database_name,
        user=admin_user,
        password=admin_password,
        connect_timeout=5,
    )
    try:
        with admin_database.cursor() as cursor:
            cursor.execute(
                sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(
                    sql.Identifier(APP_USER)
                )
            )
            cursor.execute(
                sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(
                    sql.Identifier(MIGRATION_USER)
                )
            )
        admin_database.commit()
    except Exception:
        admin_database.rollback()
        raise
    finally:
        admin_database.close()

    database_config = {
        "PG_HOST": host,
        "PG_PORT": port,
        "PG_DATABASE": database_name,
        "PG_USER": APP_USER,
        "PG_PASSWORD": app_password,
        "PG_MIGRATION_USER": MIGRATION_USER,
        "PG_MIGRATION_PASSWORD": migration_password,
    }

    migration_connection = connect(database_config, migration=True)
    try:
        init_db(migration_connection)
        with migration_connection.cursor() as cursor:
            cursor.execute(
                sql.SQL(
                    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}"
                ).format(sql.Identifier(APP_USER))
            )
            cursor.execute(
                sql.SQL("GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO {}").format(
                    sql.Identifier(APP_USER)
                )
            )
            cursor.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
                    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
                ).format(sql.Identifier(APP_USER))
            )
            cursor.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
                    "GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO {}"
                ).format(sql.Identifier(APP_USER))
            )
        migration_connection.commit()
    except Exception:
        migration_connection.rollback()
        raise
    finally:
        migration_connection.close()

    app_connection = connect(database_config)
    try:
        with app_connection.cursor() as cursor:
            cursor.execute("SELECT 1 AS verified")
            if cursor.fetchone()["verified"] != 1:
                raise RuntimeError("The application database verification failed.")
    finally:
        app_connection.close()


def main():
    if not ENV_FILE.is_file():
        raise FileNotFoundError(
            "Copy .env.example to .env before running this setup command."
        )

    config = dotenv_values(ENV_FILE)
    app_password = secrets.token_urlsafe(32)
    migration_password = secrets.token_urlsafe(32)
    secret_key = config.get("FLASK_SECRET_KEY", "")
    if len(secret_key) < 32 or secret_key == "generate-a-random-secret-with-python-secrets":
        secret_key = secrets.token_urlsafe(48)

    host = config.get("PG_HOST") or "127.0.0.1"
    port = str(config.get("PG_PORT") or "5432")
    database_name = config.get("PG_DATABASE") or "ges"
    configure_postgres(config, app_password, migration_password)
    write_env_file(
        ENV_FILE,
        {
            "PG_HOST": host,
            "PG_PORT": port,
            "PG_DATABASE": database_name,
            "PG_USER": APP_USER,
            "PG_PASSWORD": app_password,
            "PG_MIGRATION_USER": MIGRATION_USER,
            "PG_MIGRATION_PASSWORD": migration_password,
            "FLASK_SECRET_KEY": secret_key,
            "SESSION_COOKIE_SECURE": "false",
        },
    )

    print("PostgreSQL database and least-privilege users are configured.")
    print("Schema initialized; application database connection verified.")
    print("Generated credentials were saved to the ignored .env file.")
    print("Restart Flask, then verify /api/health/ready returns status ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except psycopg.Error as error:
        code = error.sqlstate or "unknown"
        print(
            f"PostgreSQL setup failed (SQLSTATE {code}). "
            "Check the PostgreSQL administrator login, service and port.",
            file=sys.stderr,
        )
        raise SystemExit(1)
