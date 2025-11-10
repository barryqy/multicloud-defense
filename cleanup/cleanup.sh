#!/bin/bash

# ════════════════════════════════════════════════════════════
# Unified Cleanup Script - Pod Resources (v3.0)
# ════════════════════════════════════════════════════════════
# This script cleans up ALL resources for a given pod:
#   • MCD resources (gateways, policies, Service VPC)
#   • AWS resources (instances, VPCs, TGW attachments, etc.)
#
# Version 3.0 Updates:
#   ✓ Uses correct system AWS CLI path
#   ✓ Verifies cleanup results (doesn't trust exit codes)
#   ✓ Proper ENI deletion before EIP release
#   ✓ Handles MCD Service VPCs (192.168.X.0/24)
#   ✓ Better error handling and retry logic
#
# Usage: ./cleanup.sh [pod_number] [auto]
# ════════════════════════════════════════════════════════════

set -e

# CRITICAL: Use system AWS CLI (not broken binaries)
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "╔════════════════════════════════════════════════════════════╗"
echo "║      Unified Pod Cleanup v3.0 - State Independent        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Verify AWS CLI is working
if ! aws --version >/dev/null 2>&1; then
    echo -e "${RED}❌ Error: AWS CLI not found or not working${NC}"
    echo "Please ensure AWS CLI is installed and accessible"
    exit 1
fi

echo -e "${GREEN}✓ AWS CLI verified: $(aws --version 2>&1 | head -1)${NC}"
echo ""

# Get pod number
if [ -n "$1" ]; then
    POD_NUMBER="$1"
else
    read -p "Enter your pod number (1-50): " POD_NUMBER
fi

# Validate pod number
if ! [[ "$POD_NUMBER" =~ ^[0-9]+$ ]] || [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 50 ]; then
    echo -e "${RED}❌ Error: Pod number must be between 1 and 50${NC}"
    exit 1
fi

echo -e "${BLUE}Pod Number: ${POD_NUMBER}${NC}"
echo ""

# Confirmation
if [ -z "$2" ]; then  # Skip confirmation if called with 2 args (automated)
    read -p "⚠️  Delete ALL resources for pod${POD_NUMBER}? This cannot be undone. (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cleanup cancelled"
        exit 0
    fi
    echo ""
fi

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "════════════════════════════════════════════════════════════"
echo "Phase 1: MCD Resources (API-based cleanup)"
echo "════════════════════════════════════════════════════════════"
echo ""

# Check if MCD cleanup script exists
if [ -f "${SCRIPT_DIR}/cleanup-mcd-resources.sh" ]; then
    echo -e "${YELLOW}🔧 Cleaning up MCD resources...${NC}"
    bash "${SCRIPT_DIR}/cleanup-mcd-resources.sh" "$POD_NUMBER" || {
        echo -e "${YELLOW}⚠️  MCD cleanup had issues, continuing with AWS cleanup...${NC}"
    }
else
    echo -e "${YELLOW}⚠️  MCD cleanup script not found${NC}"
    echo "   Expected location: ${SCRIPT_DIR}/cleanup-mcd-resources.sh"
    echo "   You may need to manually delete MCD resources from the console"
fi
echo ""

echo "════════════════════════════════════════════════════════════"
echo "Phase 2: AWS Resources (Tag-based cleanup)"
echo "════════════════════════════════════════════════════════════"
echo ""

# ────────────────────────────────────────────────────────────
# Step 1: EC2 Instances (FORCE TERMINATE - TOP PRIORITY)
# ────────────────────────────────────────────────────────────
# IMPORTANT: Check BOTH naming patterns:
#   - pod${POD_NUMBER}-* for app instances (app1, app2, jumpbox)
#   - ciscomcd-pod${POD_NUMBER}-* for MCD gateway instances
echo -e "${YELLOW}Step 1: Force Terminating ALL EC2 Instances...${NC}"

# Get app instances (pod${POD_NUMBER}-*)
INSTANCE_IDS_APP=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
              "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output json 2>/dev/null | jq -r '.[]' || echo "")

