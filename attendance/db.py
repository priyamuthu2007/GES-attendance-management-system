from pathlib import Path

import psycopg
from flask import current_app, g
from psycopg.rows import dict_row


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
    if "postgres_connection" not in g:
        g.postgres_connection = connect(current_app.config)
    return g.postgres_connection


def close_db(_error=None):
    connection = g.pop("postgres_connection", None)
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
