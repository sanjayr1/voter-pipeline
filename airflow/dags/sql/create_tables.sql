-- Raw schema mirrors the CSV exactly so dbt can surface type issues
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS metadata;

CREATE TABLE IF NOT EXISTS raw.voters (
    id VARCHAR,
    first_name VARCHAR,
    last_name VARCHAR,
    age VARCHAR,
    gender VARCHAR,
    state VARCHAR,
    party VARCHAR,
    email VARCHAR,
    registered_date VARCHAR,
    last_voted_date VARCHAR,
    updated_at VARCHAR,
    load_timestamp TIMESTAMPTZ,
    source_file_hash VARCHAR,
    CONSTRAINT voters_pk PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_raw_voters_id ON raw.voters (id);

CREATE TABLE IF NOT EXISTS metadata.voter_ingestion_audit (
    ingestion_id UUID PRIMARY KEY,
    file_hash VARCHAR NOT NULL,
    source_path VARCHAR NOT NULL,
    file_row_count BIGINT NOT NULL,
    inserted_row_count BIGINT NOT NULL,
    load_status VARCHAR NOT NULL,
    dag_run_id VARCHAR,
    ingested_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_voter_ingestion_file_hash
    ON metadata.voter_ingestion_audit (file_hash);
