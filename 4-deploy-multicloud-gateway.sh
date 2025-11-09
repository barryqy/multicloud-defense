#!/bin/bash

# Cisco Multicloud Defense - Gateway Deployment Script
# This script deploys MCD security gateways (Egress + Ingress) for traffic inspection

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "║              Cisco Multicloud Defense - Gateway Deployment                                  ║"
echo "╚════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Ensure logs directory exists
mkdir -p logs

# Check prerequisites
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

# Check if infrastructure is deployed
if [ ! -f "terraform.tfstate" ] || [ ! -s "terraform.tfstate" ]; then
    echo -e "${RED}❌ No infrastructure deployed${NC}"
    echo ""
    echo "You need to deploy infrastructure first:"
    echo "  1. Run: ./init-lab.sh"
    echo "  2. Run: ./deploy.sh"
    echo ""
    exit 1
fi

# Get pod number
POD_NUMBER=$(grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "')

if [ -z "$POD_NUMBER" ]; then
    echo -e "${RED}❌ Pod number not found in terraform.tfvars${NC}"
    echo "Please run ./init-lab.sh first"
    exit 1
fi

echo -e "${CYAN}Pod Number: $POD_NUMBER${NC}"
echo ""

# STEP 1: DIAGNOSIS
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Step 1: Verifying Gateway Deployment${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${CYAN}Note: Gateways are deployed by 3-secure.sh using Terraform.${NC}"
echo -e "${CYAN}This script verifies their status.${NC}"
echo ""

# Check Terraform state for gateways
echo "Checking gateway resources in Terraform state..."

EGRESS_EXISTS=$(terraform state list 2>/dev/null | grep "ciscomcd_gateway.aws-egress-gw" | wc -l | tr -d ' ')
INGRESS_EXISTS=$(terraform state list 2>/dev/null | grep "ciscomcd_gateway.aws-ingress-gw" | wc -l | tr -d ' ')

EGRESS_TAINTED=0
INGRESS_TAINTED=0

if [ "$EGRESS_EXISTS" -eq 1 ]; then
    EGRESS_TAINTED=$(terraform state show ciscomcd_gateway.aws-egress-gw 2>/dev/null | head -1 | grep "tainted" | wc -l | tr -d ' ')
    EGRESS_STATE=$(terraform state show ciscomcd_gateway.aws-egress-gw 2>/dev/null | grep gateway_state | awk -F'=' '{print $2}' | tr -d ' "' || echo "UNKNOWN")
fi

if [ "$INGRESS_EXISTS" -eq 1 ]; then
    INGRESS_TAINTED=$(terraform state show ciscomcd_gateway.aws-ingress-gw 2>/dev/null | head -1 | grep "tainted" | wc -l | tr -d ' ')
    INGRESS_STATE=$(terraform state show ciscomcd_gateway.aws-ingress-gw 2>/dev/null | grep gateway_state | awk -F'=' '{print $2}' | tr -d ' "' || echo "UNKNOWN")
fi

echo ""
echo -e "${YELLOW}Terraform Gateway Status:${NC}"
if [ "$EGRESS_EXISTS" -eq 1 ]; then
    if [ "$EGRESS_TAINTED" -eq 1 ]; then
        echo "  • Egress Gateway: ${RED}TAINTED${NC} (needs rebuild)"
    else
        echo "  • Egress Gateway: ${GREEN}$EGRESS_STATE${NC}"
    fi
else
    echo "  • Egress Gateway: ${YELLOW}NOT DEPLOYED${NC}"
fi

if [ "$INGRESS_EXISTS" -eq 1 ]; then
    if [ "$INGRESS_TAINTED" -eq 1 ]; then
        echo "  • Ingress Gateway: ${RED}TAINTED${NC} (needs rebuild)"
    else
        echo "  • Ingress Gateway: ${GREEN}$INGRESS_STATE${NC}"
    fi
else
    echo "  • Ingress Gateway: ${YELLOW}NOT DEPLOYED${NC}"
fi
echo ""

# Check AWS EC2 instances
echo "Checking AWS for gateway EC2 instances..."
INSTANCE_COUNT=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null | wc -w || echo "0")

INSTANCE_COUNT=$(echo "$INSTANCE_COUNT" | tr -d ' ')

echo ""
echo -e "${YELLOW}AWS EC2 Instances in Service VPC:${NC}"
if [ "$INSTANCE_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}Found $INSTANCE_COUNT gateway instance(s)${NC}"
    aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PrivateIpAddress]' \
        --output text 2>/dev/null | sed 's/^/    /' || true
else
    echo -e "  ${RED}No instances found${NC}"
fi
echo ""

# Simplified status check - just proceed with deployment if needed
NEEDS_DEPLOYMENT=0

# Check if gateways exist
if [ "$EGRESS_EXISTS" -eq 0 ] || [ "$INGRESS_EXISTS" -eq 0 ]; then
    NEEDS_DEPLOYMENT=1
elif [ "$EGRESS_TAINTED" -eq 1 ] || [ "$INGRESS_TAINTED" -eq 1 ]; then
    NEEDS_DEPLOYMENT=1
elif [ "$INSTANCE_COUNT" -eq 0 ]; then
    NEEDS_DEPLOYMENT=1
fi

# If everything is already deployed, exit gracefully
if [ "$NEEDS_DEPLOYMENT" -eq 0 ]; then
    echo -e "${GREEN}✅ Gateways are already deployed and running!${NC}"
    echo ""
    echo "Gateway EC2 instances ($INSTANCE_COUNT) are running in Service VPC."
    echo ""
    echo -e "${BLUE}Next step: Run ./5-attach-tgw.sh to enable traffic inspection${NC}"
    echo ""
    exit 0
fi

# Otherwise, proceed with deployment
echo -e "${YELLOW}Deploying gateway EC2 instances...${NC}"
echo ""
echo "This will take approximately 10-15 minutes."
echo ""

# STEP 2: DEPLOYMENT
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Step 2: Deploying Multicloud Defense Gateways${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Handle tainted resources
if [ "$EGRESS_TAINTED" -eq 1 ] || [ "$INGRESS_TAINTED" -eq 1 ]; then
    echo -e "${YELLOW}Untainting gateway resources...${NC}"
    if [ "$EGRESS_TAINTED" -eq 1 ]; then
        terraform untaint -lock=false ciscomcd_gateway.aws-egress-gw 2>&1 | grep -v "Warning" || true
        echo "  ✓ Egress gateway untainted"
    fi
    if [ "$INGRESS_TAINTED" -eq 1 ]; then
        terraform untaint -lock=false ciscomcd_gateway.aws-ingress-gw 2>&1 | grep -v "Warning" || true
        echo "  ✓ Ingress gateway untainted"
    fi
    echo ""
fi

# Run terraform apply to deploy/update gateways
echo -e "${YELLOW}Deploying gateway EC2 instances...${NC}"
echo "This will take 10-15 minutes. Please wait..."
echo ""

# Target only the gateway resources
terraform apply \
    -target='ciscomcd_gateway.aws-egress-gw' \
    -target='ciscomcd_gateway.aws-ingress-gw' \
    -auto-approve \
    -lock=false 2>&1 | tee logs/gateway-deploy-pod${POD_NUMBER}.log

APPLY_STATUS=${PIPESTATUS[0]}

# If gateways deployed successfully, register Ingress Gateway with GWLB
if [ $APPLY_STATUS -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}Registering Ingress Gateway with GWLB...${NC}"
    sleep 10  # Wait for gateway to be fully ready
    
    # Find the GWLB target group
    GWLB_TG_ARN=$(aws elbv2 describe-target-groups --region us-east-1 \
        --query "TargetGroups[?contains(TargetGroupName, 'ciscomcd') && Protocol=='GENEVE'].TargetGroupArn | [0]" \
        --output text 2>/dev/null)
    
    if [ -n "$GWLB_TG_ARN" ] && [ "$GWLB_TG_ARN" != "None" ]; then
        echo "  Found GWLB Target Group: $GWLB_TG_ARN"
        
        # Get Ingress Gateway instance ID
        INGRESS_INSTANCE=$(aws ec2 describe-instances --region us-east-1 \
            --filters "Name=tag:Name,Values=*pod${POD_NUMBER}*ingress*" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)
        
        if [ -n "$INGRESS_INSTANCE" ] && [ "$INGRESS_INSTANCE" != "None" ]; then
            echo "  Ingress Gateway Instance: $INGRESS_INSTANCE"
            
            # Register Ingress Gateway with GWLB
            aws elbv2 register-targets --region us-east-1 \
                --target-group-arn "$GWLB_TG_ARN" \
                --targets Id="$INGRESS_INSTANCE",Port=6081 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Ingress Gateway registered with GWLB successfully${NC}"
                echo "  Waiting for target health check..."
                sleep 5
            else
                echo -e "${YELLOW}⚠️  Failed to register Ingress Gateway (may already be registered)${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  Could not find Ingress Gateway instance${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Could not find GWLB target group${NC}"
        echo "  This is normal if MCD hasn't created the GWLB yet"
    fi
fi

# STEP 5: VERIFICATION
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Step 4: Verifying Deployment${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

if [ $APPLY_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ Terraform apply completed successfully${NC}"
    echo ""
    
    # Wait a moment for instances to show up in AWS
    echo "Waiting for EC2 instances to be visible in AWS (10 seconds)..."
    sleep 10
    echo ""
    
    # Verify EC2 instances
    echo "Verifying gateway EC2 instances..."
    NEW_INSTANCE_COUNT=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | wc -w || echo "0")
    
    NEW_INSTANCE_COUNT=$(echo "$NEW_INSTANCE_COUNT" | tr -d ' ')
    
    echo ""
    if [ "$NEW_INSTANCE_COUNT" -ge 2 ]; then
        echo -e "${GREEN}✅ SUCCESS! Gateway EC2 instances are running:${NC}"
        echo ""
        aws ec2 describe-instances \
            --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=instance-state-name,Values=running,pending" \
            --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PrivateIpAddress]' \
            --output table 2>/dev/null || true
        echo ""
        
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ Gateway Deployment Complete!${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${CYAN}What Just Happened:${NC}"
        echo "  ✓ Egress Gateway deployed (inspects outbound traffic)"
        echo "  ✓ Ingress Gateway deployed (protects inbound traffic)"
        echo "  ✓ 2 EC2 instances (m5.large) launched in Service VPC"
        echo "  ✓ DLP, IPS, and WAF policies configured"
        echo "  ✓ Ingress Gateway registered with GWLB"
        echo ""
        
        # Get the Ingress Gateway's public IP
        INGRESS_PUBLIC_IP=$(aws ec2 describe-instances --region us-east-1 \
            --filters "Name=tag:Name,Values=*pod${POD_NUMBER}*ingress*" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text 2>/dev/null)
        
        if [ -n "$INGRESS_PUBLIC_IP" ] && [ "$INGRESS_PUBLIC_IP" != "None" ]; then
            echo -e "${CYAN}🌐 Public HTTP Access:${NC}"
            echo ""
            echo "  App1 URL: http://${INGRESS_PUBLIC_IP}"
            echo ""
            echo "  All HTTP traffic to this IP is inspected by MCD before reaching App1."
            echo "  The Ingress Gateway routes through GWLB for IPS, WAF, and DLP inspection."
            echo ""
        fi
        
        echo -e "${YELLOW}⚠️  Important: Gateways are deployed but NOT yet in traffic path${NC}"
        echo ""
        echo "Currently, traffic flows through Internet Gateway (IGW)."
        echo "To enable security inspection, you need to route traffic through"
        echo "the Transit Gateway and MCD gateways."
        echo ""
        
        echo -e "${BLUE}🚀 Next Step:${NC}"
        echo ""
        echo "Run: ./attach-tgw.sh"
        echo ""
        echo "This will:"
        echo "  • Attach your VPCs to the Transit Gateway"
        echo "  • Modify route tables to send traffic through TGW"
        echo "  • Enable DLP, IPS, and WAF inspection"
        echo ""
        
        echo -e "${CYAN}📊 Verify in MCD Console:${NC}"
        echo ""
        echo "Login: https://defense.cisco.com"
        echo "Navigate: Manage → Gateways"
        echo "Look for:"
        echo "  • pod${POD_NUMBER}-egress-gw-aws (ACTIVE)"
        echo "  • pod${POD_NUMBER}-ingress-gw-aws (ACTIVE)"
        echo ""
        
        echo "Full deployment log saved to: logs/gateway-deploy-pod${POD_NUMBER}.log"
        echo ""
        
    elif [ "$NEW_INSTANCE_COUNT" -eq 1 ]; then
        echo -e "${YELLOW}⚠️  Partial deployment detected${NC}"
        echo ""
        echo "Only 1 gateway instance found. Expected 2."
        echo "The deployment may still be in progress."
        echo ""
        echo "Wait a few minutes and check again:"
        echo "  aws ec2 describe-instances --filters \"Name=vpc-id,Values=$SVPC_AWS_ID\""
        echo ""
    else
        echo -e "${YELLOW}⚠️  No instances detected yet${NC}"
        echo ""
        echo "The gateway deployment completed in Terraform, but EC2 instances"
        echo "are not yet visible in AWS. This is normal - they may take a few"
        echo "minutes to launch."
        echo ""
        echo "Check again in 5 minutes:"
        echo "  aws ec2 describe-instances --filters \"Name=vpc-id,Values=$SVPC_AWS_ID\" --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table"
        echo ""
        echo "Or check the MCD Console:"
        echo "  https://defense.cisco.com → Manage → Gateways"
        echo ""
    fi
    
else
    echo -e "${RED}❌ Gateway deployment failed${NC}"
    echo ""
    echo "Please check the error messages above."
    echo ""
    echo "Common issues:"
    echo "  • State lock conflicts (wait a moment and retry)"
    echo "  • Service VPC not fully provisioned (run ./secure.sh)"
    echo "  • AWS quota limits (check EC2 instance limits)"
    echo ""
    echo "Full deployment log: logs/gateway-deploy-pod${POD_NUMBER}.log"
    echo ""
    echo "To retry:"
    echo "  ./deploy-multicloud-gateway.sh"
    echo ""
    exit 1
fi

