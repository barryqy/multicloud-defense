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
    echo "Please run ./1-init-lab.sh first to set up credentials"
    exit 1
fi

POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ pod_number not found in terraform.tfvars${NC}"
    echo "Please run ./1-init-lab.sh first to configure your pod number"
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

# ════════════════════════════════════════════════════════════
# Pod-Specific State Management
# ════════════════════════════════════════════════════════════
echo -e "${YELLOW}🔧 Setting up pod-specific state...${NC}"

# Source state helper
if [ ! -f ".state-helper.sh" ]; then
    echo -e "${RED}❌ State helper script not found${NC}"
    exit 1
fi

source .state-helper.sh

# Setup pod-specific state directory and symlinks
if ! setup_pod_state; then
    echo -e "${RED}❌ Failed to setup pod-specific state${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Using isolated state for pod${POD_NUMBER}${NC}"
echo ""

# ════════════════════════════════════════════════════════════
# Ensure MCD Resources are Disabled (Step 2 = AWS Only)
# ════════════════════════════════════════════════════════════
# Step 2 deploys AWS infrastructure only.
# MCD resources are deployed in Step 3 (3-secure.sh).
# ════════════════════════════════════════════════════════════

echo -e "${YELLOW}🔧 Ensuring AWS-only deployment...${NC}"

if [ -f "mcd-resources.tf" ]; then
    # Deactivate MCD resources for this step
    mv mcd-resources.tf mcd-resources.tf.disabled
    echo -e "${GREEN}✓ MCD resources disabled (will be deployed in Step 3)${NC}"
elif [ -f "mcd-resources.tf.disabled" ]; then
    echo -e "${GREEN}✓ MCD resources already disabled${NC}"
else
    # If neither exists, that's okay - might be a fresh checkout
    echo -e "${BLUE}ℹ️  No MCD resources file found (will be created if needed)${NC}"
fi

echo -e "${BLUE}ℹ️  Step 2 deploys: VPCs, EC2 instances, Transit Gateway${NC}"
echo -e "${BLUE}ℹ️  Step 3 deploys: MCD policies, Service VPC, gateways${NC}"
echo ""

# ════════════════════════════════════════════════════════════
# Pre-Deployment Check: Detect Existing Resources
# ════════════════════════════════════════════════════════════
echo -e "${YELLOW}🔍 Checking for existing resources...${NC}"

REGION="us-east-1"

# Check for existing EC2 instances
EXISTING_INSTANCES=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1,pod${POD_NUMBER}-app2,pod${POD_NUMBER}-jumpbox" \
              "Name=instance-state-name,Values=running,pending,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null | wc -w | tr -d ' ')

# Check for existing VPCs
EXISTING_VPCS=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-vpc,pod${POD_NUMBER}-app2-vpc,pod${POD_NUMBER}-mgmt-vpc" \
    --query "Vpcs[].VpcId" \
    --output text 2>/dev/null | wc -w | tr -d ' ')

