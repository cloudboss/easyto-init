#!/bin/sh
# Setup S3 bucket with multiple files for directory download testing
set -eux

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

aws --endpoint-url="${ENDPOINT}" s3 mb s3://files-bucket

# Create multiple files under a prefix
echo "File 1 content" > /tmp/file1.txt
echo "File 2 content" > /tmp/file2.txt
echo "Nested file content" > /tmp/nested.txt

aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/file1.txt s3://files-bucket/app/config/file1.txt
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/file2.txt s3://files-bucket/app/config/file2.txt
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/nested.txt s3://files-bucket/app/config/subdir/nested.txt

# Verify uploads
aws --endpoint-url="${ENDPOINT}" s3 ls --recursive s3://files-bucket/
