#!/bin/bash

# Cisco Multicloud Defense - Security Configuration Script
# This script deploys security policies and protections:
# - Egress Protection: DLP to prevent SSN data exfiltration
# - East-West Security: Allow pod app1 to app2 communication
# - Ingress Protection: IPS/WAF for web server protection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to sanitize output by removing sensitive values
sanitize_output() {
    sed -E 's/AKIA[A-Z0-9]{16}/AKIA************/g' | \
    sed -E 's/[A-Za-z0-9/+=]{40}/****REDACTED****/g' | \
    sed -E 's/"api_key":\s*"[^"]*"/"api_key": "****REDACTED****"/g' | \
    sed -E 's/aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]*/aws_secret_access_key = ****REDACTED****/g' | \
    grep -v "Warning: Argument is deprecated" | \
    grep -v "network_interface is deprecated"
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Cisco Multicloud Defense - Security Configuration     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Terraform is not installed${NC}"
    echo "Please install Terraform first: https://www.terraform.io/downloads"
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "main.tf" ]; then
    echo -e "${RED}❌ main.tf not found${NC}"
    echo "Please run this script from the project root directory"
    exit 1
fi

# Get pod number
POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ Pod number not found in terraform.tfvars${NC}"
    echo "Please run ./init-lab.sh first"
    exit 1
fi

echo -e "${GREEN}✓ Pod Number: ${POD_NUMBER}${NC}"
echo ""

# ════════════════════════════════════════════════════════════
# Activate MCD Resources File
# ════════════════════════════════════════════════════════════
# Step 2 (2-deploy.sh) deploys AWS resources only.
# Step 3 (this script) activates MCD resources for deployment.
# ════════════════════════════════════════════════════════════

echo -e "${YELLOW}🔧 Activating MCD resources...${NC}"

if [ -f "mcd-resources.tf.disabled" ]; then
    # Activate the MCD resources file
    mv mcd-resources.tf.disabled mcd-resources.tf
    echo -e "${GREEN}✓ MCD resources activated${NC}"
elif [ -f "mcd-resources.tf" ]; then
    echo -e "${GREEN}✓ MCD resources already active${NC}"
else
    echo -e "${RED}❌ mcd-resources.tf.disabled not found${NC}"
    echo "This is required for deploying security resources."
    exit 1
fi

echo ""

# Import existing MCD resources (for container environments where state is lost)
echo -e "${YELLOW}🔍 Checking for existing MCD resources...${NC}"
echo ""

# Function to silently import resources
silent_import() {
    local resource_type=$1
    local resource_name=$2
    local resource_id=$3
    
    # Check if already in state
    if terraform state list 2>/dev/null | grep -q "^${resource_type}.${resource_name}$"; then
        return 0
    fi
    
    # Try to import silently
    terraform import "${resource_type}.${resource_name}" "${resource_id}" > /dev/null 2>&1
    return $?
}

IMPORTED_COUNT=0

# Try to import MCD resources that might already exist
echo -n "  • Service VPC... "
if silent_import "ciscomcd_service_vpc" "svpc-aws" "pod${POD_NUMBER}-svpc-aws"; then
    echo -e "${GREEN}✓ imported${NC}"
    ((IMPORTED_COUNT++))
else
    echo -e "${BLUE}new${NC}"
fi

echo -n "  • DLP Profile... "
if silent_import "ciscomcd_profile_dlp" "block-ssn-dlp" "pod${POD_NUMBER}-block-ssn"; then
    echo -e "${GREEN}✓ imported${NC}"
    ((IMPORTED_COUNT++))
else
    echo -e "${BLUE}new${NC}"
fi

echo -n "  • Address Objects... "
ADDR_IMPORTED=0
silent_import "ciscomcd_address_object" "app1-egress-addr-object" "pod${POD_NUMBER}-app1-egress" && ((ADDR_IMPORTED++)) || true
silent_import "ciscomcd_address_object" "app2-egress-addr-object" "pod${POD_NUMBER}-app2-egress" && ((ADDR_IMPORTED++)) || true
silent_import "ciscomcd_address_object" "app1-ingress-addr-object" "pod${POD_NUMBER}-app1-ingress" && ((ADDR_IMPORTED++)) || true
silent_import "ciscomcd_address_object" "app2-ingress-addr-object" "pod${POD_NUMBER}-app2-ingress" && ((ADDR_IMPORTED++)) || true
if [ $ADDR_IMPORTED -gt 0 ]; then
    echo -e "${GREEN}✓ $ADDR_IMPORTED imported${NC}"
    IMPORTED_COUNT=$((IMPORTED_COUNT + ADDR_IMPORTED))
else
    echo -e "${BLUE}new${NC}"
fi

