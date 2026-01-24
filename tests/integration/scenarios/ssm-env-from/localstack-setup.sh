#!/bin/sh
# Setup SSM parameters for env-from testing
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Single value parameter (will be assigned to a named env var)
aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/secrets/api-token" \
    --value "ssm-token-abc123" \
    --type SecureString

# JSON map parameter (will be expanded to multiple env vars)
aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/config/redis" \
    --value '{"REDIS_HOST":"redis.local","REDIS_PORT":"6379","REDIS_DB":"0"}' \
    --type String
