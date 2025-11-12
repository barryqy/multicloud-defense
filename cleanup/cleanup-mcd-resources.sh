#!/bin/bash

# ════════════════════════════════════════════════════════════
# MCD Resources Cleanup Helper Script (v1.1)
# ════════════════════════════════════════════════════════════
# This script cleans up MCD resources for a single pod:
#   • Service VPCs (MUST BE FIRST - detach spoke VPCs first)
#   • Gateways (must be disabled before deletion)
#   • Policy Rule Sets (must be deleted before DLP profiles)
#   • DLP Profiles
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

# This file is created by 1-init-lab.sh
MCD_JSON_FILE="${PARENT_DIR}/.terraform/.mcd-api.json"

if [ ! -f "$MCD_JSON_FILE" ]; then
    echo -e "${YELLOW}⚠️  MCD credentials not found: $MCD_JSON_FILE${NC}"
    echo "    This file is created by running ./1-init-lab.sh"
    echo "    Skipping MCD resource cleanup"
    exit 0
fi

# Load and decode credentials
echo "  • Loading MCD credentials..."
DECODED=$(cat "$MCD_JSON_FILE" | base64 -d 2>/dev/null || echo "")
if [ -z "$DECODED" ]; then
    echo -e "${RED}    ⚠️  Failed to decode MCD credentials${NC}"
    exit 1
fi

MCD_ACCT_NAME=$(echo "$DECODED" | jq -r '.acctName' 2>/dev/null || echo "")
MCD_BASE_URL="https://$(echo "$DECODED" | jq -r '.restAPIServer' 2>/dev/null || echo "")"
MCD_PUBLIC_KEY=$(echo "$DECODED" | jq -r '.apiKeyID' 2>/dev/null || echo "")
MCD_PRIVATE_KEY=$(echo "$DECODED" | jq -r '.apiKeySecret' 2>/dev/null || echo "")

# Validate credentials
if [ -z "$MCD_ACCT_NAME" ] || [ "$MCD_ACCT_NAME" == "null" ] || \
   [ -z "$MCD_PUBLIC_KEY" ] || [ "$MCD_PUBLIC_KEY" == "null" ] || \
   [ -z "$MCD_PRIVATE_KEY" ] || [ "$MCD_PRIVATE_KEY" == "null" ]; then
    echo -e "${RED}    ⚠️  Invalid MCD credentials${NC}"
    exit 1
fi

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

# Step 0: Delete Service VPCs (MUST BE FIRST - before gateways!)
# Wrap in set +e to continue even if Service VPC deletion fails
set +e
SVPC_NAME="pod${POD_NUMBER}-svpc-aws"
echo "  • Checking for Service VPC: $SVPC_NAME..."

