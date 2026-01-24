#!/bin/sh
# Setup S3 objects for env-from testing
set -eux

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create test bucket
aws --endpoint-url="${ENDPOINT}" s3 mb s3://config-bucket

# Single value (will be assigned to a named env var)
# Note: Use a temp file because piping to aws s3 cp can be unreliable
echo -n "my-api-key-12345" > /tmp/api-key.txt
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/api-key.txt s3://config-bucket/api-key.txt

# JSON map (will be expanded to multiple env vars)
echo '{"DB_HOST":"localhost","DB_PORT":"5432","DB_NAME":"myapp"}' > /tmp/db-config.json
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/db-config.json s3://config-bucket/db-config.json

# Verify uploads
aws --endpoint-url="${ENDPOINT}" s3 ls s3://config-bucket/
