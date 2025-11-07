# Voter Data Pipeline

Operationalizes the GoodParty.org voter CSV into repeatable analytics using Astronomer's Astro CLI, DuckDB, dbt, and a Streamlit dashboard. Reviewers can spin up the full stack (Airflow + dbt + dashboard) with a couple of commands or run the dashboard-only experience without Docker.

---

## 🔧 Tech Highlights
- **Airflow via Astro** – containerized orchestration with local UI and scheduler.
- **DuckDB + dbt** – lightweight warehouse plus modular transformations.
- **Great Expectations** – ready for dataset validation inside DAG tasks.
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

# 5. Trigger the DAG (after adding your custom pipeline DAG id)
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

## 📓 Notes for Reviewers
- Set `DATA_URL` when invoking `make download-data` if you want to test with an alternate dataset.
- `scripts/setup.sh` creates `.venv/` at the repo root; activate it for any local CLI work (`source .venv/bin/activate`).
- dbt is configured to write to `data/processed/goodparty.duckdb`; ensure that directory remains writable.
- Airflow DAGs live in `airflow/dags/` inside the Astro project. Use `astro dev restart` after adding DAGs to rebuild the container if requirements change.

Enjoy exploring the voter pipeline!
