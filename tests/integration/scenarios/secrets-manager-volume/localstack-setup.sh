#!/bin/sh
# Setup secrets in LocalStack Secrets Manager
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create test secrets
aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "app/database-password" \
    --secret-string "super-secret-password-123"

aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "app/api-credentials" \
    --secret-string '{"api_key":"key123","api_secret":"secret456"}'