# Check for existing TGW attachments (indicates previous deployment)
EXISTING_TGW_ATTACH=$(aws ec2 describe-transit-gateway-attachments --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
              "Name=state,Values=available,pending" \
    --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" \
    --output text 2>/dev/null | wc -w | tr -d ' ')

# Check for MCD gateways (via instance names)
EXISTING_MCD_GW=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=*pod${POD_NUMBER}*gw*" \
              "Name=instance-state-name,Values=running,pending" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null | wc -w | tr -d ' ')

TOTAL_EXISTING=$((EXISTING_INSTANCES + EXISTING_VPCS + EXISTING_TGW_ATTACH + EXISTING_MCD_GW))

if [ "$TOTAL_EXISTING" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  WARNING: Existing Resources Detected!${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Found existing resources for pod${POD_NUMBER}:${NC}"
    echo "  • EC2 Instances: $EXISTING_INSTANCES"
    echo "  • VPCs: $EXISTING_VPCS"
    echo "  • TGW Attachments: $EXISTING_TGW_ATTACH"
    echo "  • MCD Gateways: $EXISTING_MCD_GW"
    echo ""
    echo -e "${YELLOW}Deploying now will create DUPLICATES (same names, different resources)${NC}"
    echo ""
    echo -e "${BLUE}This can happen if:${NC}"
    echo "  • Previous deployment wasn't cleaned up"
    echo "  • Terraform state was lost (container restart)"
    echo "  • Manual resources were created"
    echo ""
    echo -e "${GREEN}Recommended Actions:${NC}"
    echo "  1. ${GREEN}Clean up first${NC}: ./cleanup/cleanup.sh $POD_NUMBER"
    echo "  2. Use a different pod number"
    echo "  3. Continue anyway (will import existing resources)"
    echo ""
    
    # Give user options
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo "  [1] Run cleanup now and then continue deployment"
    echo "  [2] Continue anyway (attempt to import existing resources)"
    echo "  [3] Cancel deployment"
    echo ""
    read -p "Enter choice (1/2/3): " CHOICE
    
    case $CHOICE in
        1)
            echo ""
            echo -e "${BLUE}Running cleanup for pod${POD_NUMBER}...${NC}"
            echo ""
            # Run cleanup with automatic confirmation
            if ./cleanup/cleanup.sh $POD_NUMBER yes; then
                echo ""
                echo -e "${GREEN}✅ Cleanup complete! Proceeding with deployment...${NC}"
                echo ""
                # Wait a bit for AWS to fully process deletions
                sleep 10
            else
                echo ""
                echo -e "${RED}❌ Cleanup failed or incomplete${NC}"
                echo "Please review the errors above and try again"
                exit 1
            fi
            ;;
        2)
            echo ""
            echo -e "${YELLOW}⚠️  Continuing with existing resources...${NC}"
            echo "Will attempt to import them into Terraform state"
            echo ""
            ;;
        3)
            echo ""
            echo -e "${BLUE}Deployment cancelled${NC}"
            echo ""
            echo "To clean up manually, run:"
            echo "  ./cleanup/cleanup.sh $POD_NUMBER"
            exit 0
            ;;
        *)
            echo ""
            echo -e "${RED}Invalid choice. Deployment cancelled.${NC}"
            exit 1
            ;;
    esac
else
    echo -e "${GREEN}✓ No existing resources found - safe to deploy${NC}"
fi
echo ""

# CRITICAL: Verify shared TGW ID to protect against accidental modifications
# The TGW is shared across all 50 pods and must never be changed
EXPECTED_TGW="tgw-0a878e2f5870e2ccf"
echo -e "${BLUE}🔒 Verifying shared Transit Gateway...${NC}"
if terraform state list 2>/dev/null | grep -q "data.aws_ec2_transit_gateway.tgw"; then
    ACTUAL_TGW=$(terraform state show 'data.aws_ec2_transit_gateway.tgw' 2>/dev/null | grep -m1 '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
    if [ -n "$ACTUAL_TGW" ] && [ "$ACTUAL_TGW" != "$EXPECTED_TGW" ]; then
        echo -e "${RED}❌ CRITICAL ERROR: TGW ID mismatch!${NC}"
        echo -e "${RED}   Expected (shared): $EXPECTED_TGW${NC}"
        echo -e "${RED}   Found in state:    $ACTUAL_TGW${NC}"
        echo ""
                echo -e "${YELLOW}This could affect all 50 pods! Contact instructor immediately.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Shared TGW verified: $EXPECTED_TGW${NC}"
else
    echo -e "${BLUE}ℹ️  TGW will be loaded as data source${NC}"
fi
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
        
        # AWS Key Pair
        "aws_key_pair:sshkeypair:pod${POD_NUMBER}-keypair"
        
        # App VPCs and Core Infrastructure
        "aws_vpc:app_vpc[0]:IMPORT_BY_TAG:pod${POD_NUMBER}-app1-vpc"
        "aws_vpc:app_vpc[1]:IMPORT_BY_TAG:pod${POD_NUMBER}-app2-vpc"
        "aws_subnet:app_subnet[0]:IMPORT_BY_TAG:pod${POD_NUMBER}-app1-subnet"
        "aws_subnet:app_subnet[1]:IMPORT_BY_TAG:pod${POD_NUMBER}-app2-subnet"
        "aws_internet_gateway:int_gw:IMPORT_BY_TAG:pod${POD_NUMBER}-igw"
        "aws_security_group:allow_all[0]:IMPORT_BY_NAME:pod${POD_NUMBER}-app1-sg"
        "aws_security_group:allow_all[1]:IMPORT_BY_NAME:pod${POD_NUMBER}-app2-sg"
        
        # App Instances (CRITICAL: These must be created!)
        "aws_instance:AppMachines[0]:IMPORT_BY_TAG:pod${POD_NUMBER}-app1"
        "aws_instance:AppMachines[1]:IMPORT_BY_TAG:pod${POD_NUMBER}-app2"
        
        # Management VPC and Jumpbox
        "aws_vpc:mgmt_vpc:IMPORT_BY_TAG:pod${POD_NUMBER}-mgmt-vpc"
        "aws_subnet:mgmt_subnet:IMPORT_BY_TAG:pod${POD_NUMBER}-mgmt-subnet"
        "aws_internet_gateway:mgmt_igw:IMPORT_BY_TAG:pod${POD_NUMBER}-mgmt-igw"
        "aws_security_group:jumpbox_sg:IMPORT_BY_NAME:pod${POD_NUMBER}-jumpbox-sg"
        "aws_instance:jumpbox:IMPORT_BY_TAG:pod${POD_NUMBER}-jumpbox"
    )
    
    # NOTE: Transit Gateway (tgw-0a878e2f5870e2ccf) is now a DATA SOURCE in data.tf
    # It is NEVER created or imported - it's a hardcoded reference to the shared TGW
    # This eliminates any possibility of creating duplicate TGWs
    
    for resource_entry in "${RESOURCES_TO_IMPORT[@]}"; do
        IFS=':' read -r res_type res_name res_id <<< "$resource_entry"
        
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
echo -e "${BLUE}Deployment Progress:${NC}"
echo "  → Creating VPCs and networking..."
echo "  → Launching EC2 instances (App1, App2, Jumpbox)..."
echo "  → Configuring security groups and routes..."
echo "  → This will take approximately 5-7 minutes"
echo ""
echo -e "${YELLOW}💡 Tip: Watch for 'Creation complete' messages below${NC}"
echo ""

