#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )/.." && pwd)"
DATA_URL="https://gist.githubusercontent.com/hhkarimi/03b7d159478b319679e308e252f58d44/raw"
RAW_DATA_DIR="$ROOT_DIR/data/raw"
RAW_DATA_FILE="$RAW_DATA_DIR/goodparty_voters.csv"
PROCESSED_DIR="$ROOT_DIR/data/processed"
ASTRO_DIR="$ROOT_DIR/airflow"
DBT_DIR="$ROOT_DIR/dbt_voter_project"
DASHBOARD_REQS="$ROOT_DIR/dashboard/requirements.txt"
LOCAL_REQS="$ROOT_DIR/requirements-local.txt"
AUTO_CONFIRM="${AUTO_CONFIRM:-0}"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
DBT_BIN="$VENV_DIR/bin/dbt"

log() { echo "[$(date +%H:%M:%S)] $*"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

prompt_confirm() {
  local prompt_msg="$1 [y/N]: "
  if [[ "$AUTO_CONFIRM" == "1" ]]; then
    return 0
  fi
  read -r -p "$prompt_msg" response || return 1
  [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]
}

ensure_command() {
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required. $*"
}

ensure_docker_running() {
  ensure_command docker "Install Docker Desktop from https://www.docker.com/ if you have not already."
  if ! docker info >/dev/null 2>&1; then
    die "Docker is not running or current user cannot talk to the Docker daemon. Please start Docker Desktop and re-run the setup."
  fi
  log "Docker is available."
}

ensure_astro_cli() {
  if command -v astro >/dev/null 2>&1; then
    log "Astro CLI detected."
    return
  fi

  echo "Astro CLI not found."
  if command -v brew >/dev/null 2>&1; then
    if prompt_confirm "Install Astro CLI via Homebrew now?"; then
      brew install astro || die "Failed to install Astro via Homebrew."
    else
      die "Astro CLI is required. Install it manually (https://www.astronomer.io/docs/astro/cli/install) and re-run."
    fi
  else
    die "Homebrew not available. Install the Astro CLI manually from https://www.astronomer.io/docs/astro/cli/install."
  fi
}

ensure_python_and_pip() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    die "Python 3 is required. Install it via Homebrew (brew install python) or from python.org."
  fi

  if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
    die "pip is missing for $PYTHON_BIN. Install it (e.g., python3 -m ensurepip --upgrade)."
  fi

  log "Using Python interpreter at $PYTHON_BIN."
}

ensure_virtualenv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating Python virtual environment in $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR" || die "Failed to create Python virtual environment."
  fi
  "$VENV_PIP" install --upgrade pip >/dev/null 2>&1 || die "Failed to upgrade pip inside the virtual environment."
  export PATH="$VENV_DIR/bin:$PATH"
  log "Virtual environment ready at $VENV_DIR (activate via 'source .venv/bin/activate')."
}

ensure_dbt_cli() {
  if [[ -x "$DBT_BIN" ]]; then
    log "dbt CLI detected in $DBT_BIN."
    return
  fi

  log "dbt CLI not found in virtual environment. Installing dbt-core and dbt-duckdb..."
  "$VENV_PIP" install "dbt-core>=1.6" "dbt-duckdb>=1.6" || die "Failed to install dbt packages."
}

download_voter_data() {
  ensure_command curl "Install curl to download files (macOS: brew install curl)."
  mkdir -p "$RAW_DATA_DIR"
  log "Downloading voter data into $RAW_DATA_FILE"
  if [[ -f "$RAW_DATA_FILE" ]]; then
    curl -fsSL -z "$RAW_DATA_FILE" "$DATA_URL" -o "$RAW_DATA_FILE" || die "Failed to refresh voter data."
  else
    curl -fsSL "$DATA_URL" -o "$RAW_DATA_FILE" || die "Failed to download voter data."
  fi
  log "Voter CSV ready."
}

init_astro_project() {
  ensure_astro_cli
  if [[ -f "$ASTRO_DIR/Dockerfile" ]]; then
    log "Astro project already initialized in airflow/."
    return
  fi
  log "Initializing Astro project in $ASTRO_DIR ..."
  (cd "$ASTRO_DIR" && astro dev init) || die "Astro init failed."
}

setup_dbt_project() {
  mkdir -p "$DBT_DIR/models" "$DBT_DIR/seeds" "$DBT_DIR/macros"
  if [[ ! -f "$DBT_DIR/dbt_project.yml" ]]; then
    cat <<'YAML' > "$DBT_DIR/dbt_project.yml"
name: dbt_voter_project
version: 1.0.0
config-version: 2
profile: voter_duckdb
model-paths: ["models"]
analysis-paths: ["analyses"]
target-path: "target"
clean-targets: ["target", "dbt_packages"]

models:
  dbt_voter_project:
    +materialized: view
YAML
    log "Created dbt_project.yml"
  else
    log "dbt_project.yml already exists."
  fi

  if [[ ! -f "$DBT_DIR/profiles.yml" ]]; then
    cat <<'YAML' > "$DBT_DIR/profiles.yml"
voter_duckdb:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: ../data/processed/goodparty.duckdb
      extensions: []
      schema: main
      threads: 4
YAML
    log "Wrote dbt profiles.yml (set DBT_PROFILES_DIR=./dbt_voter_project to use it)."
  else
    log "dbt profiles.yml already exists."
  fi
}

install_local_dependencies() {
  local requirements_files=()
  [[ -f "$LOCAL_REQS" ]] && requirements_files+=("$LOCAL_REQS")
  [[ -f "$DASHBOARD_REQS" ]] && requirements_files+=("$DASHBOARD_REQS")

  if [[ "${#requirements_files[@]}" -eq 0 ]]; then
    log "No local requirements files found; skipping Python dependency installation."
    return
  fi

  for req in "${requirements_files[@]}"; do
    log "Installing local requirements from $req"
    "$VENV_PIP" install -r "$req" || die "Failed to install dependencies from $req"
  done
}

main() {
  ensure_docker_running
  ensure_astro_cli
  ensure_python_and_pip
  ensure_virtualenv
  ensure_dbt_cli
  download_voter_data
  init_astro_project
  setup_dbt_project
  install_local_dependencies
  log "Setup complete! Activate the virtualenv with 'source .venv/bin/activate' before running local commands. You are ready to run 'make astro-start' or 'make demo'."
}

main "$@"
