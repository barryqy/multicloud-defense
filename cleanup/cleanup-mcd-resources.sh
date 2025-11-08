#!/bin/bash

# Cisco Multicloud Defense - Resource Cleanup Script
# This script removes MCD resources for a specific pod using the MCD API

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Cisco Multicloud Defense - Resource Cleanup          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq is not installed${NC}"
    echo "jq is required for MCD API calls."
    echo "Install: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Get pod number from argument or terraform.tfvars
if [ -n "$1" ]; then
    POD_NUMBER="$1"
else
    # Try to get from terraform.tfvars
    if [ -f "../terraform.tfvars" ]; then
        POD_NUMBER=$(grep -E '^pod_number' ../terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')
    fi
fi

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ Pod number not found${NC}"
    echo ""
    echo "Usage: $0 [pod_number]"
    echo "Or ensure terraform.tfvars exists in parent directory"
    exit 1
fi

echo -e "${BLUE}Pod Number: ${POD_NUMBER}${NC}"
echo ""

# Determine the correct path to .terraform directory
# This script can be called from cleanup/ directory or project root
if [ -d "../.terraform" ]; then
    # Called from cleanup/ subdirectory
    MCD_CREDS_FILE="../.terraform/.mcd-api.json"
elif [ -d ".terraform" ]; then
    # Called from project root
    MCD_CREDS_FILE=".terraform/.mcd-api.json"
else
    echo -e "${YELLOW}⚠️  MCD credentials directory not found${NC}"
    echo ""
    echo "This usually means you haven't run 1-init-lab.sh yet."
    echo ""
    echo "MCD resources will be skipped in cleanup."
    echo "If you deployed MCD resources, you can manually delete them:"
    echo "  1. Log into MCD Console: https://prod1.mcd.us.cdo.cisco.com"
    echo "  2. Navigate to each section and delete pod${POD_NUMBER} resources:"
    echo "     • Manage → Gateways → Delete pod${POD_NUMBER}-*-gw"
    echo "     • Manage → Service VPCs → Delete pod${POD_NUMBER}-svpc-aws"
    echo "     • Manage → Profiles → Security Policies → Rule Sets"
    echo "     • Manage → Profiles → DLP → Delete pod${POD_NUMBER}-block-ssn"
    echo "     • Manage → Network Objects"
    echo ""
    exit 0
fi

# Check if MCD API credentials exist
if [ ! -f "$MCD_CREDS_FILE" ]; then
    echo -e "${YELLOW}⚠️  MCD API credentials file not found${NC}"
    echo -e "${YELLOW}   Expected: $MCD_CREDS_FILE${NC}"
    echo ""
    echo "This usually means you haven't run 1-init-lab.sh to fetch credentials."
    echo ""
    echo "MCD resources will be skipped in cleanup."
    echo "If you deployed MCD resources, you can manually delete them from the console."
    echo ""
    exit 0
fi

# Load MCD API credentials (decode base64)
API_KEY=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.apiKeyID' 2>/dev/null)
API_SECRET=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.apiKeySecret' 2>/dev/null)
ACCT_NAME=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.acctName' 2>/dev/null)
BASE_URL="https://$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.restAPIServer' 2>/dev/null)"

if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
    echo -e "${RED}❌ Invalid MCD API credentials${NC}"
    exit 1
fi

echo -e "${BLUE}MCD Account: ${ACCT_NAME}${NC}"
echo -e "${BLUE}API Server: ${BASE_URL}${NC}"
echo ""

# Function to get JWT access token
get_access_token() {
    echo -e "${YELLOW}🔑 Authenticating with MCD API...${NC}"
    
    TOKEN_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/user/gettoken" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"apiKeyID\":\"$API_KEY\",\"apiKeySecret\":\"$API_SECRET\"}" 2>&1)
    
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.accessToken' 2>/dev/null)
    
    if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
        echo -e "${RED}❌ Failed to get MCD access token${NC}"
        echo "Response: $TOKEN_RESPONSE"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Authenticated successfully${NC}"
    echo ""
}