# List CSP accounts
CSP_LIST=$(curl -s -X POST "$MCD_BASE_URL/api/v1/cspaccount/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null)

# Check if Service VPC is listed as a CSP account
SVPC_EXISTS=$(echo "$CSP_LIST" | jq -r ".cspAccounts[]? | select(.name == \"$SVPC_NAME\") | .name" 2>/dev/null || echo "")

# If not found, Service VPC might still exist but not be listed
# Try to get it directly by name (it might exist but not appear in list)
if [ -z "$SVPC_EXISTS" ] || [ "$SVPC_EXISTS" == "null" ]; then
    echo "    Service VPC not found in CSP account list"
    echo "    Attempting to get Service VPC directly by name..."
    
    # Try to get Service VPC directly (it might exist but not be in list)
    SVPC_DETAILS=$(curl -s -X POST "$MCD_BASE_URL/api/v1/cspaccount/get" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$SVPC_NAME\"}" \
        2>/dev/null)
    
    # Check if we got a valid response (not an error)
    if ! echo "$SVPC_DETAILS" | grep -q "\"code\""; then
        # Got valid response - Service VPC exists
        SVPC_EXISTS="$SVPC_NAME"
        echo "    ✓ Found Service VPC via direct get"
    fi
fi

if [ -n "$SVPC_EXISTS" ] && [ "$SVPC_EXISTS" != "null" ]; then
    echo "    ✓ Found Service VPC in MCD"
    
    # If we don't have details yet, get them
    if [ -z "$SVPC_DETAILS" ]; then
        SVPC_DETAILS=$(curl -s -X POST "$MCD_BASE_URL/api/v1/cspaccount/get" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$SVPC_NAME\"}" \
            2>/dev/null)
    fi
    
    # Check for attached spoke VPCs
    SPOKE_VPCS=$(echo "$SVPC_DETAILS" | jq -r '.servicesVPC[0].attachedSpokeVPCs[]?' 2>/dev/null || echo "")
    
    if [ -n "$SPOKE_VPCS" ] && [ "$SPOKE_VPCS" != "null" ]; then
        echo "    ⚠️  Found attached spoke VPCs - detaching first..."
        
        CSP_ACCT_NAME=$(echo "$SVPC_DETAILS" | jq -r '.cspAcctName' 2>/dev/null || echo "")
        REGION=$(echo "$SVPC_DETAILS" | jq -r '.servicesVPC[0].region' 2>/dev/null || echo "us-east-1")
        SVPC_VPC_ID=$(echo "$SVPC_DETAILS" | jq -r '.servicesVPC[0].vpcID' 2>/dev/null || echo "")
        
        for SPOKE_JSON in $(echo "$SVPC_DETAILS" | jq -c '.servicesVPC[0].attachedSpokeVPCs[]?' 2>/dev/null); do
            SPOKE_MCD_ID=$(echo "$SPOKE_JSON" | jq -r '.id' 2>/dev/null || echo "")
            SPOKE_VPC_ID=$(echo "$SPOKE_JSON" | jq -r '.vpcID' 2>/dev/null || echo "")
            SPOKE_NAME=$(echo "$SPOKE_JSON" | jq -r '.name' 2>/dev/null || echo "")
            
            if [ -z "$SPOKE_MCD_ID" ] || [ "$SPOKE_MCD_ID" == "null" ]; then
                continue
            fi
            
            echo "      Detaching $SPOKE_NAME (MCD ID: $SPOKE_MCD_ID)..."
            DETACH_RESULT=$(curl -s -X POST "$MCD_BASE_URL/api/v1/transit/vpc/update" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -d "{
                    \"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},
                    \"cspAcctName\":\"$CSP_ACCT_NAME\",
                    \"region\":\"$REGION\",
                    \"servicesVPCID\":\"$SVPC_VPC_ID\",
                    \"servicesVPCName\":\"$SVPC_NAME\",
                    \"type\":\"REMOVE_USER_VPC_ROUTE\",
                    \"userVPC\":{
                        \"ID\":$SPOKE_MCD_ID,
                        \"cspAcctName\":\"$CSP_ACCT_NAME\",
                        \"region\":\"$REGION\",
                        \"vpcID\":\"$SPOKE_VPC_ID\"
                    }
                }" \
                2>&1)
            
            if echo "$DETACH_RESULT" | grep -q "\"code\""; then
                ERROR_MSG=$(echo "$DETACH_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")
                echo "      ⚠️  Detach failed: $ERROR_MSG"
            else
                echo "      ✓ Detached"
            fi
            sleep 2
        done
        
        echo "    ⏱️  Waiting 10 seconds for detachments to propagate..."
        sleep 10
    else
        echo "    ✓ No attached spoke VPCs"
    fi
    
    # Delete Service VPC using Terraform (API deletion is unreliable)
    echo "    Deleting Service VPC via Terraform..."
    cd "${PARENT_DIR}" 2>/dev/null || true
    
    # Check if Service VPC is already in Terraform state
    if terraform state list 2>/dev/null | grep -q "ciscomcd_service_vpc.svpc-aws"; then
        echo "    ✓ Service VPC found in Terraform state"
    else
        # Not in state - need to import it first
        echo "    ℹ️  Service VPC not in Terraform state - importing..."
        
        # Get the Service VPC ID from the details we fetched earlier
        SVPC_ID=$(echo "$SVPC_DETAILS" | jq -r '.servicesVPC[0].id' 2>/dev/null || echo "")
        
        if [ -z "$SVPC_ID" ] || [ "$SVPC_ID" == "null" ] || [ "$SVPC_ID" == "" ]; then
            echo "    ⚠️  Could not determine Service VPC ID for import"
            echo "    ℹ️  Service VPC may need manual deletion via MCD dashboard"
            echo "    ℹ️  Or try: terraform import ciscomcd_service_vpc.svpc-aws <ID>"
            exit 0
        fi
        
        echo "    ℹ️  Importing Service VPC (ID: $SVPC_ID) into Terraform state..."
        TERRAFORM_IMPORT_OUTPUT=$(terraform import ciscomcd_service_vpc.svpc-aws "$SVPC_ID" 2>&1)
        
        if ! echo "$TERRAFORM_IMPORT_OUTPUT" | grep -q "Import successful"; then
            echo "    ⚠️  Import failed: $(echo "$TERRAFORM_IMPORT_OUTPUT" | tail -5)"
            echo "    ℹ️  Service VPC may need manual deletion via MCD dashboard"
            echo "    ℹ️  Or try: terraform import ciscomcd_service_vpc.svpc-aws <ID>"
            exit 0
        fi
        echo "    ✓ Service VPC imported successfully"
    fi
    
    # Destroy Service VPC via Terraform
    echo "    🗑️  Destroying via Terraform..."
    TERRAFORM_DESTROY_OUTPUT=$(terraform destroy -target=ciscomcd_service_vpc.svpc-aws -auto-approve 2>&1)
    
    if echo "$TERRAFORM_DESTROY_OUTPUT" | grep -q "Destroy complete"; then
        echo "    ✓ Service VPC destroyed via Terraform"
        echo "    ⏱️  Waiting 30 seconds for deletion to propagate..."
        sleep 30
    else
        echo "    ⚠️  Terraform destroy may have failed"
        echo "    Debug: $(echo "$TERRAFORM_DESTROY_OUTPUT" | tail -10)"
    fi
