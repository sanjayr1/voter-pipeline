# Voter Data Pipeline

Operationalizes the GoodParty.org voter CSV into repeatable analytics using Astronomer's Astro CLI, DuckDB, dbt, and a Streamlit dashboard. Reviewers can spin up the full stack (Airflow + dbt + dashboard) with a single, validated workflow.

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

### Setup
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
make dashboard        # wraps ./dashboard/run.sh (http://localhost:8501)
```

Stop Airflow any time with `make astro-stop`. Run `make demo` to execute the full flow (start Airflow, refresh data, trigger DAG) in one go.

## 🧰 Helpful Make Targets
Run `make help` to list all commands. Highlights:

- `make check-prereqs` – verifies Docker + Astro availability.
- `make download-data` – pulls the latest voter CSV (https://gist.github.com/hhkarimi/...).
- `make run-pipeline` – runs the configured DAG via `astro dev run`.
- `make dashboard` – launches Streamlit via `dashboard/run.sh` (auto handles deps/locks).
- `make dashboard-build` – installs `dashboard/requirements.txt` into the active env.
- `make dashboard-dev` – runs Streamlit with auto-reload for rapid iteration.
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

Variables for CSV, DuckDB, and dbt paths are pre-seeded via `airflow/airflow_settings.yaml` when you run `make astro-start`. Only edit them (UI: Admin → Variables or CLI: `astro dev run airflow variables set <key> <value>`) if you want to experiment with alternate locations:

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

Install the DuckDB CLI if you don’t already have it (`brew install duckdb` on macOS). After a DAG run completes, inspect the warehouse directly from the repo root:

```bash
duckdb airflow/include/data/processed/goodparty.duckdb "
  
  select count(*) as raw_voter_rows from raw.voters;

  select ingestion_id, file_hash, load_status, inserted_row_count, ingested_at
  from metadata.voter_ingestion_audit
  order by ingested_at desc
  limit 5;
"
```

You should see the total number of raw voters and the latest audit record (`success` for new hashes, `no-op` when the DAG short-circuits). Append a new row to the CSV and re-trigger the DAG to watch the delta insert show up in both queries.

---

## 🧱 dbt Transformation Layers

`dbt_voter_project` materializes the shared DuckDB database into clean analytics schemas (`staging`, `intermediate`, `marts`). Model-level defaults live in `dbt_project.yml`, and the project depends on `dbt_utils==1.3.2`.

### Model inventory
- `staging.stg_voters`: trims/casts raw fields and carries ingestion metadata.
- `intermediate.int_voters_cleaned`: validates ages via `min_voter_age`/`max_voter_age`, normalizes gender, state, and email fields, parses flexible dates, and emits quality flags (`has_missing_data`, `has_invalid_age`, `is_valid_email`).
- `marts.analytics.voter_state_summary`: state-level population, turnout windows, and party mix.
- `marts.analytics.voter_party_distribution`: party headcounts with age bands and recent activity.
- `marts.analytics.voter_engagement_metrics`: cohort + recency segmentation with an engagement score.
- `marts.analytics.demographic_crosstab`: generation × gender × party coverage (filters out tiny slices).
- `marts.analytics.registration_trends`: monthly registrations since 2015 with cumulative counts + moving averages.
- `marts.data_quality.dq_summary`: end-to-end record counts plus invalid-age/email/missing-data tallies.

### Custom macros & tests
- `standardize_state(column)` – exhaustive USPS + DC mapping for messy free-text states.
- `validate_email(column)` – guards against obviously malformed addresses.
- `parse_flexible_date(column)` – handles ISO strings and `MM/DD/YYYY HH:MM:SS`.
- `tests/generic/not_future_date` – reusable helper to fail if dates drift too far forward.
- Schema tests leverage `dbt_utils` (accepted range, equal rowcount, recency) to monitor freshness and value bounds.

### Running dbt locally (outside Astro)
```bash
cd voter-pipeline/dbt_voter_project
DBT_PROFILES_DIR=. dbt deps && \
DBT_PROFILES_DIR=. dbt run && \
DBT_PROFILES_DIR=. dbt test
```
`profiles.yml` targets `../data/processed/goodparty.duckdb`, so your local CLI shares the same warehouse as the Streamlit dashboard. The current sample data surfaces two WARN-level tests (missing state codes and registration activity older than 30 days); they’re documented data-quality issues and safe to ignore for demo runs.

### Running dbt inside the Astro containers (optional)
The Airflow DAG copies the dbt repo into `/usr/local/airflow/include/dbt_voter_project` and invokes it after ingestion. Run the same commands inside the scheduler container if you need to debug in-place:
```bash
astro dev run scheduler bash -lc "
  cd /usr/local/airflow/include/dbt_voter_project &&
  dbt deps &&
  dbt run &&
  dbt test
"
```

### Spot-checking mart outputs
```bash
duckdb airflow/include/data/processed/goodparty.duckdb "
  
  select * from main_intermediate.voters_cleaned limit 5;
  
  select state_code, total_voters, democrat_pct, republican_pct
  from main_marts.voter_state_summary
  order by total_voters desc;
  
  select registration_month, new_registrations, moving_avg_registrations
  from main_marts.registration_trends
  order by registration_month desc
  limit 6;
