#!/bin/sh
# Setup AWS resources for variable expansion testing
set -eux

ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# S3: Database connection details as JSON
aws --endpoint-url="${ENDPOINT}" s3 mb s3://env-bucket
echo '{"DB_HOST":"db.example.com","DB_PORT":"5432","DB_NAME":"production"}' > /tmp/db-config.json
aws --endpoint-url="${ENDPOINT}" s3 cp /tmp/db-config.json s3://env-bucket/db-config.json

# Verify upload
aws --endpoint-url="${ENDPOINT}" s3 ls s3://env-bucket/

# SSM: Username
aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/app/db/username" \
    --value "app_user" \
    --type String

# Secrets Manager: Password
aws --endpoint-url="${ENDPOINT}" secretsmanager create-secret \
    --name "app/db/password" \
    --secret-string "super-secret-password"
