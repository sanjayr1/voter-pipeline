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
# Then activate the virtual environment - 
source .venv/bin/activate

# 4. Stage shared assets so Airflow can read them (run before starting Airflow)
make copy-data

# 5. Launch Airflow locally (builds the Astro image with requirements)
make astro-start  # Airflow UI: http://localhost:8080  (admin / admin)

# 6. You will need to unpause the voter_ingestion_dag in the UI. 
#    At this point, the DAG should auto run as it is scheduled, 
#    but if it doesn't due to the time, feel free to manually 
#    trigger the DAG from the Airflow UI.
#
#    Click the play button next to voter_ingestion_dag. Re-run `make copy-data`
#    any time you modify `data/` or the dbt project.
#
#    Side note: if you rerun the DAG, you will hit the 2nd branch 
#               path (no_new_data), so feel free to play with that
#               as well to see the idempotent behavior. 

# 7. Explore the Streamlit dashboard in another terminal
source .venv/bin/activate
make dashboard        # wraps ./dashboard/run.sh (http://localhost:8501)
```

Stop Airflow any time with `make astro-stop`. 

## 🧰 Helpful Make Targets
Run `make help` to list all commands. Highlights:

- `make check-prereqs` – verifies Docker + Astro availability.
- `make download-data` – pulls the latest voter CSV (https://gist.github.com/hhkarimi/...).
- `make copy-data` – mirrors `data/` + `dbt_voter_project/` into `airflow/include/` so the Astro containers can read them.
- `make dashboard` – launches Streamlit via `dashboard/run.sh` (auto handles deps/locks).
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

Use `make copy-data` to mirror `data/` + the dbt project into `airflow/include`, which is mounted into the Astro containers at `/usr/local/airflow/include`. Run it any time you plan to trigger the DAG (and rerun after editing `data/` or `dbt_voter_project/`).

### DuckDB connection

`airflow/airflow_settings.yaml` also seeds a connection named `duckdb_default` (Conn Type: DuckDB, Host: `/usr/local/airflow/include/data/processed/goodparty.duckdb`). The DAG reads this connection first (and only falls back to the Variable if it’s missing), which keeps Airflow, dbt, and ad-hoc queries perfectly aligned on the same DuckDB file.

### Running the pipeline

1. Run `make copy-data` (ideally before starting Airflow) so the scheduler has access to the CSV + dbt project as soon as it spins up.
2. `make astro-start`
3. Ensure the Airflow Variables above are set (or use the defaults shown).
4. Trigger the DAG from the Airflow UI (`voter_ingestion_dag` → Play → Trigger). Re-run `make copy-data` before each trigger if you edit the data/dbt assets.

Because the DAG tracks `source_file_hash`, rerunning a day with the same CSV results in a clean no-op branch; new hashes load only the delta rows and remain idempotent even if tasks retry mid-way. Airflow limits the DAG to one active run at a time, so wait for the prior run to finish (or pause the DAG) before triggering again.

### Validate ingestion results

Install the DuckDB CLI if you don’t already have it (`brew install duckdb` on macOS). After a DAG run completes, inspect the warehouse directly from the repo root. All Airflow/dbt writes land in `airflow/include/data/processed/goodparty.duckdb`; run queries against that file (or copy it back to `data/processed/` if you want to keep the legacy path in sync):

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

> If the Streamlit dashboard is running (`make dashboard`), DuckDB may be locked for writes. Stop the dashboard with `Ctrl+C` before connecting, or use `duckdb -readonly airflow/include/data/processed/goodparty.duckdb` to inspect tables without taking down the UI.

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
`profiles.yml` targets `../airflow/include/data/processed/goodparty.duckdb`, so your local CLI shares the same warehouse that Airflow/dbt use inside the containers. The current sample data surfaces two WARN-level tests (missing state codes and registration activity older than 30 days); they’re documented data-quality issues and safe to ignore for demo runs.

> Tip: close the DuckDB CLI (`.exit`) and stop the Streamlit dashboard before running dbt, or use read-only connections elsewhere. DuckDB enforces a single writer lock, so lingering sessions can block `dbt run`/`dbt test`.

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
  
  select party, total_voters, age_18_29, active_voters_2024
    from main_marts.voter_party_distribution;
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
from main_intermediate.voters_cleaned
where has_missing_data
order by voter_id;

-- Invalid ages (outside {{ var('min_voter_age') }}-{{ var('max_voter_age') }})
select voter_id, age, first_name, last_name, state_code, has_invalid_age
from main_intermediate.voters_cleaned
where has_invalid_age
order by voter_id;

-- Invalid emails caught by validate_email()
select voter_id, email, first_name, last_name, state_code
from main_intermediate.voters_cleaned
where not is_valid_email
order by voter_id;
```
---

## 📓 Notes for Reviewers
- Set `DATA_URL` when invoking `make download-data` if you want to test with an alternate dataset.
- `scripts/setup.sh` creates `.venv/` at the repo root; activate it for any local CLI work (`source .venv/bin/activate`).
- dbt is configured to write directly to `airflow/include/data/processed/goodparty.duckdb` when you run it locally. Run `make copy-data` whenever you need the Airflow containers to pick up the latest DuckDB/dbt changes. If you want to inspect the updated warehouse via `data/processed/`, copy it back after a run (`cp airflow/include/data/processed/goodparty.duckdb data/processed/goodparty.duckdb`).
- Airflow DAGs live in `airflow/dags/` inside the Astro project. Use `astro dev restart` after adding DAGs to rebuild the container if requirements change.

Enjoy exploring the voter pipeline!
