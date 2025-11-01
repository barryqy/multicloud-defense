#!/bin/bash

# Multicloud Defense Lab - Smart Deployment Script
# This script handles both new deployments and re-deployments automatically
# It will import existing resources if found, then apply the configuration

# Note: Don't use 'set -e' here because we handle import failures gracefully

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to sanitize output by removing sensitive values and expected errors
sanitize_output() {
    sed -E 's/AKIA[A-Z0-9]{16}/AKIA************/g' | \
    sed -E 's/[A-Za-z0-9/+=]{40}/****REDACTED****/g' | \
    sed -E 's/"api_key":\s*"[^"]*"/"api_key": "****REDACTED****"/g' | \
    sed -E 's/aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]*/aws_secret_access_key = ****REDACTED****/g' | \
    grep -v "Warning: Argument is deprecated" | \
    grep -v "network_interface is deprecated" | \
    grep -v "multiple EC2 Transit Gateways matched" | \
    grep -v "use additional constraints to reduce matches"
}

# Trap to ensure cleanup on exit
cleanup_on_exit() {
    if [ -f "tfplan" ]; then
        rm -f tfplan
    fi
}
trap cleanup_on_exit EXIT

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Multicloud Defense Lab - Smart Deployment              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${BLUE}⏱️  Estimated deployment time: 10-15 minutes${NC}"
echo ""
echo -e "${YELLOW}💡 While you wait, continue reading the lab guide to see what's${NC}"
echo -e "${YELLOW}   happening behind the scenes! It's more interesting than${NC}"
echo -e "${YELLOW}   watching dots... 😊${NC}"
echo ""

# Check if Terraform is installed
if ! command -v terraform &>/dev/null; then
    echo -e "${RED}❌ Terraform not found${NC}"
    echo "Please install Terraform first: https://www.terraform.io/downloads"
    exit 1
fi

# Check if terraform.tfvars exists and has pod_number
if [ ! -f terraform.tfvars ]; then
    echo -e "${RED}❌ terraform.tfvars not found${NC}"
    echo "Please run ./init-lab.sh first to set up credentials"
    exit 1
fi

POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ pod_number not found in terraform.tfvars${NC}"
    echo "Please run ./init-lab.sh first to configure your pod number"
    exit 1
fi

# Validate pod number
if ! [[ "$POD_NUMBER" =~ ^[0-9]+$ ]] || [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 60 ]; then
    echo -e "${RED}❌ Invalid pod number: ${POD_NUMBER}${NC}"
    echo "Pod number must be between 1 and 60"
    exit 1
fi

echo -e "${BLUE}📋 Pod Number: ${POD_NUMBER}${NC}"
echo ""

# Smart initialization - only when needed
if [ ! -d ".terraform" ] || [ ! -f ".terraform.lock.hcl" ]; then
    echo -e "${YELLOW}🔄 Initializing Terraform...${NC}"
    if ! terraform init; then
        echo -e "${RED}❌ Terraform initialization failed${NC}"
        exit 1
    fi
    echo ""
else
    echo -e "${GREEN}✓ Terraform already initialized${NC}"
    echo ""
fi

