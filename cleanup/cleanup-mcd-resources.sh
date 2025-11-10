#!/bin/bash

# ════════════════════════════════════════════════════════════
# MCD Resources Cleanup Helper Script (v1.0)
# ════════════════════════════════════════════════════════════
# This script cleans up MCD resources for a single pod:
#   • Policy Rule Sets (must be deleted before DLP profiles)
#   • DLP Profiles
#   • Gateways
#   • Service Objects
#   • Address Objects
#
# Called by: cleanup/cleanup.sh
# Usage: cleanup-mcd-resources.sh <pod_number>
# ════════════════════════════════════════════════════════════

set -e

POD_NUMBER=$1
if [ -z "$POD_NUMBER" ]; then
    echo "Usage: $0 <pod_number>"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
CREDS_DIR="${PARENT_DIR}/reference/.creds"

# Load MCD credentials
MCD_JSON_FILE="${CREDS_DIR}/mcd-api.json"

if [ ! -f "$MCD_JSON_FILE" ]; then
    echo -e "${YELLOW}⚠️  MCD credentials not found: $MCD_JSON_FILE${NC}"
    echo "    Skipping MCD resource cleanup"
    exit 0
fi

MCD_ACCT_NAME=$(jq -r '.acctName' "$MCD_JSON_FILE")
MCD_BASE_URL="https://$(jq -r '.restAPIServer' "$MCD_JSON_FILE")"
MCD_PUBLIC_KEY=$(jq -r '.apiKeyID' "$MCD_JSON_FILE")
MCD_PRIVATE_KEY=$(jq -r '.apiKeySecret' "$MCD_JSON_FILE")

echo -e "${YELLOW}🔧 Cleaning MCD resources for pod${POD_NUMBER}...${NC}"

# Get Bearer Token (required for DLP and Policy APIs)
echo "  • Authenticating with MCD API..."
ACCESS_TOKEN=$(curl -s -X POST "$MCD_BASE_URL/api/v1/user/gettoken" \
    -H "Content-Type: application/json" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"apiKeyID\":\"$MCD_PUBLIC_KEY\",\"apiKeySecret\":\"$MCD_PRIVATE_KEY\"}" \
    | jq -r '.accessToken' 2>/dev/null || echo "")

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo -e "${RED}    ⚠️  Failed to get MCD access token${NC}"
    exit 1
fi
echo "    ✓ Authenticated"

# Step 1: Delete Policy Rule Sets (must be deleted before DLP profiles)
echo "  • Checking for policy rule sets..."
POLICY_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/policyruleset/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".policyRuleSetswGateways[]?.policyRuleSet.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

POLICY_COUNT=0
for POLICY_NAME in $POLICY_NAMES; do
    echo "    • Deleting policy rule set: $POLICY_NAME"
    curl -s -X POST "$MCD_BASE_URL/api/v1/policyruleset/delete" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$POLICY_NAME\"}" \
        > /dev/null 2>&1
    ((POLICY_COUNT++))
done
[ $POLICY_COUNT -eq 0 ] && echo "    No policy rule sets found"
[ $POLICY_COUNT -gt 0 ] && echo "    ✓ Deleted $POLICY_COUNT policy rule sets"

# Step 2: Delete DLP Profiles
echo "  • Checking for DLP profiles..."
DLP_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/dlpprofile/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".dlpProfileswGateway[]?.dlpProfile.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

DLP_COUNT=0
for DLP_NAME in $DLP_NAMES; do
    echo "    • Deleting DLP profile: $DLP_NAME"
    curl -s -X POST "$MCD_BASE_URL/api/v1/dlpprofile/delete" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$DLP_NAME\"}" \
        > /dev/null 2>&1
    ((DLP_COUNT++))
done
[ $DLP_COUNT -eq 0 ] && echo "    No DLP profiles found"
[ $DLP_COUNT -gt 0 ] && echo "    ✓ Deleted $DLP_COUNT DLP profiles"

# Step 3: Disable and Delete Gateways
echo "  • Checking for MCD gateways..."
ALL_GATEWAYS=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/list" \
    -H "Content-Type: application/json" \
    -u "${MCD_PUBLIC_KEY}:${MCD_PRIVATE_KEY}" \
    -d '{}' 2>/dev/null | jq -r ".gateways[]? | select(.name | test(\"pod${POD_NUMBER}-.*-gw\")) | .name" 2>/dev/null || echo "")

GW_COUNT=0
for GW_NAME in $ALL_GATEWAYS; do
    echo "    • Found gateway: $GW_NAME"
    
    # Disable first
    DISABLE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/disable" \
        -H "Content-Type: application/json" \
        -u "${MCD_PUBLIC_KEY}:${MCD_PRIVATE_KEY}" \
        -d "{\"name\": \"$GW_NAME\"}" 2>/dev/null || echo "")
    
    if echo "$DISABLE_RESULT" | grep -q "success\|already disabled"; then
        echo "      ✓ Disabled"
    else
        echo "      ⚠  Disable may have failed (continuing...)"
    fi
    
    # Wait for disable to propagate
    sleep 3
    
    # Then delete
    DELETE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/delete" \
        -H "Content-Type: application/json" \
        -u "${MCD_PUBLIC_KEY}:${MCD_PRIVATE_KEY}" \
        -d "{\"name\": \"$GW_NAME\"}" 2>/dev/null || echo "")
    
    if echo "$DELETE_RESULT" | grep -q "success"; then
        echo "      ✓ Deleted"
        ((GW_COUNT++))
    else
        echo "      ⚠  Delete may have failed"
    fi
done
[ $GW_COUNT -eq 0 ] && echo "    No gateways found"
[ $GW_COUNT -gt 0 ] && echo "    ✓ Processed $GW_COUNT gateways"

echo -e "${GREEN}✓ MCD cleanup complete for pod${POD_NUMBER}${NC}"
exit 0