"
```
Combine these checks with `dbt test` to confirm data-quality logic before demoing or iterating on downstream layers.

---

## 📊 Streamlit Dashboard

Launch the visualization layer once the dbt marts have data. The helper `make dashboard` target calls `dashboard/run.sh`, which handles dependency installation, DuckDB path detection, and read-only snapshotting if another process (e.g., the DuckDB CLI) locks the file.

```bash
# from repo root
source .venv/bin/activate               # reuse the virtualenv from make setup
make dashboard                          # opens http://localhost:8501
```

Want to run the script manually? `./dashboard/run.sh` exposes the same functionality. Its behavior:
- Prefers the repo’s `airflow/include/data/processed/goodparty.duckdb`. Override by exporting `DUCKDB_PATH=/path/to/warehouse.duckdb` before running.
- Automatically installs `dashboard/requirements.txt` into the active environment if packages are missing.
- Falls back to a temporary snapshot when the primary DuckDB file is locked, so you can keep a CLI session open without killing Streamlit.
- Exposes an optional `DBT_MART_SCHEMA` env var (defaults to `main_marts`) if you want to point at a different mart schema.

Prefer a manual launch? `streamlit run dashboard/app.py` works too—just be sure `DUCKDB_PATH` points at the warehouse.

### What reviewers should look for
- **Overview tab** – Total voter counts, party split, and engagement cohorts from `main_marts.voter_engagement_metrics`.
- **Geographic tab** – Top states + party distribution charts powered by `main_marts.voter_state_summary`.
- **Demographics tab** – Generation/gender/party cross-tabs sourced entirely from `main_marts.demographic_crosstab`.
- **Trends tab** – Moving averages, cumulative growth, and party-specific registration trajectories from `main_marts.registration_trends`.
- **Data Quality tab** – Metric cards + gauge fed by `main_marts.dq_summary`. All deltas/percentages map back to the SQL logic in that mart.

### SQL snippets for data-quality investigations
Run these against the DuckDB file (e.g., `duckdb airflow/include/data/processed/goodparty.duckdb`) to see the exact records behind the dashboard metrics:

```sql
-- Rows with missing critical fields
select voter_id, first_name, last_name, state_code, age, email, load_timestamp
from main_intermediate.int_voters_cleaned
where has_missing_data
order by voter_id;

-- Invalid ages (outside {{ var('min_voter_age') }}-{{ var('max_voter_age') }})
select voter_id, age, first_name, last_name, state_code, has_invalid_age
from main_intermediate.int_voters_cleaned
where has_invalid_age
order by voter_id;

-- Invalid emails caught by validate_email()
select voter_id, email, first_name, last_name, state_code
from main_intermediate.int_voters_cleaned
where not is_valid_email
order by voter_id;
```

Use the same connection to spot-check mart outputs that feed each Streamlit page, ensuring reviewers can tie every visualization back to its SQL source.

---

## 🎬 Demo Run Playbook

Use this checklist to rehearse (or let reviewers reproduce) the full workflow on a clean machine:

1. **Clone + bootstrap**
   ```bash
   git clone <repo> voter-pipeline && cd voter-pipeline
   make setup                              # installs Astro, .venv, downloads CSV, seeds DuckDB
   ```
2. **Run dbt locally (sanity check)**
   ```bash
   cd dbt_voter_project
   DBT_PROFILES_DIR=. dbt deps && \
   DBT_PROFILES_DIR=. dbt run && \
   DBT_PROFILES_DIR=. dbt test
   cd ..
   ```
   Expect two WARN-level tests (missing state codes, stale registrations); both reflect known data quality gaps.
3. **Sync assets into Astro mounts**
   ```bash
   mkdir -p airflow/include/data/raw airflow/include/data/processed airflow/include/dbt_voter_project
   cp data/raw/goodparty_voters.csv airflow/include/data/raw/
   cp data/processed/goodparty.duckdb airflow/include/data/processed/
   rsync -av dbt_voter_project/ airflow/include/dbt_voter_project/
   ```
4. **Start Airflow + trigger the DAG**
   ```bash
   make astro-stop          # safe even if not running
   make astro-start         # wait for http://localhost:8080 to go healthy
   make run-pipeline        # equivalent to clicking “Run” on voter_ingestion_dag
   ```
   The DAG hashes/loads the CSV, runs dbt inside the scheduler container, and logs the audit row.
5. **Spot-check DuckDB outputs**
   ```bash
   duckdb airflow/include/data/processed/goodparty.duckdb "
     
     select count(*) as raw_rows from raw.voters;
     
     select * from metadata.voter_ingestion_audit order by ingested_at desc limit 3;
     
     select state_code, total_voters, democrat_pct, republican_pct
       from main_marts.voter_state_summary
       order by total_voters desc;
     
     select party, total_voters, age_18_29, active_voters_2024
       from main_marts.voter_party_distribution;
     
     select registration_month, new_registrations, moving_avg_registrations
       from main_marts.registration_trends
       order by registration_month desc limit 6;
   "
   ```
   These queries confirm ingestion counts, metadata logging, and that dbt populated each mart schema.

Restart Astro (`make astro-stop && make astro-start`) whenever you change DAG code or requirements. Run `duckdb ... delete from raw.voters; delete from metadata.voter_ingestion_audit;` between demos if you want to showcase a fresh ingestion.

---

## 📓 Notes for Reviewers
- Set `DATA_URL` when invoking `make download-data` if you want to test with an alternate dataset.
- `scripts/setup.sh` creates `.venv/` at the repo root; activate it for any local CLI work (`source .venv/bin/activate`).
- dbt is configured to write to `data/processed/goodparty.duckdb` when you run it locally (outside Astro). The Airflow containers point to the mirrored copy at `/usr/local/airflow/include/data/processed/goodparty.duckdb`, so keep `airflow/include/data/processed/` in sync with `data/processed/` when moving files between environments.
- Airflow DAGs live in `airflow/dags/` inside the Astro project. Use `astro dev restart` after adding DAGs to rebuild the container if requirements change.

Enjoy exploring the voter pipeline!
