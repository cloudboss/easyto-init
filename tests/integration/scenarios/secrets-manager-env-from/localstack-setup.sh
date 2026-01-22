#!/bin/sh
# Setup secrets for env-from testing
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Single value secret (will be assigned to a named env var)
aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "app/jwt-secret" \
    --secret-string "super-secret-jwt-key-xyz789"

# JSON map secret (will be expanded to multiple env vars)
aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "app/oauth-credentials" \
    --secret-string '{"OAUTH_CLIENT_ID":"client123","OAUTH_CLIENT_SECRET":"secret456","OAUTH_REDIRECT_URI":"https://app.example.com/callback"}'
