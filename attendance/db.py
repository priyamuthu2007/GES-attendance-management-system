from pathlib import Path

import pymysql
from flask import current_app, g
from pymysql.cursors import DictCursor


def connect(config, migration=False):
    use_migration_account = migration
    username = (
        config["MYSQL_MIGRATION_USER"] if use_migration_account else config["MYSQL_USER"]
    )
    password = (
        config["MYSQL_MIGRATION_PASSWORD"]
        if use_migration_account
        else config["MYSQL_PASSWORD"]
    )
    return pymysql.connect(
        host=config["MYSQL_HOST"],
        port=config["MYSQL_PORT"],
        user=username,
        password=password,
        database=config["MYSQL_DATABASE"],
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=False,
        connect_timeout=5,
        read_timeout=10,
        write_timeout=10,
    )


def get_connection():
    if "mysql_connection" not in g:
        g.mysql_connection = connect(current_app.config)
    return g.mysql_connection


def close_db(_error=None):
    connection = g.pop("mysql_connection", None)
    if connection is not None:
        connection.close()


def init_db(connection=None):
    schema = Path(__file__).with_name("schema.sql").read_text(encoding="utf-8")
    connection = connection or get_connection()
    try:
        with connection.cursor() as cursor:
            for statement in schema.split(";"):
                if statement.strip():
                    cursor.execute(statement)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