# Function to delete a gateway
delete_gateway() {
    local gateway_type=$1  # "ingress" or "egress"
    
    echo -e "${YELLOW}🔍 Looking for ${gateway_type} gateways for pod${POD_NUMBER}...${NC}"
    
    # List all gateways and find any that contain pod number
    GATEWAYS_RESPONSE=$(curl -s -k -X POST "${BASE_URL}/api/v1/gateway/list" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"detail\":true}" 2>&1)
    
    # Find ALL gateways matching pod number and type
    # Look for patterns like: pod48-ingress-gw, ciscomcd-pod48-ingress-gw-aws-*, etc.
    MATCHING_GATEWAYS=$(echo "$GATEWAYS_RESPONSE" | jq -r ".gateways[]? | select(.name | test(\"pod${POD_NUMBER}.*${gateway_type}\"; \"i\")) | .name" 2>/dev/null)
    
    if [ -z "$MATCHING_GATEWAYS" ]; then
        echo -e "${BLUE}   ℹ️  No ${gateway_type} gateways found for pod${POD_NUMBER}${NC}"
        return 0
    fi
    
    # Delete each matching gateway
    echo "$MATCHING_GATEWAYS" | while IFS= read -r gateway_name; do
        if [ -n "$gateway_name" ]; then
            echo -e "${YELLOW}   • Found gateway: ${gateway_name}${NC}"
            
            # CRITICAL: First DISABLE gateway (prevents auto-recreation of instances)
            echo -e "${YELLOW}     - Disabling...${NC}"
            DISABLE_RESPONSE=$(curl -s -k -X POST "${BASE_URL}/api/v1/gateway/disable" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$gateway_name\"}" 2>&1)
            
            # Check for errors on disable
            ERROR_MSG=$(echo "$DISABLE_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
            if [ -n "$ERROR_MSG" ]; then
                echo -e "${YELLOW}     ⚠️  Warning during disable: $ERROR_MSG${NC}"
            else
                echo -e "${GREEN}     ✓ Disabled${NC}"
            fi
            
            # Wait for state change to propagate
            sleep 2
            
            # Now delete the gateway
            echo -e "${YELLOW}     - Deleting...${NC}"
            DELETE_RESPONSE=$(curl -s -k -X POST "${BASE_URL}/api/v1/gateway/delete" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"Valtix-2022\"},\"name\":\"$gateway_name\"}" 2>&1)
            
            # Check if delete was successful
            ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
            if [ -n "$ERROR_MSG" ]; then
                echo -e "${RED}     ⚠️  Error deleting: $ERROR_MSG${NC}"
            else
                echo -e "${GREEN}     ✓ Deleted${NC}"
            fi
        fi
    done
    
    echo -e "${BLUE}   ℹ️  AWS will automatically terminate gateway EC2 instances${NC}"
    return 0
}

# Function to delete a Service VPC
delete_service_vpc() {
    local svpc_name=$1
    
    echo -e "${YELLOW}🔍 Looking for Service VPC: ${svpc_name}${NC}"
    
    # List all Service VPCs
    SVPC_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/transit/vpc/list" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"}}" 2>&1)
    
    # Extract Service VPC ID
    SVPC_ID=$(echo "$SVPC_RESPONSE" | jq -r ".svpcs[] | select(.name == \"$svpc_name\") | .id" 2>/dev/null)
    
    if [ -z "$SVPC_ID" ] || [ "$SVPC_ID" == "null" ]; then
        echo -e "${BLUE}   ℹ️  Service VPC not found (may already be deleted)${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}   • Found Service VPC ID: ${SVPC_ID}${NC}"
    echo -e "${YELLOW}   • Deleting...${NC}"
    
    DELETE_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/transit/vpc/delete" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"id\":$SVPC_ID}" 2>&1)
    
    ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$ERROR_MSG" ]; then
        echo -e "${RED}   ⚠️  Error deleting Service VPC: $ERROR_MSG${NC}"
        return 1
    fi
    
    echo -e "${GREEN}   ✓ Service VPC deleted${NC}"
    return 0
}

# Function to delete a Policy Rule Set
delete_policy_ruleset() {
    local ruleset_name=$1
    
    echo -e "${YELLOW}🔍 Looking for Policy Rule Set: ${ruleset_name}${NC}"
    
    # List all policy rule sets
    RULESET_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/services/ruleset/list" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"}}" 2>&1)
    
    # Extract rule set ID
    RULESET_ID=$(echo "$RULESET_RESPONSE" | jq -r ".rulesets[] | select(.name == \"$ruleset_name\") | .id" 2>/dev/null)
    
    if [ -z "$RULESET_ID" ] || [ "$RULESET_ID" == "null" ]; then
        echo -e "${BLUE}   ℹ️  Policy Rule Set not found (may already be deleted)${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}   • Found Rule Set ID: ${RULESET_ID}${NC}"
    echo -e "${YELLOW}   • Deleting...${NC}"
    
    DELETE_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/services/ruleset/delete" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"id\":$RULESET_ID}" 2>&1)
    
    ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$ERROR_MSG" ]; then
        echo -e "${RED}   ⚠️  Error deleting Policy Rule Set: $ERROR_MSG${NC}"
        return 1
    fi
    
    echo -e "${GREEN}   ✓ Policy Rule Set deleted${NC}"
    return 0
}

