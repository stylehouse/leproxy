#!/bin/bash
set -euo pipefail
source .env
export DUCKDNS_NAMES NAMES_PORTS
# exports those variables to perl:
perl here/build-docker-compose.pl