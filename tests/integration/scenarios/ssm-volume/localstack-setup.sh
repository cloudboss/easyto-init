#!/bin/sh
# Setup SSM parameters in LocalStack
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create test parameters
aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/config/database_host" \
    --value "localhost" \
    --type String

aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/config/database_port" \
    --value "5432" \
    --type String

aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/config/api_key" \
    --value "secret-api-key-12345" \
    --type SecureString