else
    echo "    ℹ️  Service VPC not found in CSP account list"
    echo "    ℹ️  Service VPC may exist but not be accessible via API"
    echo "    ℹ️  Attempting Terraform cleanup (if Service VPC is in Terraform state)..."
    
    cd "${PARENT_DIR}" 2>/dev/null || true
    
    # Check if Service VPC is in Terraform state
    if terraform state list 2>/dev/null | grep -q "ciscomcd_service_vpc.svpc-aws"; then
        echo "    ✓ Service VPC found in Terraform state"
        echo "    🗑️  Destroying via Terraform..."
        TERRAFORM_DESTROY_OUTPUT=$(terraform destroy -target=ciscomcd_service_vpc.svpc-aws -auto-approve 2>&1)
        
        if echo "$TERRAFORM_DESTROY_OUTPUT" | grep -q "Destroy complete"; then
            echo "    ✓ Service VPC destroyed via Terraform"
            echo "    ⏱️  Waiting 30 seconds for deletion to propagate..."
            sleep 30
        else
            echo "    ⚠️  Terraform destroy may have failed"
            echo "    Debug: $(echo "$TERRAFORM_DESTROY_OUTPUT" | tail -10)"
        fi
    else
        echo "    ⚠️  Service VPC not in Terraform state and not found via API"
        echo "    ℹ️  Service VPC may need manual deletion via MCD dashboard"
        echo "    ℹ️  Or try: terraform import ciscomcd_service_vpc.svpc-aws <ID> then terraform destroy"
    fi
fi
set -e  # Re-enable exit on error for rest of script

# Step 1: Disable and Delete Gateways (MUST BE AFTER Service VPC!)
# Wrap in set +e to continue even if gateway deletion fails
set +e
echo "  • Checking for MCD gateways..."
ALL_GATEWAYS=$(curl -s -X POST "$MCD_BASE_URL/api/v1/gateway/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"detail\":true}" \
    2>/dev/null | jq -r ".gateways[]? | select(.name | contains(\"pod${POD_NUMBER}-\")) | .name" 2>/dev/null || echo "")

