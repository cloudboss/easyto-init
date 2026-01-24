#!/bin/sh
# Create empty bucket - we intentionally don't create the object
set -eux

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

aws --endpoint-url="${ENDPOINT}" s3 mb s3://optional-bucket
# Note: We intentionally don't create any objects
