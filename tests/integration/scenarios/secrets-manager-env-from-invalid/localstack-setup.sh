#!/bin/sh
set -eux
ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create secret with non-JSON content
aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "invalid/plain-text" \
    --secret-string "This is plain text, not JSON"
