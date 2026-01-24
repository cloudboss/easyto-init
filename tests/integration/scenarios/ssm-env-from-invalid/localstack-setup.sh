#!/bin/sh
set -eux
ENDPOINT="${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}"

# Create parameter with non-JSON content
aws --endpoint-url="${ENDPOINT}" ssm put-parameter \
    --name "/invalid/plain-text" \
    --value "This is plain text, not JSON" \
    --type String