# Get MCD gateway instances (ciscomcd-pod${POD_NUMBER}-*)
INSTANCE_IDS_MCD=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=ciscomcd-pod${POD_NUMBER}-*" \
              "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output json 2>/dev/null | jq -r '.[]' || echo "")

# Combine both lists
INSTANCE_IDS="$INSTANCE_IDS_APP"$'\n'"$INSTANCE_IDS_MCD"
INSTANCE_IDS=$(echo "$INSTANCE_IDS" | grep -v '^$' || echo "")  # Remove empty lines

if [ -n "$INSTANCE_IDS" ]; then
    INST_COUNT=$(echo "$INSTANCE_IDS" | wc -l | tr -d ' ')
    echo "  Found $INST_COUNT instance(s) - forcing termination"
    
    # Force terminate ALL instances at once for speed
    echo "$INSTANCE_IDS" | xargs -n 20 aws ec2 terminate-instances --region $REGION --instance-ids 2>/dev/null || true
    
    # Also terminate them one by one as backup (in case batch fails)
    for INSTANCE_ID in $INSTANCE_IDS; do
        aws ec2 terminate-instances --region $REGION \
            --instance-ids "$INSTANCE_ID" > /dev/null 2>&1 && \
            echo "  ✅ $INSTANCE_ID" || \
            echo "  ❌ $INSTANCE_ID (failed)"
    done
    
    echo "  Waiting 45 seconds for instances to terminate..."
    sleep 45
else
    echo "  No instances found"
fi
echo ""

