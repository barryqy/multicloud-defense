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

# Step 1: Disable and Delete Gateways (MUST BE FIRST!)
echo "  • Checking for MCD gateways..."
ALL_GATEWAYS=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"detail\":true}" \
    2>/dev/null | jq -r ".gateways[]? | select(.name | contains(\"pod${POD_NUMBER}-\")) | .name" 2>/dev/null || echo "")

GW_COUNT=0
for GW_NAME in $ALL_GATEWAYS; do
    echo "    • Found gateway: $GW_NAME"
    
    # Disable first (CRITICAL: Gateway must be INACTIVE before deletion)
    echo "      Disabling..."
    DISABLE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/disable" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$GW_NAME\"}" 2>/dev/null || echo "")
    
    if ! echo "$DISABLE_RESULT" | grep -q "\"code\""; then
        echo "      ✓ Disabled"
    else
        echo "      ⚠  Disable may have failed ($(echo "$DISABLE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown"))"
    fi
    
    # Wait for disable to propagate and state to change to INACTIVE
    echo "      Waiting 10 seconds for state change..."
    sleep 10
    
    # Try deletion up to 3 times (gateway must be INACTIVE)
    DELETED=false
    for attempt in 1 2 3; do
        DELETE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/delete" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$GW_NAME\"}" 2>/dev/null || echo "")
        
        if ! echo "$DELETE_RESULT" | grep -q "\"code\""; then
            echo "      ✓ Deleted"
            DELETED=true
            ((GW_COUNT++))
            break
        elif echo "$DELETE_RESULT" | grep -q "INACTIVE state"; then
            if [ $attempt -lt 3 ]; then
                echo "      ⚠  Still in ACTIVE state, waiting 15s... (attempt $attempt)"
                sleep 15
            else
                echo "      ⚠  Delete failed after 3 attempts (still in ACTIVE state)"
            fi
        else
            echo "      ⚠  Delete failed: $(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")"
            break
        fi
    done
done
[ $GW_COUNT -eq 0 ] && echo "    No gateways found"
[ $GW_COUNT -gt 0 ] && echo "    ✓ Processed $GW_COUNT gateways"

# CRITICAL: Wait for MCD to sync gateway deletion before deleting policies
if [ $GW_COUNT -gt 0 ]; then
    echo "  ⏱️  Waiting 90 seconds for MCD to sync gateway deletion..."
    sleep 90
fi

# Step 2: Delete Policy Rule Sets (with retry logic for stale gateway references)
echo "  • Checking for policy rule sets..."
POLICY_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/policyruleset/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".policyRuleSetswGateways[]?.policyRuleSet.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

POLICY_COUNT=0
POLICY_FAILED=0
for POLICY_NAME in $POLICY_NAMES; do
    echo -n "    • Deleting policy rule set: $POLICY_NAME... "
    
    # Try up to 3 times with backoff
    SUCCESS=false
    for attempt in 1 2 3; do
        DELETE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/policyruleset/delete" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$POLICY_NAME\"}" \
            2>&1)
        
        # Check if deletion succeeded (empty response or success)
        if ! echo "$DELETE_RESULT" | grep -q "\"code\""; then
            echo "✓"
            SUCCESS=true
            ((POLICY_COUNT++))
            break
        elif echo "$DELETE_RESULT" | grep -q "\"code\":2"; then
            # Code 2 = still in use by gateway
            if [ $attempt -lt 3 ]; then
                echo -n "(retry $attempt, gateway still attached)... "
                sleep 30
            else
                echo "✗ (still attached to gateway after 3 attempts)"
                ((POLICY_FAILED++))
            fi
        else
            # Other error
            echo "✗ ($(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown error"))"
            ((POLICY_FAILED++))
            break
        fi
    done
done
[ $POLICY_COUNT -eq 0 ] && [ $POLICY_FAILED -eq 0 ] && echo "    No policy rule sets found"
[ $POLICY_COUNT -gt 0 ] && echo "    ✓ Deleted $POLICY_COUNT policy rule sets"
[ $POLICY_FAILED -gt 0 ] && echo "    ⚠️  Failed to delete $POLICY_FAILED policy rule sets (stale gateway references)"

# Step 3: Delete DLP Profiles (with retry logic)
echo "  • Checking for DLP profiles..."
DLP_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/dlpprofile/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".dlpProfileswGateway[]?.dlpProfile.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

DLP_COUNT=0
DLP_FAILED=0
for DLP_NAME in $DLP_NAMES; do
    echo -n "    • Deleting DLP profile: $DLP_NAME... "
    
    # Try up to 3 times with backoff
    SUCCESS=false
    for attempt in 1 2 3; do
        DELETE_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/dlpprofile/delete" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$DLP_NAME\"}" \
            2>&1)
        
        # Check if deletion succeeded
        if ! echo "$DELETE_RESULT" | grep -q "\"code\""; then
            echo "✓"
            SUCCESS=true
            ((DLP_COUNT++))
            break
        elif echo "$DELETE_RESULT" | grep -q "\"code\":2"; then
            # Code 2 = still in use by policy
            if [ $attempt -lt 3 ]; then
                echo -n "(retry $attempt, policy still attached)... "
                sleep 20
            else
                echo "✗ (still attached to policy after 3 attempts)"
                ((DLP_FAILED++))
            fi
        else
            # Other error
            echo "✗ ($(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown error"))"
            ((DLP_FAILED++))
            break
        fi
    done
done
[ $DLP_COUNT -eq 0 ] && [ $DLP_FAILED -eq 0 ] && echo "    No DLP profiles found"
[ $DLP_COUNT -gt 0 ] && echo "    ✓ Deleted $DLP_COUNT DLP profiles"
[ $DLP_FAILED -gt 0 ] && echo "    ⚠️  Failed to delete $DLP_FAILED DLP profiles (stale policy references)"

echo -e "${GREEN}✓ MCD cleanup complete for pod${POD_NUMBER}${NC}"
exit 0
