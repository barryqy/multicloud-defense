#!/bin/bash

KEY_SERVICE_URL="https://ks.barrysecure.com/credentials"
KEY_SERVICE_LAB_ID="mcd"

json_field() {
    local field_name=$1

    python3 -c '
import json
import sys

data = json.load(sys.stdin)
value = data.get(sys.argv[1], "")

if isinstance(value, (dict, list)):
    print(json.dumps(value), end="")
else:
    print(value, end="")
' "$field_name" 2>/dev/null
}

require_lab_password() {
    if [ -n "${LAB_PASSWORD:-}" ]; then
        return 0
    fi

    echo "❌ LAB_PASSWORD is required to fetch lab credentials" >&2
    return 1
}

fetch_lab_credentials() {
    require_lab_password || return 1

    local api_response
    api_response=$(curl -fsS "$KEY_SERVICE_URL" \
        -H "X-Lab-ID: $KEY_SERVICE_LAB_ID" \
        -H "X-Session-Password: $LAB_PASSWORD" 2>/dev/null) || return 1

    if [ -z "$api_response" ]; then
        return 1
    fi

    AWS_ACCESS_KEY=$(printf '%s' "$api_response" | json_field "AWS_ACCESS_KEY_ID")
    AWS_SECRET=$(printf '%s' "$api_response" | json_field "AWS_SECRET_ACCESS_KEY")
    MCD_API_KEY_JSON=$(printf '%s' "$api_response" | json_field "MCD_API_KEY")

    if [ -z "$AWS_ACCESS_KEY" ] || [ -z "$AWS_SECRET" ]; then
        return 1
    fi

    if [ -z "$MCD_API_KEY_JSON" ]; then
        return 1
    fi

    LAB_CREDENTIALS_JSON="$api_response"
    export AWS_ACCESS_KEY AWS_SECRET MCD_API_KEY_JSON LAB_CREDENTIALS_JSON
    return 0
}

_c2() {
    fetch_lab_credentials
}

get_aws_credentials() {
    echo "🔄 Fetching credentials from key-service..." >&2

    if ! fetch_lab_credentials; then
        echo "❌ Failed to fetch credentials" >&2
        return 1
    fi

    export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
    echo "✓ Credentials retrieved" >&2
    return 0
}

cleanup_credentials() {
    unset AWS_ACCESS_KEY
    unset AWS_SECRET
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset MCD_API_KEY_JSON
    unset LAB_CREDENTIALS_JSON
    unset LAB_PASSWORD
}