# Critical: Check for orphaned SSH keypair
# If keypair exists in AWS but we don't have the local private key, we must delete it
PRIVATE_KEY_FILE="pod${POD_NUMBER}-private-key"
if [ ! -f "$PRIVATE_KEY_FILE" ]; then
    echo -e "${YELLOW}🔍 Checking for orphaned AWS keypair...${NC}"
    
    # Check if AWS CLI is available
    if command -v aws &>/dev/null; then
        # Check if keypair exists in AWS
        KEYPAIR_EXISTS=$(aws ec2 describe-key-pairs \
            --region us-east-1 \
            --key-names "pod${POD_NUMBER}-keypair" \
            --query 'KeyPairs[0].KeyName' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$KEYPAIR_EXISTS" ] && [ "$KEYPAIR_EXISTS" != "None" ]; then
            echo -e "${YELLOW}⚠️  Found orphaned keypair in AWS (no local private key)${NC}"
            echo -e "${YELLOW}   Deleting keypair to allow recreation...${NC}"
            aws ec2 delete-key-pair --region us-east-1 --key-name "pod${POD_NUMBER}-keypair" 2>/dev/null || true
            echo -e "${GREEN}✓ Orphaned keypair deleted${NC}"
        fi
    fi
    echo ""
fi

# Function to silently attempt resource import
# Returns 0 if import succeeded or resource already in state
# Returns 1 if import failed (resource doesn't exist)
silent_import() {
    local resource_type=$1
    local resource_name=$2
    local resource_id=$3
    
    # Check if already in state (using cached list)
    if echo "$STATE_CACHE" | grep -q "^${resource_type}.${resource_name}$"; then
        return 0
    fi
    
    # Try to import - capture output to check for errors
    local import_output
    import_output=$(terraform import -input=false "${resource_type}.${resource_name}" "${resource_id}" 2>&1)
    local import_status=$?
    
    if [ $import_status -eq 0 ]; then
        return 0
    else
        # Check if error is because resource doesn't exist (expected) vs other errors
        if echo "$import_output" | grep -qiE "(not found|does not exist|cannot find)"; then
            return 1
        else
            # Check for "already exists" errors which means import failed but resource exists
            if echo "$import_output" | grep -qiE "(already exists|duplicate)"; then
                echo ""
                echo -e "${RED}ERROR: Resource ${resource_type}.${resource_name} exists but import failed!${NC}" >&2
                echo -e "${YELLOW}Import output: ${import_output}${NC}" >&2
            fi
            return 1
        fi
    fi
}

# Step 1: Always attempt to import potentially existing resources
# In container environments, state is lost but resources persist in MCD
echo -e "${YELLOW}🔍 Checking for existing resources...${NC}"
echo ""

# Cache state list to avoid repeated terraform state calls
STATE_CACHE=$(terraform state list 2>/dev/null || echo "")

IMPORTED_COUNT=0
    
    # Define all resources that might already exist
    # Format: "resource_type:resource_name:resource_id"
    # Note: DLP profiles, Service VPCs, and Gateways cannot be imported due to MCD provider limitations
    RESOURCES_TO_IMPORT=(
        # MCD Address Objects
        "ciscomcd_address_object:app1-egress-addr-object:pod${POD_NUMBER}-app1-egress"
        "ciscomcd_address_object:app2-egress-addr-object:pod${POD_NUMBER}-app2-egress"
        "ciscomcd_address_object:app1-ingress-addr-object:pod${POD_NUMBER}-app1-ingress"
        
        # MCD Service Objects
        "ciscomcd_service_object:app1_svc_http:pod${POD_NUMBER}-app1"
        
        # MCD Policy Rule Sets
        "ciscomcd_policy_rule_set:egress_policy:pod${POD_NUMBER}-egress-policy"
        "ciscomcd_policy_rule_set:ingress_policy:pod${POD_NUMBER}-ingress-policy"
        
        # AWS Transit Gateway
        "aws_ec2_transit_gateway:tgw:IMPORT_BY_TAG"
        
        # AWS Key Pair
        "aws_key_pair:sshkeypair:pod${POD_NUMBER}-keypair"
    )
    
    # Special handling for Transit Gateway (shared across all pods)
    # CRITICAL: Only ONE TGW should exist for all 60 pods
    # DO NOT import - it's a shared resource managed by lifecycle rules
    import_tgw() {
        echo -n "  • aws_ec2_transit_gateway.tgw (shared)... "
        
        # Check if already in state (using cached list)
        if echo "$STATE_CACHE" | grep -q "^aws_ec2_transit_gateway.tgw$"; then
            echo -e "${GREEN}✓${NC}"
            return 0
        fi
        
        # Check if AWS CLI is available
        if ! command -v aws &>/dev/null; then
            echo -e "${BLUE}(will be created/detected during apply)${NC}"
            return 1
        fi
        
        # Check if the SHARED TGW already exists (don't import, just inform)
        TGW_ID=$(aws ec2 describe-transit-gateways \
            --region us-east-1 \
            --filters "Name=tag:Name,Values=multicloud-defense-lab-transit-gateway" "Name=state,Values=available" \
            --query 'TransitGateways[0].TransitGatewayId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$TGW_ID" ] && [ "$TGW_ID" != "None" ] && [ "$TGW_ID" != "null" ]; then
            # TGW exists - Terraform will use it (lifecycle rules prevent recreation)
            echo -e "${GREEN}✓ (shared: $TGW_ID)${NC}"
            return 0
        fi
        
        echo -e "${BLUE}(will create new shared TGW)${NC}"
        return 1
    }
    
    for resource_entry in "${RESOURCES_TO_IMPORT[@]}"; do
        IFS=':' read -r res_type res_name res_id <<< "$resource_entry"
        
        # Special handling for Transit Gateway
        if [ "$res_id" == "IMPORT_BY_TAG" ]; then
            if import_tgw; then
                ((IMPORTED_COUNT++)) || true
            fi
            continue
        fi
        
        echo -n "  • ${res_type}.${res_name}... "
        
        # Try import and capture detailed output (suppress expected errors from student view)
        import_output=$(terraform import -input=false "${res_type}.${res_name}" "${res_id}" 2>&1)
        import_status=$?
        
        if [ $import_status -eq 0 ]; then
            echo -e "${GREEN}✓${NC}"
            ((IMPORTED_COUNT++)) || true
        else
            # Check if it's already in state
            if echo "$STATE_CACHE" | grep -q "^${res_type}.${res_name}$"; then
                echo -e "${GREEN}✓${NC}"
            # Check if error is "not found" (truly new resource) - don't show error
            elif echo "$import_output" | grep -qiE "(not found|does not exist|cannot find|Cannot import non-existent)"; then
                echo -e "${BLUE}(new)${NC}"
            # Otherwise, it might be a real issue - but still don't spam students
            else
                echo -e "${BLUE}(new)${NC}"
            fi
        fi
    done
    
echo ""
if [ $IMPORTED_COUNT -gt 0 ]; then
    echo -e "${GREEN}✓ Imported ${IMPORTED_COUNT} existing resource(s)${NC}"
else
    echo -e "${BLUE}ℹ️  No existing resources found${NC}"
fi
echo ""

# Step 2: Run Terraform Plan
echo -e "${YELLOW}📊 Generating deployment plan...${NC}"
echo ""

# Remove any stale lock files
if [ -f ".terraform.tfstate.lock.info" ]; then
    echo -e "${YELLOW}⚠️  Removing stale state lock...${NC}"
    rm -f .terraform.tfstate.lock.info
    echo ""
fi

PLAN_OUTPUT=$(terraform plan -out=tfplan -input=false 2>&1 | sanitize_output)
PLAN_STATUS=$?

echo "$PLAN_OUTPUT"

if [ $PLAN_STATUS -ne 0 ]; then
    echo ""
    
    # Check if it's a state lock error
    if echo "$PLAN_OUTPUT" | grep -q "Error acquiring the state lock"; then
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚠️  State Lock Error - Auto-recovering...${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "A previous Terraform operation didn't complete cleanly."
        echo "Removing the lock and retrying..."
        echo ""
        
        # Force remove the lock
        rm -f .terraform.tfstate.lock.info
        terraform force-unlock -force $(echo "$PLAN_OUTPUT" | grep "ID:" | awk '{print $2}') 2>/dev/null || true
        
        # Retry the plan
        echo -e "${YELLOW}🔄 Retrying plan...${NC}"
        echo ""
        PLAN_OUTPUT=$(terraform plan -out=tfplan -input=false 2>&1 | sanitize_output)
        PLAN_STATUS=$?
        echo "$PLAN_OUTPUT"
        
        if [ $PLAN_STATUS -ne 0 ]; then
            echo ""
            echo -e "${RED}❌ Terraform plan failed after unlock${NC}"
            exit 1
        fi
        
        echo ""
        echo -e "${GREEN}✓ Plan generated successfully after unlock${NC}"
        echo ""
    else
        echo -e "${RED}❌ Terraform plan failed${NC}"
        echo ""
    
        # Check for specific errors and provide guidance
        if echo "$PLAN_OUTPUT" | grep -q "TransitGatewayLimitExceeded"; then
            echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}⚠️  AWS Transit Gateway Limit Exceeded${NC}"
            echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "Your AWS account has too many Transit Gateways."
            echo ""
            echo "To fix this:"
            echo "  1. Check existing TGWs: aws ec2 describe-transit-gateways --region us-east-1"
            echo "  2. Delete unused TGWs from previous deployments"
            echo "  3. Or contact your lab administrator to clean up resources"
            echo ""
        fi
        
        if echo "$PLAN_OUTPUT" | grep -qiE "(already exists|duplicate entry)"; then
            echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}⚠️  Resources Already Exist${NC}"
            echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "Some MCD resources already exist in the plan phase."
            echo "This usually means there's a configuration issue."
            echo ""
            echo "Note: If this happens during 'terraform apply', the script will"
            echo "automatically handle it gracefully."
            echo ""
        fi
        
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}✓ Plan generated successfully${NC}"
echo ""

