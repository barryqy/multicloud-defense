#!/bin/bash
MCD_CREDS_FILE=".terraform/.mcd-api.json"
DECODED=$(cat "$MCD_CREDS_FILE" | base64 -d 2>/dev/null)
API_KEY=$(echo "$DECODED" | jq -r '.apiKeyID')
API_SECRET=$(echo "$DECODED" | jq -r '.apiKeySecret')
REST_API_SERVER=$(echo "$DECODED" | jq -r '.restAPIServer')
ACCT_NAME=$(echo "$DECODED" | jq -r '.acctName')
BASE_URL="https://${REST_API_SERVER}"

TOKEN_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/user/gettoken" \
    -H "Content-Type: application/json" \
    -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"apiKeyID\":\"$API_KEY\",\"apiKeySecret\":\"$API_SECRET\"}")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.accessToken')

echo "Checking MCD for any DLP profiles (including old ones)..."
curl -s -X POST "${BASE_URL}/api/v1/services/dlp/profile/list" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"}}" | jq '.'

echo ""
echo "If DLP was working before, there should be profiles listed above."
echo "If the response is 'Not Found', DLP was never actually deployed via API."