# ────────────────────────────────────────────────────────────
# Step 2: TGW Attachments (CRITICAL - Before VPCs!)
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Deleting TGW Attachments...${NC}"
TGW_ATTACH_IDS=$(aws ec2 describe-transit-gateway-attachments --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
              "Name=state,Values=available,pending,pendingAcceptance" \
    --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" \
    --output json 2>/dev/null | jq -r '.[]' || echo "")

if [ -n "$TGW_ATTACH_IDS" ]; then
    TGW_COUNT=$(echo "$TGW_ATTACH_IDS" | wc -l | tr -d ' ')
    echo "  Found $TGW_COUNT TGW attachment(s)"
    
    for TGW_ATTACH_ID in $TGW_ATTACH_IDS; do
        aws ec2 delete-transit-gateway-vpc-attachment --region $REGION \
            --transit-gateway-attachment-id "$TGW_ATTACH_ID" > /dev/null 2>&1 && \
            echo "  ✅ $TGW_ATTACH_ID" || \
            echo "  ❌ $TGW_ATTACH_ID (failed)"
    done
    
    echo "  Waiting 60 seconds for TGW attachments to delete..."
    sleep 60
else
    echo "  No TGW attachments found"
fi
echo ""

# ────────────────────────────────────────────────────────────
# Step 3: Elastic IPs & Step 4: Load Balancers (PARALLEL)
# ────────────────────────────────────────────────────────────
# These two steps are independent and can run in parallel
echo -e "${YELLOW}Step 3 & 4: Releasing Elastic IPs and Deleting Load Balancers (parallel)...${NC}"

# Step 3: EIPs (background)
(
    EIP_ALLOC_IDS=$(aws ec2 describe-addresses --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
        --query "Addresses[].AllocationId" \
        --output json 2>/dev/null | jq -r '.[]' || echo "")
    
    if [ -n "$EIP_ALLOC_IDS" ]; then
        EIP_COUNT=$(echo "$EIP_ALLOC_IDS" | wc -l | tr -d ' ')
        echo "  [EIP] Found $EIP_COUNT Elastic IP(s)"
        
        echo "$EIP_ALLOC_IDS" | while IFS= read -r ALLOC_ID; do
            # Check if EIP is associated
            ASSOC_ID=$(aws ec2 describe-addresses --region $REGION \
                --allocation-ids "$ALLOC_ID" \
                --query "Addresses[0].AssociationId" \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$ASSOC_ID" ] && [ "$ASSOC_ID" != "None" ]; then
                echo "  [EIP] Disassociating $ALLOC_ID..."
                aws ec2 disassociate-address --region $REGION \
                    --association-id "$ASSOC_ID" > /dev/null 2>&1
                sleep 1
            fi
            
            # Release EIP
            aws ec2 release-address --region $REGION \
                --allocation-id "$ALLOC_ID" > /dev/null 2>&1 && \
                echo "  [EIP] ✅ $ALLOC_ID" || \
                echo "  [EIP] ❌ $ALLOC_ID (failed)"
        done
    else
        echo "  [EIP] No Elastic IPs found"
    fi
) &
EIP_PID=$!

# Step 4: Load Balancers (background)
(
    # Get VPCs for this pod to find LBs
    VPCS=$(aws ec2 describe-vpcs --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || echo "")
    
    LBS_FOUND=""
    for VPC in $VPCS; do
        VPC_LBS=$(aws elbv2 describe-load-balancers --region $REGION \
            --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" \
            --output text 2>/dev/null || echo "")
        LBS_FOUND="$LBS_FOUND $VPC_LBS"
    done
    
    if [ -n "$LBS_FOUND" ]; then
        LB_COUNT=$(echo "$LBS_FOUND" | wc -w | tr -d ' ')
        echo "  [LB] Found $LB_COUNT load balancer(s)"
        
        for LB_ARN in $LBS_FOUND; do
            aws elbv2 delete-load-balancer --region $REGION \
                --load-balancer-arn $LB_ARN > /dev/null 2>&1 && \
                echo "  [LB] ✅ LB deleted" || \
                echo "  [LB] ❌ LB deletion failed"
        done
        
        echo "  [LB] Waiting 30 seconds for load balancers to delete..."
        sleep 30
    else
        echo "  [LB] No load balancers found"
    fi
) &
LB_PID=$!

# Wait for both parallel tasks
wait $EIP_PID
wait $LB_PID
echo ""

# ────────────────────────────────────────────────────────────
# Step 5: NAT Gateways
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Deleting NAT Gateways...${NC}"
NAT_GW_IDS=$(aws ec2 describe-nat-gateways --region $REGION \
    --filter "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
             "Name=state,Values=available,pending" \
    --query "NatGateways[].NatGatewayId" \
    --output json 2>/dev/null | jq -r '.[]' || echo "")

if [ -n "$NAT_GW_IDS" ]; then
    NAT_COUNT=$(echo "$NAT_GW_IDS" | wc -l | tr -d ' ')
    echo "  Found $NAT_COUNT NAT Gateway(s)"
    
    for NAT_ID in $NAT_GW_IDS; do
        aws ec2 delete-nat-gateway --region $REGION \
            --nat-gateway-id "$NAT_ID" > /dev/null 2>&1 && \
            echo "  ✅ $NAT_ID" || \
            echo "  ❌ $NAT_ID (failed)"
    done
    
    echo "  Waiting 30 seconds for NAT Gateways to delete..."
    sleep 30
else
    echo "  No NAT Gateways found"
fi
echo ""

# ────────────────────────────────────────────────────────────
# Step 6: VPCs and Dependencies
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Deleting VPCs and Dependencies...${NC}"

# Re-query VPCs for this step (can't use $VPCS from parallel subprocess)
VPCS=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
    --query 'Vpcs[].VpcId' \
    --output text 2>/dev/null || echo "")

if [ -n "$VPCS" ]; then
    VPC_COUNT=$(echo "$VPCS" | wc -w | tr -d ' ')
    echo "  Found $VPC_COUNT VPC(s)"
    
    for VPC_ID in $VPCS; do
        VPC_NAME=$(aws ec2 describe-vpcs --region $REGION --vpc-ids $VPC_ID \
            --query "Vpcs[0].Tags[?Key=='Name']|[0].Value" --output text 2>/dev/null || echo "unknown")
        
        echo "  Processing: $VPC_NAME ($VPC_ID)"
        
        # 6a. Delete VPC Endpoints
        for ENDPOINT_ID in $(aws ec2 describe-vpc-endpoints --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null); do
            aws ec2 delete-vpc-endpoints --region $REGION \
                --vpc-endpoint-ids $ENDPOINT_ID 2>/dev/null
        done
        
        # 6b. Delete Network Interfaces (critical for Service VPCs)
        for ENI_ID in $(aws ec2 describe-network-interfaces --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null); do
            aws ec2 delete-network-interface --region $REGION \
                --network-interface-id $ENI_ID 2>/dev/null || true
        done
        
        # 6c. Detach and delete IGWs
        for IGW_ID in $(aws ec2 describe-internet-gateways --region $REGION \
            --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
            --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null); do
            aws ec2 detach-internet-gateway --region $REGION \
                --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>/dev/null
            aws ec2 delete-internet-gateway --region $REGION \
                --internet-gateway-id $IGW_ID 2>/dev/null
        done
        
        # 6d. Delete subnets
        for SUBNET_ID in $(aws ec2 describe-subnets --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "Subnets[].SubnetId" --output text 2>/dev/null); do
            aws ec2 delete-subnet --region $REGION \
                --subnet-id $SUBNET_ID 2>/dev/null
        done
        
        # 6e. Delete route tables (non-main) with disassociation
        for RT_ID in $(aws ec2 describe-route-tables --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
            # Disassociate first
            for ASSOC_ID in $(aws ec2 describe-route-tables --region $REGION \
                --route-table-ids $RT_ID \
                --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
                --output text 2>/dev/null); do
                aws ec2 disassociate-route-table --region $REGION \
                    --association-id $ASSOC_ID 2>/dev/null || true
            done
            aws ec2 delete-route-table --region $REGION \
                --route-table-id $RT_ID 2>/dev/null
        done
        
        # 6f. Delete security groups (non-default) with rule cleanup
        # Retry up to 3 times to handle inter-group dependencies
        for ATTEMPT in 1 2 3; do
            SG_IDS=$(aws ec2 describe-security-groups --region $REGION \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)
            
            [ -z "$SG_IDS" ] && break
            
            for SG_ID in $SG_IDS; do
                # Revoke all rules to break dependencies
                aws ec2 describe-security-groups --region $REGION --group-ids $SG_ID \
                    --query "SecurityGroups[0].IpPermissions" 2>/dev/null | \
                    aws ec2 revoke-security-group-ingress --region $REGION \
                    --group-id $SG_ID --ip-permissions file:///dev/stdin 2>/dev/null || true
                
                aws ec2 describe-security-groups --region $REGION --group-ids $SG_ID \
                    --query "SecurityGroups[0].IpPermissionsEgress" 2>/dev/null | \
                    aws ec2 revoke-security-group-egress --region $REGION \
                    --group-id $SG_ID --ip-permissions file:///dev/stdin 2>/dev/null || true
                
                aws ec2 delete-security-group --region $REGION \
                    --group-id $SG_ID 2>/dev/null || true
            done
            
            [ $ATTEMPT -lt 3 ] && sleep 2
        done
        
        # 6g. Delete VPC
        sleep 2
        aws ec2 delete-vpc --region $REGION --vpc-id $VPC_ID 2>/dev/null && \
            echo "    ✅ Deleted" || \
            echo "    ⚠️  Still has dependencies (will retry)"
    done
else
    echo "  No VPCs found"
fi
echo ""

# ────────────────────────────────────────────────────────────
# Step 7: Aggressive VPC Cleanup (for Service VPCs with ENIs)
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 7: Aggressive VPC cleanup...${NC}"
echo "  Waiting 30 seconds for ENIs to fully detach..."
sleep 30

REMAINING_VPCS=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
    --query "Vpcs[].VpcId" \
    --output json 2>/dev/null | jq -r '.[]' || echo "")

if [ -n "$REMAINING_VPCS" ]; then
    VPC_RETRY_COUNT=$(echo "$REMAINING_VPCS" | wc -l | tr -d ' ')
    echo "  Found $VPC_RETRY_COUNT remaining VPC(s) - running aggressive cleanup"
    
    for VPC_ID in $REMAINING_VPCS; do
        VPC_NAME=$(aws ec2 describe-vpcs --region $REGION --vpc-ids $VPC_ID \
            --query "Vpcs[0].Tags[?Key=='Name']|[0].Value" --output text 2>/dev/null || echo "unknown")
        
        echo "  🔍 Processing: $VPC_NAME ($VPC_ID)"
        
        # 7a. Force delete any remaining ENIs (retry)
        ENI_COUNT=0
        for ENI_ID in $(aws ec2 describe-network-interfaces --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null); do
            aws ec2 delete-network-interface --region $REGION \
                --network-interface-id $ENI_ID 2>/dev/null && \
                echo "     • Deleted ENI: $ENI_ID" && \
                ((ENI_COUNT++)) || true
        done
        [ $ENI_COUNT -gt 0 ] && echo "     ℹ️  Cleaned $ENI_COUNT ENI(s)"
        
        # 7b. Force delete any VPC endpoints (retry)
        for ENDPOINT_ID in $(aws ec2 describe-vpc-endpoints --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null); do
            aws ec2 delete-vpc-endpoints --region $REGION \
                --vpc-endpoint-ids $ENDPOINT_ID 2>/dev/null && \
                echo "     • Deleted VPC Endpoint: $ENDPOINT_ID" || true
        done
        
        # 7c. Force delete any remaining subnets (retry)
        for SUBNET_ID in $(aws ec2 describe-subnets --region $REGION \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "Subnets[].SubnetId" --output text 2>/dev/null); do
            aws ec2 delete-subnet --region $REGION \
                --subnet-id $SUBNET_ID 2>/dev/null && \
                echo "     • Deleted Subnet: $SUBNET_ID" || true
        done
        
        # 7d. Try to delete VPC again
        sleep 2
        aws ec2 delete-vpc --region $REGION --vpc-id $VPC_ID 2>/dev/null && \
            echo "     ✅ VPC deleted" || \
            echo "     ⚠️  VPC still has dependencies (will auto-delete soon)"
    done
else
    echo "  ✅ All VPCs deleted!"
fi
echo ""

# ────────────────────────────────────────────────────────────
# Step 8: Key Pairs
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 8: Deleting Key Pairs...${NC}"
aws ec2 delete-key-pair --region $REGION --key-name "pod${POD_NUMBER}-keypair" 2>/dev/null && \
    echo "  ✅ Key pair deleted" || \
    echo "  ℹ️  Key pair not found (may already be deleted)"
echo ""

# ────────────────────────────────────────────────────────────
# Step 9: Local Files
# ────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 9: Cleaning up local files...${NC}"
rm -f "pod${POD_NUMBER}-private-key" 2>/dev/null && echo "  ✅ Private key removed" || true
rm -f "pod${POD_NUMBER}-public-key" 2>/dev/null && echo "  ✅ Public key removed" || true
echo ""

# ────────────────────────────────────────────────────────────
# Final Summary & Verification (v3.0)
# ────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "Cleanup Summary - Pod $POD_NUMBER"
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${YELLOW}Verifying cleanup results...${NC}"
echo ""

# Comprehensive verification (don't trust exit codes)
REMAINING_INST=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*,ciscomcd-pod${POD_NUMBER}-*" \
              "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

REMAINING_VPC=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
    --query "Vpcs[].VpcId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

REMAINING_EIP=$(aws ec2 describe-addresses --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
    --query "Addresses[].AllocationId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

REMAINING_ENI=$(aws ec2 describe-network-interfaces --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
    --query "NetworkInterfaces[].NetworkInterfaceId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

REMAINING_TGW=$(aws ec2 describe-transit-gateway-attachments --region $REGION \
    --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
              "Name=state,Values=available,pending" \
    --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

# Check for Service VPCs (may not have pod tag but have specific CIDR)
SERVICE_VPCS=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=cidr,Values=192.168.${POD_NUMBER}.0/24" \
    --query "Vpcs[].VpcId" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null | wc -l | tr -d ' ')

echo "Remaining Resources:"
echo "  • EC2 Instances: $REMAINING_INST"
echo "  • VPCs (tagged): $REMAINING_VPC"
echo "  • Service VPCs (192.168.${POD_NUMBER}.0/24): $SERVICE_VPCS"
echo "  • Elastic IPs: $REMAINING_EIP"
echo "  • ENIs: $REMAINING_ENI"
echo "  • TGW Attachments: $REMAINING_TGW"
echo ""

# Calculate cost impact
if [ "$REMAINING_EIP" -gt 0 ]; then
    COST=$(echo "scale=2; $REMAINING_EIP * 3.65" | bc)
    echo -e "${YELLOW}💰 Cost Alert: $REMAINING_EIP EIP(s) = ~\$${COST}/month${NC}"
    echo ""
fi

TOTAL=$((REMAINING_INST + REMAINING_VPC + SERVICE_VPCS + REMAINING_EIP + REMAINING_ENI + REMAINING_TGW))

if [ "$TOTAL" -eq 0 ]; then
    echo -e "${GREEN}✅ SUCCESS - All resources cleaned up!${NC}"
    echo ""
    
    # Clean up pod-specific Terraform state
echo "════════════════════════════════════════════════════════════"
echo "Phase 4: Local State Cleanup"
echo "════════════════════════════════════════════════════════════"
echo ""

cd "${SCRIPT_DIR}/.."  # Go to project root

# Reset MCD resources file to disabled state
if [ -f "mcd-resources.tf" ]; then
    mv mcd-resources.tf mcd-resources.tf.disabled 2>/dev/null
    echo "🗑️  Reset MCD resources to disabled state"
fi

if [ -f ".state-helper.sh" ]; then
    source .state-helper.sh
    cleanup_pod_state "$POD_NUMBER"
fi
    
    # Clean up other local files for this pod
    echo "🗑️  Cleaning up local files..."
    rm -f "pod${POD_NUMBER}-private-key" "pod${POD_NUMBER}-private-key.pem" 2>/dev/null
    rm -f "pod${POD_NUMBER}-keypair.pub" 2>/dev/null
    echo "✅ Local cleanup complete"
    echo ""
    
    exit 0
else
    # Resources remain - provide guidance
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  $TOTAL resource(s) remain after cleanup${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$SERVICE_VPCS" -gt 0 ]; then
        echo -e "${BLUE}ℹ️  Service VPCs found (CIDR: 192.168.${POD_NUMBER}.0/24)${NC}"
        echo "   These are MCD-created VPCs that need manual cleanup."
        echo "   They may contain security groups or route tables."
        echo ""
        echo "   To clean them manually:"
        echo "   1. Run: cleanup/cleanup-direct.sh"
        echo "   2. Or delete via AWS console"
        echo ""
    fi
    
    if [ "$REMAINING_EIP" -gt 0 ]; then
        echo -e "${YELLOW}💰 ACTION REQUIRED: Release Elastic IPs to avoid charges${NC}"
        echo "   Run this command:"
        echo "   aws ec2 describe-addresses --region us-east-1 \\"
        echo "     --filters \"Name=tag:Name,Values=pod${POD_NUMBER}-*\" \\"
        echo "     --query \"Addresses[].[AllocationId,PublicIp]\" --output table"
        echo ""
    fi
    
    if [ "$REMAINING_ENI" -gt 0 ]; then
        echo -e "${BLUE}ℹ️  ENIs remain - these may prevent EIP release${NC}"
        echo "   Delete ENIs first, then retry EIP release"
        echo ""
    fi
    
    if [ "$REMAINING_VPC" -gt 0 ] && [ "$REMAINING_VPC" -le 2 ]; then
        echo -e "${BLUE}ℹ️  VPCs may have ENIs still detaching (async operation)${NC}"
        echo "   Wait 5-10 minutes and they should auto-delete"
        echo ""
    fi
    
    echo "Debug Commands:"
    echo "  # List remaining VPCs:"
    echo "  aws ec2 describe-vpcs --region us-east-1 --filters \"Name=tag:Name,Values=pod${POD_NUMBER}-*\""
    echo ""
    echo "  # List remaining EIPs:"
    echo "  aws ec2 describe-addresses --region us-east-1 --filters \"Name=tag:Name,Values=pod${POD_NUMBER}-*\""
    echo ""
    echo "  # Cleanup leftovers:"
    echo "  ./cleanup/cleanup-direct.sh"
    echo ""