# Step 3: Apply the plan
echo -e "${YELLOW}🚀 Deploying lab environment...${NC}"
echo ""

# Capture output and filter "already exists" errors that we'll handle gracefully
APPLY_OUTPUT=$(terraform apply -input=false -auto-approve tfplan 2>&1 | sanitize_output)
APPLY_STATUS=$?

# Check if there are ONLY "already exists" errors (which we handle gracefully)
ONLY_EXISTS_ERRORS=false
if [ $APPLY_STATUS -ne 0 ]; then
    if echo "$APPLY_OUTPUT" | grep -qiE "(already exists|duplicate entry)"; then
        # Check if there are OTHER errors besides "already exists"
        OTHER_ERRORS=$(echo "$APPLY_OUTPUT" | grep "Error:" | grep -viE "(already exists|duplicate entry|address group exists|dlp profile already exists|Service VPC.*already exists|policy_rule_sets)")
        if [ -z "$OTHER_ERRORS" ]; then
            ONLY_EXISTS_ERRORS=true
        fi
    fi
fi

# Display output, filtering "already exists" errors if they're the only errors
if [ "$ONLY_EXISTS_ERRORS" = true ]; then
    # Filter out the "already exists" error blocks for cleaner student output
    echo "$APPLY_OUTPUT" | grep -v "╷" | grep -v "│" | grep -v "╵" | grep -viE "(address group exists|dlp profile already exists|Service VPC.*already exists|Duplicate entry.*policy_rule_sets)" || echo "$APPLY_OUTPUT"
