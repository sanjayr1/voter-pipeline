"""
Voter Data Ingestion Pipeline for GoodParty.org.

This DAG handles incremental, idempotent loads from the append-only voter CSV
into DuckDB. Each run:
1. Validates the CSV location and captures a file hash + quick stats.
2. Ensures the raw + metadata tables exist.
3. Branches on whether the file hash has changed since the last successful load.
4. Loads only new voter rows into DuckDB using native SQL (append-safe).
5. Triggers downstream dbt transformations (staging -> intermediate -> marts).
6. Persists ingestion metadata, including the last processed file hash.

Paths (CSV, DuckDB DB file, dbt project) default to locations under /usr/local/airflow
but should be overridden via Airflow Variables for flexibility:
- voter_csv_path
- voter_duckdb_path
- voter_dbt_project_path
- voter_dbt_profiles_dir
"""

from __future__ import annotations

import logging
import uuid
from pathlib import Path
from typing import Any, Dict

import pendulum
import duckdb
from airflow import DAG
from airflow.hooks.base import BaseHook
from airflow.models import Variable
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import BranchPythonOperator, PythonOperator
from airflow.utils.trigger_rule import TriggerRule

from utils.helpers import (
    compute_file_hash,
    count_csv_rows,
    get_last_processed_hash,
    is_new_data,
)


CSV_PATH_VAR = "voter_csv_path"
DUCKDB_PATH_VAR = "voter_duckdb_path"
DBT_PROJECT_VAR = "voter_dbt_project_path"
DBT_PROFILES_VAR = "voter_dbt_profiles_dir"

DEFAULT_CSV_PATH = "/usr/local/airflow/include/data/raw/goodparty_voters.csv"
DEFAULT_DUCKDB_PATH = "/usr/local/airflow/include/data/processed/goodparty.duckdb"
DEFAULT_DBT_PROJECT_PATH = "/usr/local/airflow/include/dbt_voter_project"

RAW_TABLE = "raw.voters"
METADATA_TABLE = "metadata.voter_ingestion_audit"
DUCKDB_CONN_ID = "duckdb_default"
CREATE_TABLES_SQL = "/usr/local/airflow/dags/sql/create_tables.sql"


def _get_duckdb_path() -> str:
    """
    Resolve the DuckDB database path from the Airflow connection or variable.
    """
    default_path = Variable.get(DUCKDB_PATH_VAR, default_var=DEFAULT_DUCKDB_PATH)
    try:
        conn = BaseHook.get_connection(DUCKDB_CONN_ID)
        return conn.host or default_path
    except Exception:
        logging.info(
            "DuckDB connection %s not found; falling back to variable path %s",
            DUCKDB_CONN_ID,
            default_path,
        )
        return default_path


def _resolve_csv_payload() -> Dict[str, Any]:
    csv_path = Variable.get(CSV_PATH_VAR, default_var=DEFAULT_CSV_PATH)
    file_hash = compute_file_hash(csv_path)
    row_count = count_csv_rows(csv_path)
    logging.info(
        "CSV %s ready for ingest. hash=%s rows=%s", csv_path, file_hash, row_count
    )
    return {"csv_path": csv_path, "file_hash": file_hash, "row_count": row_count}


def _branch_on_new_data(**context) -> str:
    payload = context["ti"].xcom_pull(task_ids="check_csv_file")
    file_hash = payload["file_hash"]
    duckdb_path = _get_duckdb_path()
    last_hash = get_last_processed_hash(duckdb_path, METADATA_TABLE)

    if is_new_data(file_hash, last_hash):
        logging.info("New data detected (old hash=%s). Continuing load.", last_hash)
        return "load_csv_to_raw"

    logging.info(
        "Hash %s already processed (last hash=%s). Skipping downstream tasks.",
        file_hash,
        last_hash,
    )
    return "no_new_data"


def _update_metadata(**context) -> None:
    payload = context["ti"].xcom_pull(task_ids="check_csv_file")
    file_hash = payload["file_hash"]
    csv_path = payload["csv_path"]
    file_row_count = payload["row_count"]
    duckdb_path = _get_duckdb_path()
    dag_run = context.get("dag_run")
    run_id = dag_run.run_id if dag_run else None

    with duckdb.connect(database=duckdb_path) as conn:
        inserted_rows = conn.execute(
            f"SELECT COUNT(*) FROM {RAW_TABLE} WHERE source_file_hash = ?",
            (file_hash,),
        ).fetchone()[0]

        conn.execute(
            f"""
            INSERT INTO {METADATA_TABLE} (
                ingestion_id,
                file_hash,
                source_path,
                file_row_count,
                inserted_row_count,
                load_status,
                dag_run_id,
                ingested_at
            )
            VALUES (
                CAST(? AS UUID),
                ?,
                ?,
                ?,
                ?,
                ?,
                ?,
                now()
            )
            """,
            (
                str(uuid.uuid4()),
                file_hash,
                csv_path,
                file_row_count,
                inserted_rows,
                "success" if inserted_rows else "no-op",
                run_id,
            ),
        )

    logging.info(
        "Recorded ingestion metadata for hash %s (inserted_rows=%s).",
        file_hash,
        inserted_rows,
    )


