"""
Utility helpers shared by the voter ingestion DAG.
"""

from __future__ import annotations

import hashlib
import logging
from pathlib import Path
from typing import Optional, Tuple

import duckdb


def compute_file_hash(file_path: str, chunk_size: int = 1024 * 1024) -> str:
    """
    Return the SHA256 hash for a file without loading the full contents into memory.
    """
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"CSV not found at {file_path}")

    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    logging.info("Calculated hash %s for %s", digest, file_path)
    return digest


def count_csv_rows(file_path: str) -> int:
    """
    Count the number of data rows in the CSV (excludes the header).
    """
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"CSV not found at {file_path}")

    with path.open("r", encoding="utf-8") as handle:
        row_count = sum(1 for _ in handle) - 1  # subtract header
    if row_count < 0:
        row_count = 0
    logging.info("Quick row count for %s: %s rows", file_path, row_count)
    return row_count


def get_last_processed_hash(
    database_path: str, metadata_table: str
) -> Optional[str]:
    """
    Return the most recent file hash recorded in the metadata table, if any.
    """
    schema, table = _split_table(metadata_table)
    with duckdb.connect(database=database_path) as conn:
        exists = conn.execute(
            """
            SELECT COUNT(*) > 0
            FROM information_schema.tables
            WHERE table_schema = ?
              AND table_name = ?
            """,
            (schema, table),
        ).fetchone()[0]

        if not exists:
            logging.info(
                "Metadata table %s does not exist yet; treating as first load.",
                metadata_table,
            )
            return None

        result = conn.execute(
            f"""
            SELECT file_hash
            FROM {metadata_table}
            ORDER BY ingested_at DESC
            LIMIT 1
            """
        ).fetchone()

    last_hash = result[0] if result else None
    logging.info("Last processed hash: %s", last_hash)
    return last_hash


def is_new_data(current_hash: str, last_hash: Optional[str]) -> bool:
    """
    Determine whether the current file hash represents new work.
    """
    return last_hash is None or current_hash != last_hash


def _split_table(table_identifier: str) -> Tuple[str, str]:
    if "." in table_identifier:
        schema, table = table_identifier.split(".", 1)
    else:
        schema, table = "main", table_identifier
    return schema, table