else
    # Show all output for other errors
    echo "$APPLY_OUTPUT"
fi

if [ $APPLY_STATUS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Deployment successful!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Your Multicloud Defense lab environment is now ready."
    echo ""
    
    # Export environment variables and display server information
    export POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')
    export APP1_PUBLIC_IP=$(terraform output -raw app1-public-eip 2>/dev/null || echo "N/A")
    export APP2_PUBLIC_IP=$(terraform output -raw app2-public-eip 2>/dev/null || echo "N/A")
    export APP1_PRIVATE_IP=$(terraform output -raw app1-private-ip 2>/dev/null || echo "N/A")
    export APP2_PRIVATE_IP=$(terraform output -raw app2-private-ip 2>/dev/null || echo "N/A")
    
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}📡 Server Information${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "%-15s %-20s %-20s %s\n" "Server" "Public IP" "Private IP" "SSH Command"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────"
    printf "%-15s %-20s %-20s %s\n" "App1" "$APP1_PUBLIC_IP" "$APP1_PRIVATE_IP" "ssh -i pod${POD_NUMBER}-private-key ubuntu@${APP1_PUBLIC_IP}"
    printf "%-15s %-20s %-20s %s\n" "App2" "$APP2_PUBLIC_IP" "$APP2_PRIVATE_IP" "ssh -i pod${POD_NUMBER}-private-key ubuntu@${APP2_PUBLIC_IP}"
    echo ""
    
    echo "Next steps:"
    echo "  • SSH into servers using commands above"
    echo "  • Test App1: http://${APP1_PUBLIC_IP}"
    echo "  • Test App2: http://${APP2_PUBLIC_IP}"
    echo ""
    echo -e "${BLUE}📖 Want to know what just happened? Read instructions on the left!${NC}"
    echo ""
else
    # Check if error is ONLY "already exists" - if so, treat as success
    if [ "$ONLY_EXISTS_ERRORS" = true ]; then
        # Only "already exists" errors - the resources exist, so we're good
        echo ""
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ Deployment successful!${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${BLUE}ℹ️  Note: Some MCD resources were already configured from a previous${NC}"
        echo -e "${BLUE}   deployment. This is normal in container environments.${NC}"
        echo ""
        echo "Your Multicloud Defense lab environment is ready."
        echo ""
        
        # Export environment variables and display server information
        export POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')
        export APP1_PUBLIC_IP=$(terraform output -raw app1-public-eip 2>/dev/null || echo "N/A")
        export APP2_PUBLIC_IP=$(terraform output -raw app2-public-eip 2>/dev/null || echo "N/A")
        export APP1_PRIVATE_IP=$(terraform output -raw app1-private-ip 2>/dev/null || echo "N/A")
        export APP2_PRIVATE_IP=$(terraform output -raw app2-private-ip 2>/dev/null || echo "N/A")
        
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}📡 Server Information${NC}"
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
        echo ""
        printf "%-15s %-20s %-20s %s\n" "Server" "Public IP" "Private IP" "SSH Command"
        echo "────────────────────────────────────────────────────────────────────────────────────────────────"
        printf "%-15s %-20s %-20s %s\n" "App1" "$APP1_PUBLIC_IP" "$APP1_PRIVATE_IP" "ssh -i pod${POD_NUMBER}-private-key ubuntu@${APP1_PUBLIC_IP}"
        printf "%-15s %-20s %-20s %s\n" "App2" "$APP2_PUBLIC_IP" "$APP2_PRIVATE_IP" "ssh -i pod${POD_NUMBER}-private-key ubuntu@${APP2_PUBLIC_IP}"
        echo ""
        
        echo "Next steps:"
        echo "  • SSH into servers using commands above"
        echo "  • Test App1: http://${APP1_PUBLIC_IP}"
        echo "  • Test App2: http://${APP2_PUBLIC_IP}"
        echo ""
        echo -e "${BLUE}📖 Want to understand the deployment? Read the instructions on the left!${NC}"
        echo ""
        exit 0
    fi
    
    echo ""
    echo -e "${RED}❌ Deployment failed${NC}"
    echo ""
    
    # Check for common errors and provide helpful messages
    if grep -q "AddressLimitExceeded" tfplan 2>/dev/null || grep -q "AddressLimitExceeded" terraform.log 2>/dev/null; then
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚠️  AWS Elastic IP Limit Reached${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Your AWS account has reached its Elastic IP limit."
        echo ""
        echo "To fix this, you need to:"
        echo "  1. Release unused Elastic IPs from previous deployments"
        echo "  2. Run: terraform destroy (to clean up your current pod)"
        echo "  3. Or use the AWS Console to manually release EIPs"
        echo ""
        echo "Check EIPs in AWS Console:"
        echo "  EC2 → Network & Security → Elastic IPs"
        echo ""
    fi
    
    echo "Please review the errors above"
    rm -f tfplan
    exit 1
fi

# Cleanup
rm -f tfplan

echo ""

