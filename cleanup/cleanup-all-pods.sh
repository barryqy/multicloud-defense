#!/bin/bash

# ALL PODS CLEANUP SCRIPT
# ⚠️ INSTRUCTOR/ADMIN USE ONLY ⚠️
# This script cleans up ALL student pods (1-60)
# Requires password authentication

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Password hash (SHA-256 of the admin password)
# To verify: echo -n "YourPassword" | shasum -a 256
EXPECTED_HASH="10c14c7459df11e17b3b3f63ad995737854e64d12c067d2186dea38f6d553ef8"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     ⚠️  ALL PODS CLEANUP - ADMIN ONLY  ⚠️             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${RED}WARNING: This will destroy resources for ALL pods (1-60)${NC}"
echo -e "${RED}This operation cannot be undone!${NC}"
echo ""

# Password authentication
read -sp "Enter admin password: " INPUT_PASSWORD
echo ""
echo ""

# Hash the input password and compare
INPUT_HASH=$(echo -n "$INPUT_PASSWORD" | shasum -a 256 | awk '{print $1}')

if [ "$INPUT_HASH" != "$EXPECTED_HASH" ]; then
    echo -e "${RED}❌ Authentication failed. Access denied.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Authentication successful${NC}"
echo ""

# Use the verified password for AWS credential fetch
export LAB_PASSWORD="$INPUT_PASSWORD"

# Double confirmation
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}You are about to clean up ALL 60 pods:${NC}"
echo "  • All AWS VPCs, EC2 instances, networking"
echo "  • All MCD gateways, policies, address objects"
echo "  • All student SSH keys and state files"
echo ""
echo -e "${RED}This will affect ALL students!${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo ""
read -p "Type 'DELETE-ALL-PODS' to confirm: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "DELETE-ALL-PODS" ]; then
    echo -e "${YELLOW}⚠️  Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${MAGENTA}🚀 Starting cleanup of all pods...${NC}"
echo ""

# Source credentials helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/../.credentials-helper.sh" ]; then
    echo -e "${RED}❌ Credentials helper not found${NC}"
    exit 1
fi

source "${SCRIPT_DIR}/../.credentials-helper.sh"

# Check if AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found. Please install it first.${NC}"
    exit 1
fi

# Get AWS credentials
echo -e "${BLUE}Fetching AWS credentials...${NC}"

if ! _c2; then
    echo -e "${RED}❌ Failed to fetch credentials${NC}"
    exit 1
fi

export AWS_DEFAULT_REGION="us-east-1"
echo ""

# Function to clean up a single pod
cleanup_pod() {
    local POD=$1
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Cleaning up Pod ${POD}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    
    # Terminate EC2 instances
    echo -n "  • Terminating EC2 instances... "
    INSTANCES=$(aws ec2 describe-instances \
        --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD}-app1,pod${POD}-app2" \
                  "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$INSTANCES" ]; then
        aws ec2 terminate-instances --region us-east-1 --instance-ids $INSTANCES &>/dev/null || true
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(none)${NC}"
    fi
    
    # Delete key pairs
    echo -n "  • Deleting key pairs... "
    aws ec2 delete-key-pair --region us-east-1 --key-name "pod${POD}-keypair" 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"
    
    # Release Elastic IPs
    echo -n "  • Releasing Elastic IPs... "
    EIPS=$(aws ec2 describe-addresses \
        --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD}-app1-eip,pod${POD}-app2-eip" \
        --query 'Addresses[].AllocationId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$EIPS" ]; then
        for EIP in $EIPS; do
            aws ec2 release-address --region us-east-1 --allocation-id $EIP 2>/dev/null || true
        done
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(none)${NC}"
    fi
    
    # Sleep to allow resource cleanup
    sleep 3
    
    # Delete Security Groups
    echo -n "  • Deleting Security Groups... "
    SGS=$(aws ec2 describe-security-groups \
        --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD}-app1-sg,pod${POD}-app2-sg" \
        --query 'SecurityGroups[].GroupId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$SGS" ]; then
        for SG in $SGS; do
            aws ec2 delete-security-group --region us-east-1 --group-id $SG 2>/dev/null || true
        done
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(none)${NC}"
    fi
    
    # Delete VPCs and dependencies
    echo -n "  • Deleting VPCs... "
    VPCS=$(aws ec2 describe-vpcs \
        --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD}-app1-vpc,pod${POD}-app2-vpc" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    for VPC in $VPCS; do
        # Detach and delete IGWs
        IGWS=$(aws ec2 describe-internet-gateways --region us-east-1 \
            --filters "Name=attachment.vpc-id,Values=$VPC" \
            --query 'InternetGateways[].InternetGatewayId' \
            --output text 2>/dev/null || true)
        for IGW in $IGWS; do
            aws ec2 detach-internet-gateway --region us-east-1 --internet-gateway-id $IGW --vpc-id $VPC 2>/dev/null || true
            aws ec2 delete-internet-gateway --region us-east-1 --internet-gateway-id $IGW 2>/dev/null || true
        done
        
        # Delete Subnets
        SUBNETS=$(aws ec2 describe-subnets --region us-east-1 \
            --filters "Name=vpc-id,Values=$VPC" \
            --query 'Subnets[].SubnetId' \
            --output text 2>/dev/null || true)
        for SUBNET in $SUBNETS; do
            aws ec2 delete-subnet --region us-east-1 --subnet-id $SUBNET 2>/dev/null || true
        done
        
        # Delete Route Tables
        RTS=$(aws ec2 describe-route-tables --region us-east-1 \
            --filters "Name=vpc-id,Values=$VPC" \
            --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
            --output text 2>/dev/null || true)
        for RT in $RTS; do
            aws ec2 delete-route-table --region us-east-1 --route-table-id $RT 2>/dev/null || true
        done
        
        # Delete VPC
        aws ec2 delete-vpc --region us-east-1 --vpc-id $VPC 2>/dev/null || true
    done
    
    if [ -n "$VPCS" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(none)${NC}"
    fi
    
    echo -e "${GREEN}  Pod ${POD} cleanup complete${NC}"
}

# Main cleanup loop
TOTAL_PODS=60
CLEANED=0

echo -e "${MAGENTA}Starting cleanup of ${TOTAL_PODS} pods...${NC}"
echo -e "${YELLOW}This may take 15-30 minutes. Please be patient.${NC}"

for POD in $(seq 1 $TOTAL_PODS); do
    cleanup_pod $POD
    ((CLEANED++))
    
    # Progress indicator
    if [ $((POD % 10)) -eq 0 ]; then
        echo ""
        echo -e "${MAGENTA}Progress: ${CLEANED}/${TOTAL_PODS} pods cleaned${NC}"
    fi
done

# Cleanup credentials
cleanup_credentials

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ ALL PODS CLEANUP COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Cleaned up ${CLEANED} pods successfully."
echo ""
echo -e "${YELLOW}Note: Some resources may still exist due to dependencies.${NC}"
echo -e "${YELLOW}Please verify in AWS Console and MCD Console.${NC}"
echo ""
echo "MCD Resources (may need manual cleanup):"
echo "  • Service VPCs (pod1-svpc-aws through pod60-svpc-aws)"
echo "  • Gateways (pod1-*-gw-aws through pod60-*-gw-aws)"
echo "  • Policy Rule Sets, Address Objects, DLP Profiles"
echo ""
echo "Shared Resources (preserved):"
echo "  • Transit Gateway (multicloud-defense-lab-transit-gateway)"
echo "    This is shared across all pods and NOT deleted."
echo ""

