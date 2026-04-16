#!/bin/sh
set -eu
SCENARIO_DIR=$(cd "$(dirname "$0")" && pwd)
gzip -c "${SCENARIO_DIR}/user-data-source.yaml" > "$1/user-data.yaml"
