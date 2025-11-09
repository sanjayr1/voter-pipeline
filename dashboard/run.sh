#!/usr/bin/env bash
# Start the GoodParty voter analytics dashboard with sensible defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SCRIPT_DIR}"

echo "🚀 Starting GoodParty Voter Analytics Dashboard"

# Prefer local warehouse mirror; fall back to container path if needed.
LOCAL_DB_PATH="${PROJECT_ROOT}/data/processed/goodparty.duckdb"
CONTAINER_DB_PATH="/usr/local/airflow/data/processed/goodparty.duckdb"

if [[ -z "${DUCKDB_PATH:-}" ]]; then
    if [[ -f "${LOCAL_DB_PATH}" ]]; then
        export DUCKDB_PATH="${LOCAL_DB_PATH}"
    else
        export DUCKDB_PATH="${CONTAINER_DB_PATH}"
    fi
fi

echo "Using DuckDB at: ${DUCKDB_PATH}"

if [[ ! -f "${DUCKDB_PATH}" ]]; then
    echo "❌ Database not found. Run the pipeline first (e.g., 'make run-pipeline')."
    exit 1
fi

# Install dashboard deps into the active environment if missing.
echo "📦 Ensuring Streamlit dependencies are installed..."
python -m pip install -q -r requirements.txt

echo "🌐 Opening dashboard on http://localhost:8501"
exec streamlit run app.py \
    --server.port 8501 \
    --server.address 0.0.0.0 \
    --server.headless true \
    --browser.serverAddress localhost \
    --theme.primaryColor="#1f77b4" \
    --theme.backgroundColor="#ffffff" \
    --theme.secondaryBackgroundColor="#f0f2f6"