# Function to delete a DLP profile
delete_dlp_profile() {
    local profile_name=$1
    
    echo -e "${YELLOW}🔍 Looking for DLP Profile: ${profile_name}${NC}"
    
    # List all DLP profiles
    DLP_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/services/dlp/profile/list" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"}}" 2>&1)
    
    # Extract DLP profile ID
    PROFILE_ID=$(echo "$DLP_RESPONSE" | jq -r ".profiles[] | select(.name == \"$profile_name\") | .id" 2>/dev/null)
    
    if [ -z "$PROFILE_ID" ] || [ "$PROFILE_ID" == "null" ]; then
        echo -e "${BLUE}   ℹ️  DLP Profile not found (may already be deleted)${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}   • Found DLP Profile ID: ${PROFILE_ID}${NC}"
    echo -e "${YELLOW}   • Deleting...${NC}"
    
    DELETE_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/services/dlp/profile/delete" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"id\":$PROFILE_ID}" 2>&1)
    
    ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$ERROR_MSG" ]; then
        echo -e "${RED}   ⚠️  Error deleting DLP Profile: $ERROR_MSG${NC}"
        return 1
    fi
    
    echo -e "${GREEN}   ✓ DLP Profile deleted${NC}"
    return 0
}

# Main cleanup process
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Starting MCD Resource Cleanup for Pod ${POD_NUMBER}${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Get access token
get_access_token

# Delete resources in the correct order (dependencies matter!)

# Step 0: Remove MCD resources from Terraform state first
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Step 0: Removing MCD Resources from Terraform State${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Check if we're in the cleanup directory and cd to parent if needed
if [ -f "../terraform.tfstate" ] || [ -f "../terraform.tfstate.d" ]; then
    echo -e "${BLUE}   ℹ️  Found Terraform state in parent directory${NC}"
    cd ..
    
    # List MCD resources in state
    MCD_RESOURCES=$(terraform state list 2>/dev/null | grep -E "ciscomcd|mcd" || echo "")
    
    if [ -n "$MCD_RESOURCES" ]; then
        echo -e "${YELLOW}   • Found MCD resources in state:${NC}"
        echo "$MCD_RESOURCES" | while IFS= read -r resource; do
            if [ -n "$resource" ]; then
                echo "     - $resource"
                terraform state rm "$resource" > /dev/null 2>&1 && \
                    echo -e "${GREEN}       ✓ Removed from state${NC}" || \
                    echo -e "${YELLOW}       ⚠️  Could not remove${NC}"
            fi
        done
    else
        echo -e "${BLUE}   ℹ️  No MCD resources found in Terraform state${NC}"
    fi
    
    cd cleanup
else
    echo -e "${BLUE}   ℹ️  No Terraform state found (may be running from different directory)${NC}"
fi
echo ""

# 1. Delete Gateways first (they depend on Service VPC)
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Step 1: Deleting Gateways${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
delete_gateway "ingress" || true
delete_gateway "egress" || true
echo ""

# 2. Delete Policy Rule Sets (they may reference other objects)
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Step 2: Deleting Policy Rule Sets${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
delete_policy_ruleset "pod${POD_NUMBER}-ingress-policy" || true
delete_policy_ruleset "pod${POD_NUMBER}-egress-policy" || true
echo ""

# 3. Delete Service VPC
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Step 3: Deleting Service VPC${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
delete_service_vpc "pod${POD_NUMBER}-svpc-aws" || true
echo ""

# 4. Delete DLP Profile (can be deleted independently)
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Step 4: Deleting DLP Profile${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
delete_dlp_profile "block-ssn-dlp" || true
echo ""

# Note about Address/Service/Network Objects
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ℹ️  Note: Address Objects, Service Objects, and Network Objects${NC}"
echo -e "${BLUE}   These are typically deleted automatically when their parent${NC}"
echo -e "${BLUE}   policy rule sets are deleted. If they persist, Terraform${NC}"
echo -e "${BLUE}   will handle them on the next deployment.${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ MCD Resource Cleanup Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}What was cleaned:${NC}"
echo "  ✓ Gateways (Ingress and Egress)"
echo "  ✓ Policy Rule Sets (Ingress and Egress)"
echo "  ✓ Service VPC"
echo "  ✓ DLP Profile"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  • Run ./cleanup.sh to clean up AWS resources"
echo "  • Or run ./2-deploy.sh to redeploy with fresh configuration"
echo ""

