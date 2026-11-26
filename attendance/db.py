from pathlib import Path
from queue import Empty, Full, LifoQueue

import psycopg
from flask import current_app, g
from psycopg.rows import dict_row

POOL_SIZE = 10


def connect(config, migration=False):
    username = config["PG_MIGRATION_USER"] if migration else config["PG_USER"]
    password = config["PG_MIGRATION_PASSWORD"] if migration else config["PG_PASSWORD"]
    return psycopg.connect(
        host=config["PG_HOST"],
        port=config["PG_PORT"],
        user=username,
        password=password,
        dbname=config["PG_DATABASE"],
        row_factory=dict_row,
        autocommit=False,
        connect_timeout=5,
    )


def get_connection():
<<<<<<< HEAD
    if "postgres_connection" not in g:
        g.postgres_connection = connect(current_app.config)
    return g.postgres_connection


def close_db(_error=None):
    connection = g.pop("postgres_connection", None)
    if connection is not None:
=======
    if "mysql_connection" not in g:
        pool = current_app.extensions.setdefault(
            "mysql_connection_pool", LifoQueue(maxsize=POOL_SIZE)
        )
        while True:
            try:
                connection = pool.get_nowait()
            except Empty:
                connection = connect(current_app.config)
                break
            try:
                connection.ping(reconnect=False)
                break
            except pymysql.MySQLError:
                current_app.logger.info(
                    "Discarding a stale pooled MySQL connection.", exc_info=True
                )
                connection.close()
        g.mysql_connection = connection
    return g.mysql_connection


def close_db(_error=None):
    connection = g.pop("mysql_connection", None)
    if connection is None:
        return
    try:
        connection.rollback()
        connection.ping(reconnect=False)
    except pymysql.MySQLError:
        current_app.logger.warning(
            "Discarding an unhealthy pooled MySQL connection.", exc_info=True
        )
        connection.close()
        return

    pool = current_app.extensions["mysql_connection_pool"]
    try:
        pool.put_nowait(connection)
    except Full:
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
        connection.close()


def init_db(connection=None):
    schema = Path(__file__).with_name("schema.sql").read_text(encoding="utf-8")
    connection = connection or get_connection()
    try:
        with connection.cursor() as cursor:
            for statement in schema.split(";"):
                if statement.strip():
                    cursor.execute(statement)
            cursor.execute(
                """SELECT COLUMN_NAME, IS_NULLABLE
                   FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'attendance'"""
            )
            attendance_columns = {
                row["COLUMN_NAME"]: row["IS_NULLABLE"] for row in cursor.fetchall()
            }
            for column in (
                "check_in_latitude",
                "check_in_longitude",
                "check_in_accuracy_meters",
                "check_in_distance_meters",
            ):
                if attendance_columns.get(column) == "NO":
                    cursor.execute(f"ALTER TABLE attendance MODIFY {column} DOUBLE NULL")
            for column, definition in (
                ("check_in_source", "VARCHAR(24) NOT NULL DEFAULT 'gps'"),
                ("check_out_source", "VARCHAR(24) NULL"),
            ):
                if column not in attendance_columns:
                    cursor.execute(f"ALTER TABLE attendance ADD COLUMN {column} {definition}")
            for table, index_name in (
                ("employees", "employees_email_unique"),
                ("managers", "managers_email_unique"),
            ):
                cursor.execute(
                    """SELECT COLUMN_NAME FROM information_schema.COLUMNS
                       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s
                         AND COLUMN_NAME = 'email'""",
                    (table,),
                )
                if not cursor.fetchone():
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN email VARCHAR(254) NULL")
                cursor.execute(
                    """SELECT INDEX_NAME FROM information_schema.STATISTICS
                       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s
                         AND COLUMN_NAME = 'email' AND NON_UNIQUE = 0""",
                    (table,),
                )
                if not cursor.fetchone():
                    cursor.execute(
                        f"ALTER TABLE {table} ADD UNIQUE KEY {index_name} (email)"
                    )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