GW_COUNT=0
if [ -n "$ALL_GATEWAYS" ]; then
    for GW_NAME in $ALL_GATEWAYS; do
        if [ -z "$GW_NAME" ] || [ "$GW_NAME" == "null" ]; then
            continue
        fi
        
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
            ERROR_MSG=$(echo "$DISABLE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")
            echo "      ⚠  Disable may have failed: $ERROR_MSG"
            # Show full response for debugging
            echo "      Debug: $DISABLE_RESULT"
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
            
            # Check if deletion succeeded (no error code)
            if ! echo "$DELETE_RESULT" | grep -q "\"code\""; then
                echo "      ✓ Deleted"
                DELETED=true
                ((GW_COUNT++))
                break
            else
                ERROR_CODE=$(echo "$DELETE_RESULT" | jq -r '.code' 2>/dev/null || echo "")
                ERROR_MSG=$(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")
                
                # Check for specific error messages
                if echo "$ERROR_MSG" | grep -qi "INACTIVE\|active state\|still active"; then
                    if [ $attempt -lt 3 ]; then
                        echo "      ⚠  Still in ACTIVE state, waiting 15s... (attempt $attempt)"
                        sleep 15
                    else
                        echo "      ⚠  Delete failed after 3 attempts (still in ACTIVE state)"
                        echo "      Debug: $DELETE_RESULT"
                    fi
                else
                    echo "      ⚠  Delete failed (attempt $attempt): Code $ERROR_CODE - $ERROR_MSG"
                    echo "      Debug: $DELETE_RESULT"
                    # Don't break on first error, try all 3 attempts
                    if [ $attempt -lt 3 ]; then
                        echo "      Retrying in 10 seconds..."
                        sleep 10
                    fi
                fi
            fi
        done
        
        if [ "$DELETED" = false ]; then
            echo "      ❌ Failed to delete gateway $GW_NAME after 3 attempts"
        fi
    done
fi

if [ $GW_COUNT -eq 0 ]; then
    echo "    No gateways found"
else
    echo "    ✓ Processed $GW_COUNT gateways"
fi
set -e  # Re-enable exit on error

# CRITICAL: Wait for MCD to sync gateway deletion before deleting policies
if [ $GW_COUNT -gt 0 ]; then
    echo "  ⏱️  Waiting 90 seconds for MCD to sync gateway deletion..."
    sleep 90
fi

# Step 2: Delete Policy Rule Sets (with retry logic for stale gateway references)
# Wrap in set +e to continue even if policy deletion fails
set +e
echo "  • Checking for policy rule sets..."
POLICY_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/policyruleset/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".policyRuleSetswGateways[]?.policyRuleSet.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

POLICY_COUNT=0
POLICY_FAILED=0
if [ -n "$POLICY_NAMES" ]; then
    for POLICY_NAME in $POLICY_NAMES; do
        if [ -z "$POLICY_NAME" ] || [ "$POLICY_NAME" == "null" ]; then
            continue
        fi
        
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
            else
                ERROR_CODE=$(echo "$DELETE_RESULT" | jq -r '.code' 2>/dev/null || echo "")
                ERROR_MSG=$(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")
                
                if [ "$ERROR_CODE" = "2" ] || echo "$ERROR_MSG" | grep -qi "gateway\|still in use\|attached"; then
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
                    echo "✗ (Code $ERROR_CODE: $ERROR_MSG)"
                    ((POLICY_FAILED++))
                    break
                fi
            fi
        done
    done
fi

if [ $POLICY_COUNT -eq 0 ] && [ $POLICY_FAILED -eq 0 ]; then
    echo "    No policy rule sets found"
elif [ $POLICY_COUNT -gt 0 ]; then
    echo "    ✓ Deleted $POLICY_COUNT policy rule sets"
fi
if [ $POLICY_FAILED -gt 0 ]; then
    echo "    ⚠️  Failed to delete $POLICY_FAILED policy rule sets (stale gateway references)"
fi
set -e  # Re-enable exit on error

# Step 3: Delete DLP Profiles (with retry logic)
# Wrap in set +e to continue even if DLP deletion fails
set +e
echo "  • Checking for DLP profiles..."
DLP_NAMES=$(curl -s -X POST "$MCD_BASE_URL/api/v1/dlpprofile/list" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"common\":{\"acctName\":\"$MCD_ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"}}" \
    2>/dev/null | jq -r ".dlpProfileswGateway[]?.dlpProfile.header.name" | grep "^pod${POD_NUMBER}-" 2>/dev/null || echo "")

DLP_COUNT=0
DLP_FAILED=0
if [ -n "$DLP_NAMES" ]; then
    for DLP_NAME in $DLP_NAMES; do
        if [ -z "$DLP_NAME" ] || [ "$DLP_NAME" == "null" ]; then
            continue
        fi
        
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
            else
                ERROR_CODE=$(echo "$DELETE_RESULT" | jq -r '.code' 2>/dev/null || echo "")
                ERROR_MSG=$(echo "$DELETE_RESULT" | jq -r '.message' 2>/dev/null || echo "unknown")
                
                if [ "$ERROR_CODE" = "2" ] || echo "$ERROR_MSG" | grep -qi "policy\|still in use\|attached"; then
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
                    echo "✗ (Code $ERROR_CODE: $ERROR_MSG)"
                    ((DLP_FAILED++))
                    break
                fi
            fi
        done
    done
fi

if [ $DLP_COUNT -eq 0 ] && [ $DLP_FAILED -eq 0 ]; then
    echo "    No DLP profiles found"
elif [ $DLP_COUNT -gt 0 ]; then
    echo "    ✓ Deleted $DLP_COUNT DLP profiles"
fi
if [ $DLP_FAILED -gt 0 ]; then
    echo "    ⚠️  Failed to delete $DLP_FAILED DLP profiles (stale policy references)"
fi
set -e  # Re-enable exit on error

echo -e "${GREEN}✓ MCD cleanup complete for pod${POD_NUMBER}${NC}"
exit 0
