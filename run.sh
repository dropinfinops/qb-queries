#!/usr/bin/env bash
# DropInFinOps -- FOCUS anomaly playground launcher.
#
# This does NOT run any detection query for you. It checks for duckdb, loads the
# sample billing data (dated through today), and drops you at a DuckDB prompt with
# the `bill` view ready. You run the queries yourself and watch them catch the
# planted waste.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v duckdb >/dev/null 2>&1; then
  cat <<'EOF'
duckdb is not installed (it's the only dependency).

Install it, then re-run ./run.sh :
  macOS:   brew install duckdb
  Linux:   curl https://install.duckdb.org | sh
  Docs:    https://duckdb.org/docs/installation/
EOF
  exit 1
fi

exec duckdb -init playground.sql
