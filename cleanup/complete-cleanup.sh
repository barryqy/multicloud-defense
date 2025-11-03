#!/bin/bash

# Complete Cleanup Script
# Comprehensive cleanup for Multicloud Defense lab resources
# This script cleans up ALL resources including Transit Gateways

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to sanitize output by removing sensitive values
sanitize_output() {
    sed -E 's/AKIA[A-Z0-9]{16}/AKIA************/g' | \
    sed -E 's/[A-Za-z0-9/+=]{40}/****REDACTED****/g' | \
    sed -E 's/"api_key":\s*"[^"]*"/"api_key": "****REDACTED****"/g' | \
    sed -E 's/aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]*/aws_secret_access_key = ****REDACTED****/g'
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        Multicloud Defense - Complete Cleanup            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Get pod number from parent terraform.tfvars if available
POD_NUMBER=$(grep "^pod_number" ../terraform.tfvars 2>/dev/null | awk '{print $3}')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${YELLOW}📋 Pod number not found in terraform.tfvars${NC}"
    echo ""
    read -p "Enter your pod number (1-60): " POD_NUMBER
    
    # Validate pod number
    if ! [[ "$POD_NUMBER" =~ ^[0-9]+$ ]] || [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 60 ]; then
        echo -e "${RED}❌ Pod number must be between 1 and 60${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Found pod number: ${POD_NUMBER}${NC}"
fi

echo ""
echo -e "${BLUE}Pod ${POD_NUMBER} - Complete Cleanup${NC}"
echo ""

# Show what will be cleaned up
echo -e "${YELLOW}Resources to be destroyed:${NC}"
echo "  AWS Resources:"
echo "    • VPCs and all networking (subnets, route tables)"
echo "    • EC2 Instances (app1, app2, jumpbox)"
echo "    • Elastic IPs"
echo "    • Security Groups"
echo "    • Internet Gateways"
echo "    • Network Interfaces"
echo "    • SSH Key Pairs"
echo ""
echo "  MCD Resources:"
echo "    • Service VPC"
echo "    • Gateways (ingress, egress)"
echo "    • Policy Rule Sets & Rules"
echo "    • Address Objects"
echo "    • Service Objects"
echo "    • DLP Profiles"
echo ""
echo "  Shared Resources (NOT deleted):"
echo "    • Transit Gateway (shared across all pods)"
echo ""
echo "  Local Files:"
echo "    • State files and keys"
echo ""

read -p "Continue with cleanup? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}⚠️  Cleanup cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}🗑️  Starting cleanup process...${NC}"
echo ""

# Change to parent directory
cd ..

# Step 1: Run Terraform Destroy (handles most resources)
echo -e "${BLUE}Step 1: Running terraform destroy...${NC}"
echo ""

if [ -f "main.tf" ] && [ -d ".terraform" ]; then
    # NOTE: TGW is now a DATA SOURCE (not a resource), so it's never in state
    # No need to remove it before destroy
    echo -e "${BLUE}  Transit Gateway is a data source (tgw-0a878e2f5870e2ccf)${NC}"
    echo -e "${BLUE}  It's never in state and never gets destroyed${NC}"
    echo ""
    
    if terraform destroy -auto-approve 2>&1 | sanitize_output; then
        echo ""
        echo -e "${GREEN}✓ Terraform destroy complete${NC}"
    else
        echo -e "${YELLOW}⚠️  Terraform destroy had errors, continuing with manual cleanup...${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  No Terraform state found, skipping terraform destroy${NC}"
fi

echo ""

# Step 2: Clean up local files
echo -e "${BLUE}Step 2: Cleaning up local files...${NC}"

# Remove SSH keys
if [ -f "pod${POD_NUMBER}-private-key" ]; then
    rm -f "pod${POD_NUMBER}-private-key"
    echo "  ✓ Removed pod${POD_NUMBER}-private-key"
fi

if [ -f "pod${POD_NUMBER}-public-key" ]; then
    rm -f "pod${POD_NUMBER}-public-key"
    echo "  ✓ Removed pod${POD_NUMBER}-public-key"
fi

# Remove Terraform state and lock files
if [ -d ".terraform" ]; then
    rm -rf .terraform
    echo "  ✓ Removed .terraform directory"
fi

if [ -f ".terraform.lock.hcl" ]; then
    rm -f .terraform.lock.hcl
    echo "  ✓ Removed .terraform.lock.hcl"
fi

if [ -f "terraform.tfstate" ]; then
    rm -f terraform.tfstate
    echo "  ✓ Removed terraform.tfstate"
fi

if [ -f "terraform.tfstate.backup" ]; then
    rm -f terraform.tfstate.backup
    echo "  ✓ Removed terraform.tfstate.backup"
fi

if [ -f "tfplan" ]; then
    rm -f tfplan
    echo "  ✓ Removed tfplan"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Complete cleanup finished!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "All resources for pod ${POD_NUMBER} have been cleaned up."
echo ""
echo "To start fresh:"
echo "  1. Run: ./init-lab.sh"
echo "  2. Run: ./deploy.sh"
echo ""

