SHELL := /bin/bash

ASTRO_PROJECT_DIR := airflow
RAW_DATA_DIR := data/raw
PROCESSED_DATA_DIR := data/processed
RAW_DATA_FILE := $(RAW_DATA_DIR)/goodparty_voters.csv
PROCESSED_DB_FILE := $(PROCESSED_DATA_DIR)/goodparty.duckdb
ASTRO_INCLUDE_DIR := $(ASTRO_PROJECT_DIR)/include
ASTRO_RAW_DIR := $(ASTRO_INCLUDE_DIR)/data/raw
ASTRO_PROCESSED_DIR := $(ASTRO_INCLUDE_DIR)/data/processed
ASTRO_DBT_DIR := $(ASTRO_INCLUDE_DIR)/dbt_voter_project
DAG_ID ?= voter_ingestion_dag
STREAMLIT_APP := dashboard/app.py
DATA_URL ?= https://gist.githubusercontent.com/hhkarimi/03b7d159478b319679e308e252f58d44/raw

.PHONY: help check-prereqs install-astro setup astro-init astro-start astro-stop download-data copy-data dashboard dashboard-build dashboard-dev demo clean

help:              # Show all commands
	@echo "Available commands:"
	@grep -E '^[-a-zA-Z0-9_]+:.*?#' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?#"} {printf "  %-15s %s\n", $$1, $$2}'

check-prereqs:     # Check if Docker and Astro CLI are installed
	@command -v docker >/dev/null 2>&1 && echo "✅ Docker found" || echo "❌ Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop"
	@command -v astro >/dev/null 2>&1 && echo "✅ Astro CLI found" || echo "❌ Astro CLI not found. Run \"make install-astro\" for instructions"

install-astro:     # Help install Astro CLI
	@echo "Installing via Homebrew (macOS/Linux):"
	@echo "  brew install astro"
	@echo "Manual install: https://www.astronomer.io/docs/astro/cli/install"

setup:             # Run full bootstrap script (creates .venv, installs deps, downloads data)
	@bash scripts/setup.sh

astro-init:        # Initialize Astro project
	@command -v astro >/dev/null 2>&1 || { echo "Astro CLI not installed. Run \"make install-astro\"."; exit 1; }
	@cd $(ASTRO_PROJECT_DIR) && { [ -f Dockerfile ] && echo "Astro project already initialized." || astro dev init; }

astro-start:       # Start Airflow via Astro
	@command -v astro >/dev/null 2>&1 || { echo "Astro CLI not installed. Run \"make install-astro\"."; exit 1; }
	@cd $(ASTRO_PROJECT_DIR) && astro dev start

astro-stop:        # Stop Airflow
	@command -v astro >/dev/null 2>&1 || { echo "Astro CLI not installed. Run \"make install-astro\"."; exit 1; }
	@cd $(ASTRO_PROJECT_DIR) && astro dev stop

download-data:     # Download voter CSV
	@mkdir -p $(RAW_DATA_DIR)
	@if [ "$(DATA_URL)" = "" ]; then echo "Set DATA_URL to a CSV source." && exit 1; fi
	@echo "Downloading voter file from $(DATA_URL) ..."
	@curl -L $(DATA_URL) -o $(RAW_DATA_FILE)
	@echo "Saved to $(RAW_DATA_FILE)"

copy-data:         # Mirror data + dbt project into Astro include for containers
	@mkdir -p $(ASTRO_RAW_DIR) $(ASTRO_PROCESSED_DIR) $(ASTRO_DBT_DIR)
	@command -v rsync >/dev/null 2>&1 || { echo "rsync is required. Install via 'brew install rsync' or your package manager."; exit 1; }
	@if [ ! -f $(RAW_DATA_FILE) ]; then echo "Missing $(RAW_DATA_FILE). Run \"make download-data\" first."; exit 1; fi
	@cp $(RAW_DATA_FILE) $(ASTRO_RAW_DIR)/
	@if [ -f $(PROCESSED_DB_FILE) ]; then \
		cp $(PROCESSED_DB_FILE) $(ASTRO_PROCESSED_DIR)/; \
	else \
		echo "⚠️  $(PROCESSED_DB_FILE) not found yet. It will be created during the DAG run."; \
	fi
	@rsync -a --delete --exclude 'target' --exclude 'dbt_packages' --exclude 'logs' dbt_voter_project/ $(ASTRO_DBT_DIR)/
	@echo "Copied assets into $(ASTRO_INCLUDE_DIR)"

dashboard:         # Run Streamlit dashboard via helper script
	@echo "Starting Voter Analytics Dashboard..."
	@./dashboard/run.sh

dashboard-build:   # Install dashboard dependencies into current environment
	@python -m pip install -r dashboard/requirements.txt

dashboard-dev:     # Run dashboard with Streamlit's dev mode (auto-reload)
	@cd dashboard && streamlit run app.py --server.runOnSave=true

demo:              # Full demo flow with manual DAG trigger
	@$(MAKE) check-prereqs
	@$(MAKE) download-data
	@$(MAKE) astro-start
	@$(MAKE) copy-data
	@echo "Airflow is running at http://localhost:8080 (admin/admin). Trigger '$(DAG_ID)' from the UI."
	@echo "Once the DAG finishes, run 'make dashboard' in a new terminal to launch the UI."

clean:             # Clean everything
	@rm -rf $(RAW_DATA_FILE) $(PROCESSED_DATA_DIR)/*.duckdb $(ASTRO_PROJECT_DIR)/logs $(ASTRO_PROJECT_DIR)/dags/__pycache__
	@echo "Workspace cleaned."
