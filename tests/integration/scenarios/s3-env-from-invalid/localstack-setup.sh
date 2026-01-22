#!/bin/sh
# Setup S3 object with invalid (non-JSON) content for error testing
set -eux

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

aws --endpoint-url="${ENDPOINT}" s3 mb s3://invalid-bucket

# Plain text file (not valid JSON) - should fail when used without 'name'
echo "This is plain text, not JSON" > /tmp/plain-text.txt
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/plain-text.txt s3://invalid-bucket/plain-text.txt
