# Voter Data Pipeline

Operationalizes the GoodParty.org voter CSV into repeatable analytics using Astronomer's Astro CLI, DuckDB, dbt, and a Streamlit dashboard. Reviewers can spin up the full stack (Airflow + dbt + dashboard) with a couple of commands or run the dashboard-only experience without Docker.

---

## 🔧 Tech Highlights
- **Airflow via Astro** – containerized orchestration with local UI and scheduler.
- **DuckDB + dbt** – lightweight warehouse plus modular transformations.
- **Streamlit dashboard** – quick visualization layer for demos.
- **Smart bootstrap script** – `scripts/setup.sh` checks prerequisites, downloads data, initializes Astro/dbt, and installs pinned Python deps inside `.venv/`.

Repository layout:
```
airflow/            # Astro project (DAGs, Dockerfile, requirements)
data/raw            # Ingested CSV (downloaded automatically)
data/processed      # DuckDB files + analytics outputs
dbt_voter_project/  # dbt project + DuckDB profile
dashboard/          # Streamlit app + requirements
scripts/            # setup.sh, future helper scripts
```

---

## 🚀 Quick Start

### Prerequisites
- macOS/Linux with Docker Desktop running (4 GB RAM free recommended)
- Python 3.9+ (used to host the local virtual environment)
- Git + Homebrew (for Astro installation)

### Option A – Full Stack via Astro CLI (Recommended)
```bash
# 1. Clone and enter the repo
git clone <your repo url> voter-pipeline
cd voter-pipeline

# 2. (Optional) Install Astro CLI helper
make install-astro

# 3. One-time setup: checks Docker/Astro, creates .venv, downloads CSV, inits dbt
make setup        # wraps scripts/setup.sh

# 4. Launch Airflow locally (builds the Astro image with requirements)
make astro-start  # Airflow UI: http://localhost:8080  (admin / admin)

# 5. Trigger the DAG (defaults to voter_ingestion_dag; override with DAG_ID=your_dag if needed)
make run-pipeline

# 6. Explore the Streamlit dashboard in another terminal
source .venv/bin/activate
make dashboard    # Dashboard: http://localhost:8501
```

Stop Airflow any time with `make astro-stop`. Run `make demo` to execute the full flow (start Airflow, refresh data, trigger DAG) in one go.

### Option B – Quick Local Demo (No Docker)
For reviewers who mainly want to inspect the data transformations and dashboard without spinning up Airflow:
```bash
git clone <your repo url> voter-pipeline
cd voter-pipeline

# Bootstrap tooling, DuckDB, and the dashboard environment (prompts can be skipped with AUTO_CONFIRM=1)
AUTO_CONFIRM=1 scripts/setup.sh
source .venv/bin/activate

# Use dbt/duckdb locally (optional)
cd dbt_voter_project
DBT_PROFILES_DIR=. dbt deps   # when models are added
DBT_PROFILES_DIR=. dbt run

# Launch the Streamlit dashboard
cd ..
streamlit run dashboard/app.py
```

---

## 🧰 Helpful Make Targets
Run `make help` to list all commands. Highlights:

- `make check-prereqs` – verifies Docker + Astro availability.
- `make download-data` – pulls the latest voter CSV (https://gist.github.com/hhkarimi/...).
- `make run-pipeline` – runs the configured DAG via `astro dev run`.
- `make demo` – orchestrates startup, data download, and DAG trigger for interview demos.
- `make clean` – removes generated data, DuckDB files, and Astro logs.

---

## 🗳️ Airflow DAG: Voter Ingestion

`airflow/dags/voter_ingestion_dag.py` orchestrates the end-to-end ingestion of `data/raw/goodparty_voters.csv` into DuckDB and then runs the dbt project. The DAG:
- hashes the source file, counts rows, and short-circuits via `BranchPythonOperator` if nothing changed.
- creates raw + metadata tables from `airflow/dags/sql/create_tables.sql`.
- loads only unseen voter IDs via DuckDB SQL executed inside a Python task, tagging each row with `load_timestamp` and `source_file_hash`.
- runs `dbt` (staging → intermediate → marts) and logs the run inside `metadata.voter_ingestion_audit`.

### Configure paths via Airflow Variables

Set these (UI: Admin → Variables or CLI: `astro dev run airflow variables set <key> <value>`). They’re pre-populated for local development through `airflow/airflow_settings.yaml`, so running `make astro-start` seeds them automatically—update the YAML or the UI if you want to point at different locations:

| Variable | Purpose | Suggested value |
|----------|---------|-----------------|
| `voter_csv_path` | Location of the append-only CSV inside the Astro containers | `/usr/local/airflow/include/data/raw/goodparty_voters.csv` |
| `voter_duckdb_path` | DuckDB file that Airflow + dbt share | `/usr/local/airflow/include/data/processed/goodparty.duckdb` |
| `voter_dbt_project_path` | Path to the dbt repo | `/usr/local/airflow/include/dbt_voter_project` |
| `voter_dbt_profiles_dir` | Profiles directory for dbt | Same as project path (unless you split profiles) |

Tip: after `make download-data`, copy artefacts into the Astro mount so containers can reach them:

```bash
mkdir -p airflow/include/data/raw airflow/include/data/processed
cp data/raw/goodparty_voters.csv airflow/include/data/raw/
rsync -av dbt_voter_project/ airflow/include/dbt_voter_project/
```

### DuckDB connection

`airflow/airflow_settings.yaml` also seeds a connection named `duckdb_default` (Conn Type: DuckDB, Host: `/usr/local/airflow/include/data/processed/goodparty.duckdb`). The DAG reads this connection first (and only falls back to the Variable if it’s missing), which keeps Airflow, dbt, and ad-hoc queries perfectly aligned on the same DuckDB file.

### Running the pipeline

1. `make astro-start`
2. Ensure the Airflow Variables above are set (or use the defaults shown).
3. Trigger the DAG from the UI (`voter_ingestion_dag`) or via `make run-pipeline`.

Because the DAG tracks `source_file_hash`, rerunning a day with the same CSV results in a clean no-op branch; new hashes load only the delta rows and remain idempotent even if tasks retry mid-way.

### Validate ingestion results

Install the DuckDB CLI if you don’t already have it (`brew install duckdb` on macOS). After a DAG run completes, you can inspect the warehouse directly from the repo root:

```bash
duckdb airflow/include/data/processed/goodparty.duckdb "
  select count(*) as raw_voter_rows from raw.voters;
  select ingestion_id, file_hash, load_status, inserted_row_count, ingested_at
  from metadata.voter_ingestion_audit
  order by ingested_at desc
  limit 5;
"
```

Alternatively, run the same SQL inside the scheduler container:

```bash
astro dev run scheduler bash -c "
duckdb /usr/local/airflow/include/data/processed/goodparty.duckdb \"
  select count(*) as raw_voter_rows from raw.voters;
  select ingestion_id, file_hash, load_status, inserted_row_count, ingested_at
  from metadata.voter_ingestion_audit
  order by ingested_at desc
  limit 5;
\"
"
```

You should see the total number of raw voters and the latest audit record (`success` for new hashes, `no-op` when the DAG short-circuits). Append a new row to the CSV and re-trigger the DAG to watch the delta insert show up in both queries.

---

## 📓 Notes for Reviewers
- Set `DATA_URL` when invoking `make download-data` if you want to test with an alternate dataset.
- `scripts/setup.sh` creates `.venv/` at the repo root; activate it for any local CLI work (`source .venv/bin/activate`).
- dbt is configured to write to `data/processed/goodparty.duckdb` when you run it locally (outside Astro). The Airflow containers point to the mirrored copy at `/usr/local/airflow/include/data/processed/goodparty.duckdb`, so keep `airflow/include/data/processed/` in sync with `data/processed/` when moving files between environments.
- Airflow DAGs live in `airflow/dags/` inside the Astro project. Use `astro dev restart` after adding DAGs to rebuild the container if requirements change.

Enjoy exploring the voter pipeline!