# Capture output and filter "already exists" errors that we'll handle gracefully
# Using tee to show real-time progress to students
APPLY_OUTPUT=$(terraform apply -input=false -auto-approve tfplan 2>&1 | tee /dev/tty | sanitize_output)
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
    
    # Only check for tainted resources if apply had errors (provisioner failures)
    # This check is SLOW, so we skip it for clean deployments
    if echo "$APPLY_OUTPUT" | grep -qiE "(Error:|provisioner.*failed|remote-exec.*failed|Tainted: true)"; then
        echo -e "${BLUE}🔍 Verifying deployment integrity...${NC}"
        TAINTED_RESOURCES=$(terraform state list 2>/dev/null | while read resource; do
            terraform state show "$resource" 2>/dev/null | grep -q "Tainted: true" && echo "$resource"
        done)
        
        if [ -n "$TAINTED_RESOURCES" ]; then
            echo -e "${YELLOW}⚠️  WARNING: Some resources are marked as TAINTED${NC}"
            echo ""
            echo "Tainted resources (provisioner failures):"
            echo "$TAINTED_RESOURCES" | while read res; do
                echo "  ❌ $res"
            done
            echo ""
            
            # Auto-untaint App instances (they're functional even if provisioners failed)
            APP_INSTANCES=$(echo "$TAINTED_RESOURCES" | grep "aws_instance.AppMachines")
            JUMPBOX_INSTANCE=$(echo "$TAINTED_RESOURCES" | grep "aws_instance.jumpbox")
            
            if [ -n "$APP_INSTANCES" ] || [ -n "$JUMPBOX_INSTANCE" ]; then
                echo -e "${BLUE}ℹ️  Auto-untainting instances (they're functional, just SSH provisioning failed)...${NC}"
                echo ""
                
                echo "$APP_INSTANCES" | while read res; do
                    if [ -n "$res" ]; then
                        terraform untaint "$res" 2>&1 | grep -q "successfully" && \
                            echo -e "  ${GREEN}✓${NC} Untainted $res" || \
                            echo -e "  ${RED}✗${NC} Failed to untaint $res"
                    fi
                done
                
                if [ -n "$JUMPBOX_INSTANCE" ]; then
                    terraform untaint "$JUMPBOX_INSTANCE" 2>&1 | grep -q "successfully" && \
                        echo -e "  ${GREEN}✓${NC} Untainted $JUMPBOX_INSTANCE" || \
                        echo -e "  ${RED}✗${NC} Failed to untaint $JUMPBOX_INSTANCE"
                fi
                
                echo ""
                echo -e "${GREEN}✓ Instances are now clean and won't be replaced on next deployment${NC}"
                echo ""
            fi
            
            # Check if any non-instance resources are still tainted
            OTHER_TAINTED=$(echo "$TAINTED_RESOURCES" | grep -v "aws_instance")
            if [ -n "$OTHER_TAINTED" ]; then
                echo -e "${RED}⚠️  WARNING: Non-instance resources are still tainted:${NC}"
                echo "$OTHER_TAINTED" | while read res; do
                    echo "  ❌ $res"
                done
                echo ""
                echo "These may need manual attention. Contact instructor if unsure."
                echo ""
            fi
        else
            echo -e "${GREEN}✓ All resources are clean (no tainted resources)${NC}"
            echo ""
        fi
    else
        echo -e "${GREEN}✓ Deployment completed cleanly (skipped integrity check)${NC}"
        echo ""
    fi
    
    echo "Your Multicloud Defense lab environment is now ready."
    echo ""
    
    # Export environment variables using helper
    echo -e "${BLUE}📝 Gathering deployment information...${NC}"
    source ./env-helper.sh
    export_deployment_vars
    echo ""
    
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}📡 Server Information${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "%-15s %-20s %-20s %s\n" "Server" "Public IP" "Private IP" "SSH Command"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────"
    printf "%-15s %-20s %-20s %s\n" "Jumpbox" "$JUMPBOX_PUBLIC_IP" "N/A" "ssh -i $SSH_KEY ubuntu@$JUMPBOX_PUBLIC_IP"
    printf "%-15s %-20s %-20s %s\n" "App1" "$APP1_PUBLIC_IP" "$APP1_PRIVATE_IP" "ssh -i $SSH_KEY ubuntu@$APP1_PUBLIC_IP"
    printf "%-15s %-20s %-20s %s\n" "App2" "$APP2_PUBLIC_IP" "$APP2_PRIVATE_IP" "ssh -i $SSH_KEY ubuntu@$APP2_PUBLIC_IP"
    echo ""
    
    echo "Via Jumpbox (always works, unaffected by TGW routing):"
    echo "  1. ssh -i $SSH_KEY ubuntu@$JUMPBOX_PUBLIC_IP"
    echo "  2. Then from jumpbox:"
    echo "       ssh ubuntu@app1  # or: ssh ubuntu@$APP1_PRIVATE_IP"
    echo "       ssh ubuntu@app2  # or: ssh ubuntu@$APP2_PRIVATE_IP"
    echo ""
    
    echo "Direct access (works with IGW routing, may not work with TGW):"
    echo "  • Test App1: http://${APP1_PUBLIC_IP}"
    echo "  • Test App2: http://${APP2_PUBLIC_IP}"
    
    show_deployment_vars
    
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
        
        # Export environment variables using helper
        source ./env-helper.sh
        export_deployment_vars
        
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}📡 Server Information${NC}"
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
        echo ""
        printf "%-15s %-20s %-20s %s\n" "Server" "Public IP" "Private IP" "SSH Command"
        echo "────────────────────────────────────────────────────────────────────────────────────────────────"
        printf "%-15s %-20s %-20s %s\n" "Jumpbox" "$JUMPBOX_PUBLIC_IP" "N/A" "ssh -i $SSH_KEY ubuntu@$JUMPBOX_PUBLIC_IP"
        printf "%-15s %-20s %-20s %s\n" "App1" "$APP1_PUBLIC_IP" "$APP1_PRIVATE_IP" "ssh -i $SSH_KEY ubuntu@$APP1_PUBLIC_IP"
        printf "%-15s %-20s %-20s %s\n" "App2" "$APP2_PUBLIC_IP" "$APP2_PRIVATE_IP" "ssh -i $SSH_KEY ubuntu@$APP2_PUBLIC_IP"
        echo ""
        
        echo "Via Jumpbox (always works, unaffected by TGW routing):"
        echo "  1. ssh -i $SSH_KEY ubuntu@$JUMPBOX_PUBLIC_IP"
        echo "  2. Then from jumpbox:"
        echo "       ssh ubuntu@app1  # or: ssh ubuntu@$APP1_PRIVATE_IP"
        echo "       ssh ubuntu@app2  # or: ssh ubuntu@$APP2_PRIVATE_IP"
        echo ""
        
        echo "Direct access (works with IGW routing, may not work with TGW):"
        echo "  • Test App1: http://${APP1_PUBLIC_IP}"
        echo "  • Test App2: http://${APP2_PUBLIC_IP}"
        
        show_deployment_vars
        
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