echo -n "  • Service Objects... "
SVC_IMPORTED=0
silent_import "ciscomcd_service_object" "app1_svc_http" "pod${POD_NUMBER}-app1" && ((SVC_IMPORTED++)) || true
silent_import "ciscomcd_service_object" "app2_svc_http" "pod${POD_NUMBER}-app2" && ((SVC_IMPORTED++)) || true
if [ $SVC_IMPORTED -gt 0 ]; then
    echo -e "${GREEN}✓ $SVC_IMPORTED imported${NC}"
    IMPORTED_COUNT=$((IMPORTED_COUNT + SVC_IMPORTED))
else
    echo -e "${BLUE}new${NC}"
fi

echo -n "  • Policy Rule Sets... "
POLICY_IMPORTED=0
silent_import "ciscomcd_policy_rule_set" "egress_policy" "pod${POD_NUMBER}-egress-policy" && ((POLICY_IMPORTED++)) || true
silent_import "ciscomcd_policy_rule_set" "ingress_policy" "pod${POD_NUMBER}-ingress-policy" && ((POLICY_IMPORTED++)) || true
if [ $POLICY_IMPORTED -gt 0 ]; then
    echo -e "${GREEN}✓ $POLICY_IMPORTED imported${NC}"
    IMPORTED_COUNT=$((IMPORTED_COUNT + POLICY_IMPORTED))
else
    echo -e "${BLUE}new${NC}"
fi

echo ""
if [ $IMPORTED_COUNT -gt 0 ]; then
    echo -e "${GREEN}✓ Imported $IMPORTED_COUNT existing MCD resource(s)${NC}"
    echo -e "${BLUE}ℹ️  This is normal in container environments where Terraform state is lost${NC}"
else
    echo -e "${BLUE}✓ No existing resources found - will create new ones${NC}"