def _create_tables() -> None:
    duckdb_path = _get_duckdb_path()
    sql_path = Path(CREATE_TABLES_SQL)
    if not sql_path.exists():
        raise FileNotFoundError(f"Create tables SQL not found at {CREATE_TABLES_SQL}")

    script = sql_path.read_text(encoding="utf-8")
    with duckdb.connect(database=duckdb_path) as conn:
        for statement in script.split(";"):
            stmt = statement.strip()
            if stmt:
                conn.execute(stmt)
    logging.info("Ensured raw + metadata tables exist at %s", duckdb_path)


def _load_csv_to_raw(**context) -> None:
    payload = context["ti"].xcom_pull(task_ids="check_csv_file")
    csv_path = payload["csv_path"]
    file_hash = payload["file_hash"]

    duckdb_path = _get_duckdb_path()
    with duckdb.connect(database=duckdb_path) as conn:
        conn.execute(
            """
            CREATE TEMP TABLE staged_voters AS
            SELECT
                id,
                first_name,
                last_name,
                age,
                gender,
                state,
                party,
                email,
                registered_date,
                last_voted_date,
                updated_at,
                now() AS load_timestamp,
                ? AS source_file_hash
            FROM read_csv_auto(
                ?,
                header=TRUE
            )
            """,
            (file_hash, csv_path),
        )

        conn.execute(
            f"""
            CREATE TEMP TABLE incremental_voters AS
            SELECT *
            FROM staged_voters sv
            WHERE NOT EXISTS (
                SELECT 1
                FROM {RAW_TABLE} rv
                WHERE rv.id = sv.id
            )
            """
        )

        inserted_rows = conn.execute(
            "SELECT COUNT(*) FROM incremental_voters"
        ).fetchone()[0]

        if inserted_rows:
            conn.execute(
                f"""
                INSERT INTO {RAW_TABLE}
                SELECT * FROM incremental_voters
                """
            )

    logging.info(
        "Loaded %s new voter rows from %s using hash %s",
        inserted_rows,
        csv_path,
        file_hash,
    )


with DAG(
    dag_id="voter_ingestion_dag",
    description="Incremental voter ingestion into DuckDB + dbt refresh",
    schedule="@daily",
    start_date=pendulum.datetime(2024, 1, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    default_args={"owner": "goodparty-data", "retries": 1},
    tags=["goodparty", "duckdb", "dbt"],
    doc_md=__doc__,
) as dag:
    check_csv_file = PythonOperator(
        task_id="check_csv_file",
        python_callable=_resolve_csv_payload,
    )

    create_raw_tables = PythonOperator(
        task_id="create_raw_tables",
        python_callable=_create_tables,
    )

    check_for_new_data = BranchPythonOperator(
        task_id="check_for_new_data",
        python_callable=_branch_on_new_data,
    )

    no_new_data = EmptyOperator(task_id="no_new_data")

    load_csv_to_raw = PythonOperator(
        task_id="load_csv_to_raw",
        python_callable=_load_csv_to_raw,
    )

    trigger_dbt_run = BashOperator(
        task_id="trigger_dbt_run",
        bash_command="""
        set -euo pipefail
        : "${DBT_PROJECT_DIR:?Set voter_dbt_project_path Airflow Variable or env}"
        : "${DBT_PROFILES_DIR:?Set voter_dbt_profiles_dir Airflow Variable or env}"
        cd "${DBT_PROJECT_DIR}"
        dbt deps --quiet
        dbt run --select staging.* intermediate.* marts.*
        """,
        env={
            "DBT_PROJECT_DIR": "{{ var.value.get('"
            + DBT_PROJECT_VAR
            + "', '"
            + DEFAULT_DBT_PROJECT_PATH
            + "') }}",
            "DBT_PROFILES_DIR": "{{ var.value.get('"
            + DBT_PROFILES_VAR
            + "', '"
            + DEFAULT_DBT_PROJECT_PATH
            + "') }}",
        },
    )

    update_metadata = PythonOperator(
        task_id="update_metadata",
        python_callable=_update_metadata,
    )

    finish = EmptyOperator(
        task_id="pipeline_complete",
        trigger_rule=TriggerRule.NONE_FAILED_MIN_ONE_SUCCESS,
    )

    (
        check_csv_file
        >> create_raw_tables
        >> check_for_new_data
        >> [no_new_data, load_csv_to_raw]
    )
    load_csv_to_raw >> trigger_dbt_run >> update_metadata >> finish
    no_new_data >> finish
