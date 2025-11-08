SHELL := /bin/bash

ASTRO_PROJECT_DIR := airflow
RAW_DATA_DIR := data/raw
PROCESSED_DATA_DIR := data/processed
RAW_DATA_FILE := $(RAW_DATA_DIR)/goodparty_voters.csv
DAG_ID ?= voter_ingestion_dag
STREAMLIT_APP := dashboard/app.py
DATA_URL ?= https://gist.githubusercontent.com/hhkarimi/03b7d159478b319679e308e252f58d44/raw

.PHONY: help check-prereqs install-astro setup astro-init astro-start astro-stop download-data run-pipeline dashboard demo clean

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

setup:             # Setup everything
	@$(MAKE) check-prereqs
	@$(MAKE) astro-init
	@$(MAKE) download-data

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

run-pipeline:      # Trigger the DAG
	@command -v astro >/dev/null 2>&1 || { echo "Astro CLI not installed. Run \"make install-astro\"."; exit 1; }
	@cd $(ASTRO_PROJECT_DIR) && astro dev run dags trigger $(DAG_ID)

dashboard:         # Run Streamlit dashboard
	@command -v streamlit >/dev/null 2>&1 || { echo "Streamlit not found. Install with \"pip install streamlit\"."; exit 1; }
	@streamlit run $(STREAMLIT_APP)

demo:              # Full demo flow
	@$(MAKE) check-prereqs
	@$(MAKE) astro-start
	@$(MAKE) download-data
	@$(MAKE) run-pipeline
	@echo "Demo ready! Run \"make dashboard\" in a new terminal to launch the UI."

clean:             # Clean everything
	@rm -rf $(RAW_DATA_FILE) $(PROCESSED_DATA_DIR)/*.duckdb $(ASTRO_PROJECT_DIR)/logs $(ASTRO_PROJECT_DIR)/dags/__pycache__
	@echo "Workspace cleaned."