fi
echo ""

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}🔒 Security Features to Deploy${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "1. 📤 Egress Security (DLP)"
echo "   • Data Loss Prevention Profile"
echo "   • Block SSN exfiltration from app servers"
echo "   • Egress Gateway with DLP inspection"
echo ""
echo "2. 🔄 East-West Security"
echo "   • Allow pod${POD_NUMBER}-app1 → pod${POD_NUMBER}-app2 traffic"
echo "   • Micro-segmentation policy rules"
echo "   • Traffic logging and monitoring"
echo ""
echo "3. 📥 Ingress Security (IPS/WAF)"
echo "   • Intrusion Prevention System (IPS)"
echo "   • Web Application Firewall protection"
echo "   • Ingress Gateway with threat protection"
echo ""
echo "4. 🏗️ Infrastructure Components"
echo "   • Gateway Load Balancer (GWLB)"
echo "   • Address & Service Objects"
echo "   • Note: Service VPC already deployed in deploy.sh"
echo ""

# Check if infrastructure is deployed
if [ ! -f "terraform.tfstate" ] || [ ! -s "terraform.tfstate" ]; then
    echo -e "${YELLOW}⚠️  Warning: No infrastructure state found${NC}"
    echo ""
    echo "You need to deploy the base infrastructure first using:"
    echo "  ./deploy.sh"
    echo ""
    read -p "Continue anyway? (yes/no): " CONTINUE
    if [ "$CONTINUE" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}⚠️  Important: Security Deployment${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "This will deploy security policies that include:"
echo "  • Data Loss Prevention (DLP) for SSN protection"
echo "  • Network segmentation rules"
echo "  • IPS/WAF threat protection"
echo ""
echo "Estimated deployment time: 10-15 minutes"
echo ""

echo ""
echo -e "${YELLOW}🔧 Initializing Terraform...${NC}"
echo ""

# Initialize terraform
if terraform init -upgrade 2>&1 | sanitize_output; then
    echo ""
    echo -e "${GREEN}✓ Terraform initialized${NC}"
else
    echo ""
    echo -e "${RED}❌ Terraform initialization failed${NC}"
    exit 1
fi

# Target only the security-related resources
# Note: Service VPC is deployed in deploy.sh, not here
SECURITY_TARGETS=(
    "ciscomcd_address_object.app1-egress-addr-object"
    "ciscomcd_address_object.app2-egress-addr-object"
    "ciscomcd_address_object.app1-ingress-addr-object"
    "ciscomcd_service_object.app1_svc_http"
    "ciscomcd_profile_dlp.block-ssn-dlp"
    "ciscomcd_policy_rule_set.egress_policy"
    "ciscomcd_policy_rules.egress-ew-policy-rules"
    "ciscomcd_policy_rule_set.ingress_policy"
    "ciscomcd_policy_rules.ingress-policy-rules"
    "ciscomcd_gateway.aws-egress-gw"
    "ciscomcd_gateway.aws-ingress-gw"
    "data.aws_security_group.datapath-sg"
    "aws_security_group_rule.datapath-rule"
)

echo ""
echo -e "${YELLOW}📋 Planning security deployment...${NC}"
echo ""

# Build target arguments
TARGET_ARGS=""
for target in "${SECURITY_TARGETS[@]}"; do
    TARGET_ARGS="${TARGET_ARGS} -target=${target}"
done

# Create plan
if terraform plan -out=security-tfplan $TARGET_ARGS 2>&1 | sanitize_output; then
    echo ""
    echo -e "${GREEN}✓ Security plan created${NC}"
else
    echo ""
    echo -e "${RED}❌ Security planning failed${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}🚀 Deploying security configuration...${NC}"
echo ""
echo -e "${BLUE}Deployment Timeline (watch for these milestones):${NC}"
echo "  → [~2 min] Creating Service VPC and networking"
echo "  → [~5 min] Deploying address and service objects"
echo "  → [~8 min] Creating DLP profiles"
echo "  → [~12 min] Deploying policy rule sets"
echo "  → [~15 min] Launching security gateways"
echo ""
echo -e "${YELLOW}💡 Tip: Watch for 'Creation complete' messages below${NC}"
echo ""

# Apply the plan with real-time output
terraform apply -auto-approve security-tfplan 2>&1 | tee /tmp/mcd-secure-apply.log | while IFS= read -r line; do
    # Show creation/modification lines, hide sensitive info
    if echo "$line" | grep -qE "(Creating|Modifying|Creation complete|Still creating)"; then
        echo "$line"
    elif echo "$line" | grep -qE "^Apply complete"; then
        echo "$line"
    elif echo "$line" | grep -qiE "error"; then
        echo "$line"
    fi
done

APPLY_STATUS=${PIPESTATUS[0]}
APPLY_OUTPUT=$(cat /tmp/mcd-secure-apply.log 2>/dev/null || echo "")
rm -f /tmp/mcd-secure-apply.log

echo ""
echo -e "${BLUE}🔍 Verifying security deployment...${NC}"

# Check for "already exists" errors
ONLY_EXISTS_ERRORS=false
if [ $APPLY_STATUS -ne 0 ]; then
    if echo "$APPLY_OUTPUT" | grep -qiE "(already exists|duplicate entry)"; then
        OTHER_ERRORS=$(echo "$APPLY_OUTPUT" | grep "Error:" | grep -viE "(already exists|duplicate entry|address group exists|dlp profile already exists|Service VPC.*already exists|policy_rule_sets)")
        if [ -z "$OTHER_ERRORS" ]; then
            ONLY_EXISTS_ERRORS=true
        fi
    fi
fi

# Display filtered output
if [ "$ONLY_EXISTS_ERRORS" = true ]; then
    echo "$APPLY_OUTPUT" | grep -v "╷" | grep -v "│" | grep -v "╵" | grep -viE "(address group exists|dlp profile already exists|Service VPC.*already exists|Duplicate entry.*policy_rule_sets)" || echo "$APPLY_OUTPUT"
else
    echo "$APPLY_OUTPUT"
fi

if [ $APPLY_STATUS -eq 0 ] || [ "$ONLY_EXISTS_ERRORS" = true ]; then
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Security Configuration Deployed Successfully!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$ONLY_EXISTS_ERRORS" = true ]; then
        echo -e "${BLUE}ℹ️  Note: Some security resources were already configured.${NC}"
        echo -e "${BLUE}   This is normal in container environments.${NC}"
        echo ""
    fi
    
    echo -e "${BLUE}🔒 Security Policies Deployed:${NC}"
    echo ""
    echo "✓ Egress Security:"
    echo "  • DLP Profile: pod${POD_NUMBER}-block-ssn"
    echo "  • Blocks: US Social Security Numbers"
    echo "  • Gateway: pod${POD_NUMBER}-egress-gw-aws"
    echo ""
    echo "✓ East-West Security:"
    echo "  • Policy: pod${POD_NUMBER}-egress-policy"
    echo "  • Rule 1: App1 → Internet (with DLP)"
    echo "  • Rule 2: App1 → App2 (allowed)"
    echo ""
    echo "✓ Ingress Security:"
    echo "  • Policy: pod${POD_NUMBER}-ingress-policy"
    echo "  • IPS Profile: Balanced Alert"
    echo "  • Gateway: pod${POD_NUMBER}-ingress-gw-aws"
    echo ""
    echo "✓ Infrastructure:"
    echo "  • Security Gateways: Egress + Ingress deployed"
    echo "  • Gateway Load Balancer (GWLB): MCD-managed"
    echo "  • Service VPC: Already deployed (192.168.${POD_NUMBER}.0/24)"
    echo ""
    
    # Cleanup
    rm -f security-tfplan
    
    echo -e "${BLUE}📖 Next step: Run ./4-deploy-multicloud-gateway.sh${NC}"
    echo ""
    exit 0
else
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}❌ Security Deployment Failed${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Please review the errors above."
    echo ""
    echo "Common issues:"
    echo "  • Base infrastructure not deployed (run ./deploy.sh first)"
    echo "  • API credentials expired (check terraform.tfvars)"
    echo "  • Service VPC already exists (run in fresh container)"
    echo ""
    
    # Cleanup
    rm -f security-tfplan
    exit 1
fi

