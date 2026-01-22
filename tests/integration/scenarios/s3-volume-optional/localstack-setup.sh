#!/bin/sh
set -eux
ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"
aws --endpoint-url="${ENDPOINT}" s3 mb s3://empty-bucket
# No objects created
