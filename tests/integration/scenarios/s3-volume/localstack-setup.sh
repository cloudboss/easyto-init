#!/bin/sh
# Setup S3 bucket and test files in LocalStack
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create test bucket
aws --endpoint-url="${ENDPOINT}" s3 mb s3://test-bucket

# Upload test files
echo "Hello from S3!" | aws --endpoint-url="${ENDPOINT}" s3 cp - s3://test-bucket/config/greeting.txt
echo "config_value=42" | aws --endpoint-url="${ENDPOINT}" s3 cp - s3://test-bucket/config/settings.conf
