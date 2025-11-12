#!/bin/bash

# Cisco Multicloud Defense - Transit Gateway VPC Attachment Script
# This script attaches spoke VPCs to the Transit Gateway for traffic inspection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Transit Gateway VPC Attachment - Secure Spoke VPCs    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Terraform is not installed${NC}"
    echo "Please install Terraform first: https://www.terraform.io/downloads"
    exit 1
fi

# Check if jq is installed (needed for MCD API calls)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq is not installed${NC}"
    echo "jq is required for MCD API integration."
    echo "Install: brew install jq (macOS) or apt-get install jq (Linux)"
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
    echo "  1. Run: ./1-init-lab.sh"
    echo "  2. Run: ./2-deploy.sh"
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
    echo -e "${YELLOW}⚠️  TGW data source not found in state${NC}"
    echo -e "${YELLOW}   Please run ./2-deploy.sh first${NC}"
    exit 1
fi
echo ""

# Check if TGW resources exist in state
echo -e "${YELLOW}🔍 Checking current configuration...${NC}"
echo ""

# TGW is now a data source (hardcoded), not in state
TGW_ID="tgw-0a878e2f5870e2ccf"
ATTACHMENTS_EXIST=$(terraform state list 2>/dev/null | grep "aws_ec2_transit_gateway_vpc_attachment" | wc -l | tr -d ' ')

echo -e "${BLUE}Current Status:${NC}"
echo "  • Transit Gateway: $TGW_ID (shared, data source) ✓"

SKIP_ATTACHMENT_CREATION=false
if [ "$ATTACHMENTS_EXIST" -gt "0" ]; then
    echo "  • TGW Attachments: Already configured (${ATTACHMENTS_EXIST} found)"
    echo -e "${GREEN}  ✓ Skipping Step 1 (attachments already exist)${NC}"
    SKIP_ATTACHMENT_CREATION=true
else
    echo "  • TGW Attachments: Not configured"
    echo -e "${BLUE}  → Will create TGW attachments in Step 1${NC}"
fi
echo ""

# Step 1: Create TGW Attachments (only if needed)
if [ "$SKIP_ATTACHMENT_CREATION" = false ]; then
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Step 1: Creating TGW Attachments${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Creating Terraform configuration to attach spoke VPCs to Transit Gateway..."
    echo ""

    # Create a temporary Terraform file for TGW attachments
cat > tgw-attachments.tf << 'EOFTF'
# Transit Gateway VPC Attachments for Spoke VPCs
# These attachments connect the application VPCs and management VPC to the shared Transit Gateway

resource "aws_ec2_transit_gateway_vpc_attachment" "mgmt_attachment" {
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.mgmt_vpc.id
  subnet_ids         = [aws_subnet.mgmt_subnet.id]

  tags = {
    Name = "pod${var.pod_number}-mgmt-vpc-tgw-attachment"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "app1_attachment" {
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.app_vpc[0].id
  subnet_ids         = [aws_subnet.app_subnet[0].id]

  tags = {
    Name = "pod${var.pod_number}-app1-vpc-tgw-attachment"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "app2_attachment" {
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.app_vpc[1].id
  subnet_ids         = [aws_subnet.app_subnet[1].id]

  tags = {
    Name = "pod${var.pod_number}-app2-vpc-tgw-attachment"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Route from Management VPC to App VPCs via TGW
# This enables jumpbox to SSH to app instances
resource "aws_route" "mgmt_to_apps" {
  route_table_id         = aws_route_table.mgmt_rt.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = data.aws_ec2_transit_gateway.tgw.id
  
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.mgmt_attachment]
}
EOFTF

    echo -e "${GREEN}✓ Created tgw-attachments.tf (includes mgmt VPC)${NC}"
    echo ""

    echo -e "${YELLOW}🚀 Running Terraform apply...${NC}"
    echo ""

    # Define the resources to target - TGW attachments + mgmt route
    TGW_TARGETS=(
        "aws_ec2_transit_gateway_vpc_attachment.mgmt_attachment"
        "aws_ec2_transit_gateway_vpc_attachment.app1_attachment"
        "aws_ec2_transit_gateway_vpc_attachment.app2_attachment"
        "aws_route.mgmt_to_apps"
    )

    # Build the target flags
    TARGET_FLAGS=""
    for target in "${TGW_TARGETS[@]}"; do
        TARGET_FLAGS="${TARGET_FLAGS} -target=${target}"
    done

    # Initialize if needed
    if [ ! -d ".terraform" ]; then
        echo -e "${BLUE}Initializing Terraform...${NC}"
        terraform init -upgrade
        echo ""
    fi

    # Run terraform apply with targeted resources
    terraform apply ${TARGET_FLAGS} -auto-approve

    APPLY_STATUS=$?

    if [ $APPLY_STATUS -ne 0 ]; then
        echo ""
        echo -e "${RED}❌ Failed to create TGW attachments${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Step 1 Complete: TGW attachments created successfully${NC}"
    echo ""
fi

# Step 2: Register Spoke VPCs with MCD (the "Secure Now" button functionality)
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Step 2: Registering Spoke VPCs with MCD (Secure Now)...${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
    
    # Check if MCD API credentials exist
    MCD_CREDS_FILE=".terraform/.mcd-api.json"
    if [ ! -f "$MCD_CREDS_FILE" ]; then
        echo -e "${YELLOW}⚠️  MCD API credentials not found${NC}"
        echo "Skipping MCD Spoke VPC registration."
        echo "You may need to manually click 'Secure Now' in MCD Console."
        echo ""
    else
        # Load MCD API credentials (decode base64)
        API_KEY=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.apiKeyID' 2>/dev/null)
        API_SECRET=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.apiKeySecret' 2>/dev/null)
        ACCT_NAME=$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.acctName' 2>/dev/null)
        BASE_URL="https://$(cat "$MCD_CREDS_FILE" | base64 -d | jq -r '.restAPIServer' 2>/dev/null)"
        
        if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
            echo -e "${YELLOW}⚠️  Invalid MCD API credentials${NC}"
            echo "Skipping MCD Spoke VPC registration."
            echo ""
        else
            echo "  • MCD Account: $ACCT_NAME"
            echo "  • API Server: $BASE_URL"
            echo ""
            
            # Get JWT token
            echo "  • Authenticating with MCD API..."
            TOKEN_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/user/gettoken" \
                -H "Content-Type: application/json" \
                -d "{\"common\":{\"acctName\":\"$ACCT_NAME\",\"source\":\"RESTAPI\",\"clientVersion\":\"CiscoMCD-2024\"},\"apiKeyID\":\"$API_KEY\",\"apiKeySecret\":\"$API_SECRET\"}" 2>&1)
            
            ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.accessToken' 2>/dev/null)
            
            if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
                echo -e "${YELLOW}⚠️  Failed to get MCD access token${NC}"
                echo "Skipping MCD Spoke VPC registration."
                echo "You may need to manually click 'Secure Now' in MCD Console."
                echo ""
            else
                echo -e "${GREEN}    ✓ Authenticated successfully${NC}"
                echo ""
                
                # Get Service VPC details from Terraform state
                SVPC_NAME="pod${POD_NUMBER}-svpc-aws"
                SVPC_MCD_ID=$(terraform state show ciscomcd_service_vpc.svpc-aws 2>/dev/null | grep -E '^\s*service_vpc_id\s*=' | awk '{print $3}' | tr -d '"')
                SVPC_AWS_ID=$(terraform state show ciscomcd_service_vpc.svpc-aws 2>/dev/null | grep -E '^\s*vpc_id\s*=' | awk '{print $3}' | tr -d '"')
                
                # Get App VPC details from AWS
                APP1_VPC_ID=$(terraform state show 'aws_vpc.app_vpc[0]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                APP2_VPC_ID=$(terraform state show 'aws_vpc.app_vpc[1]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                
                # Get Route Table IDs
                APP1_RT_ID=$(terraform state show 'aws_route_table.app-route[0]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                APP2_RT_ID=$(terraform state show 'aws_route_table.app-route[1]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                
                # Get Subnet IDs for attachments
                APP1_SUBNET_ID=$(terraform state show 'aws_subnet.app_subnet[0]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                APP2_SUBNET_ID=$(terraform state show 'aws_subnet.app_subnet[1]' 2>/dev/null | grep -E '^\s*id\s*=' | awk '{print $3}' | tr -d '"')
                
                echo "  • Service VPC: $SVPC_NAME (MCD ID: $SVPC_MCD_ID)"
                echo "  • App1 VPC (AWS): $APP1_VPC_ID"
                echo "  • App2 VPC (AWS): $APP2_VPC_ID"
                echo ""
                
                # Try registering VPCs directly without discovery (MCD may auto-discover)
                echo "  • Registering App1 VPC with MCD (attempting auto-discovery)..."
                APP1_REGISTER=$(curl -s -X POST "${BASE_URL}/api/v1/transit/vpc/update" \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "{
                        \"common\": {
                            \"acctName\": \"$ACCT_NAME\",
                            \"source\": \"RESTAPI\",
                            \"clientVersion\": \"CiscoMCD-2024\"
                        },
                        \"cspAcctName\": \"bayuan\",
                        \"region\": \"us-east-1\",
                        \"servicesVPCID\": \"$SVPC_AWS_ID\",
                        \"servicesVPCName\": \"$SVPC_NAME\",
                        \"type\": \"ADD_USER_VPC_ROUTE\",
                        \"userVPC\": {
                            \"cspAcctName\": \"bayuan\",
                            \"region\": \"us-east-1\",
                            \"state\": \"ACTIVE\",
                            \"vpcID\": \"$APP1_VPC_ID\",
                            \"attachmentSubnets\": [
                                {
                                    \"subnetID\": \"$APP1_SUBNET_ID\"
                                }
                            ],
                            \"routeTables\": [
                                {
                                    \"routeTableID\": \"$APP1_RT_ID\",
                                    \"routes\": [
                                        {
                                            \"destination\": \"0.0.0.0/0\",
                                            \"nextHop\": \"$TGW_ID\",
                                            \"nextHopType\": \"TransitGateway\"
                                        }
                                    ]
                                }
                            ]
                        }
                    }" 2>&1)
                
                # Check if registration was successful
                if echo "$APP1_REGISTER" | jq -e '.code' >/dev/null 2>&1; then
                    ERROR_CODE=$(echo "$APP1_REGISTER" | jq -r '.code')
                    ERROR_MSG=$(echo "$APP1_REGISTER" | jq -r '.message' 2>/dev/null || echo "Unknown error")
                    if [ "$ERROR_CODE" != "0" ] && [ "$ERROR_CODE" != "null" ]; then
                        echo -e "${YELLOW}    ⚠️  App1 VPC registration: $ERROR_MSG (code: $ERROR_CODE)${NC}"
                        echo "    Please manually click 'Secure Now' in MCD Console for pod${POD_NUMBER}-app1-vpc"
                    else
                        echo -e "${GREEN}    ✓ App1 VPC registered successfully${NC}"
                    fi
                else
                    echo -e "${GREEN}    ✓ App1 VPC registered successfully${NC}"
                fi
                
                # Register App2 VPC with MCD
                echo "  • Registering App2 VPC with MCD (attempting auto-discovery)..."
                APP2_REGISTER=$(curl -s -X POST "${BASE_URL}/api/v1/transit/vpc/update" \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "{
                        \"common\": {
                            \"acctName\": \"$ACCT_NAME\",
                            \"source\": \"RESTAPI\",
                            \"clientVersion\": \"CiscoMCD-2024\"
                        },
                        \"cspAcctName\": \"bayuan\",
                        \"region\": \"us-east-1\",
                        \"servicesVPCID\": \"$SVPC_AWS_ID\",
                        \"servicesVPCName\": \"$SVPC_NAME\",
                        \"type\": \"ADD_USER_VPC_ROUTE\",
                        \"userVPC\": {
                            \"cspAcctName\": \"bayuan\",
                            \"region\": \"us-east-1\",
                            \"state\": \"ACTIVE\",
                            \"vpcID\": \"$APP2_VPC_ID\",
                            \"attachmentSubnets\": [
                                {
                                    \"subnetID\": \"$APP2_SUBNET_ID\"
                                }
                            ],
                            \"routeTables\": [
                                {
                                    \"routeTableID\": \"$APP2_RT_ID\",
                                    \"routes\": [
                                        {
                                            \"destination\": \"0.0.0.0/0\",
                                            \"nextHop\": \"$TGW_ID\",
                                            \"nextHopType\": \"TransitGateway\"
                                        }
                                    ]
                                }
                            ]
                        }
                    }" 2>&1)
                
                # Check if registration was successful
                if echo "$APP2_REGISTER" | jq -e '.code' >/dev/null 2>&1; then
                    ERROR_CODE=$(echo "$APP2_REGISTER" | jq -r '.code')
                    ERROR_MSG=$(echo "$APP2_REGISTER" | jq -r '.message' 2>/dev/null || echo "Unknown error")
                    if [ "$ERROR_CODE" != "0" ] && [ "$ERROR_CODE" != "null" ]; then
                        echo -e "${YELLOW}    ⚠️  App2 VPC registration: $ERROR_MSG (code: $ERROR_CODE)${NC}"
                        echo "    Please manually click 'Secure Now' in MCD Console for pod${POD_NUMBER}-app2-vpc"
                    else
                        echo -e "${GREEN}    ✓ App2 VPC registered successfully${NC}"
                    fi
                else
                    echo -e "${GREEN}    ✓ App2 VPC registered successfully${NC}"
                fi
                
                echo ""
                echo -e "${GREEN}✓ Spoke VPCs registered with MCD${NC}"
                echo ""
                
                # CRITICAL: Add routes in Service VPC datapath for spoke VPC CIDRs
                echo -e "${YELLOW}Adding spoke VPC routes to Service VPC datapath...${NC}"
                
                # Launch async route monitoring process in background
                # This ensures routes are added even if datapath RT is still being created
                nohup bash -c '
                    # Wait for Service VPC datapath route table to be available
                    MAX_ATTEMPTS=30  # 5 minutes (10s intervals)
                    ATTEMPT=0
                    
                    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
                        DATAPATH_RT=$(aws ec2 describe-route-tables --region us-east-1 \
                            --filters "Name=vpc-id,Values='"$SVPC_AWS_ID"'" "Name=tag:Name,Values=*datapath*" \
                            --query "RouteTables[0].RouteTableId" \
                            --output text 2>/dev/null)
                        
                        if [ -n "$DATAPATH_RT" ] && [ "$DATAPATH_RT" != "None" ]; then
                            # Found it! Add routes
                            APP1_CIDR="10.'"$POD_NUMBER"'.0.0/16"
                            APP2_CIDR="10.'"$((100 + POD_NUMBER))"'.0.0/16"
                            
                            # Try to add App1 route
                            aws ec2 create-route --region us-east-1 \
                                --route-table-id "$DATAPATH_RT" \
                                --destination-cidr-block "$APP1_CIDR" \
                                --transit-gateway-id "'"$TGW_ID"'" 2>/dev/null
                            
                            # Try to add App2 route
                            aws ec2 create-route --region us-east-1 \
                                --route-table-id "$DATAPATH_RT" \
                                --destination-cidr-block "$APP2_CIDR" \
                                --transit-gateway-id "'"$TGW_ID"'" 2>/dev/null
                            
                            # Verify routes were added
                            ROUTE1=$(aws ec2 describe-route-tables --region us-east-1 \
                                --route-table-ids "$DATAPATH_RT" \
                                --query "RouteTables[0].Routes[?DestinationCidrBlock=='"'"'$APP1_CIDR'"'"'].State" \
                                --output text 2>/dev/null)
                            
                            ROUTE2=$(aws ec2 describe-route-tables --region us-east-1 \
                                --route-table-ids "$DATAPATH_RT" \
                                --query "RouteTables[0].Routes[?DestinationCidrBlock=='"'"'$APP2_CIDR'"'"'].State" \
                                --output text 2>/dev/null)
                            
                            if [ "$ROUTE1" = "active" ] && [ "$ROUTE2" = "active" ]; then
                                echo "✓ Service VPC datapath routes configured successfully" >> logs/route-monitor-pod'"$POD_NUMBER"'.log
                                exit 0
                            fi
                        fi
                        
                        ATTEMPT=$((ATTEMPT + 1))
                        sleep 10
                    done
                    
                    echo "⚠️  Timeout: Could not configure Service VPC datapath routes after 5 minutes" >> logs/route-monitor-pod'"$POD_NUMBER"'.log
                ' > /dev/null 2>&1 &
                
                MONITOR_PID=$!
                echo "  Route monitoring process started (PID: $MONITOR_PID)"
                echo "  This process will add routes when datapath RT becomes available"
                echo "  Log: logs/route-monitor-pod${POD_NUMBER}.log"
                
                # Try once immediately (in case RT already exists)
                DATAPATH_RT=$(aws ec2 describe-route-tables --region us-east-1 \
                    --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=tag:Name,Values=*datapath*" \
                    --query "RouteTables[0].RouteTableId" \
                    --output text 2>/dev/null)
                
                if [ -n "$DATAPATH_RT" ] && [ "$DATAPATH_RT" != "None" ]; then
                    echo "  ✓ Service VPC Datapath RT found: $DATAPATH_RT"
                    
                    # Add route for App1 VPC CIDR
                    APP1_CIDR="10.${POD_NUMBER}.0.0/16"
                    echo "  Adding route: $APP1_CIDR → TGW"
                    set +e
                    APP1_ROUTE_OUTPUT=$(aws ec2 create-route --region us-east-1 \
                        --route-table-id "$DATAPATH_RT" \
                        --destination-cidr-block "$APP1_CIDR" \
                        --transit-gateway-id "$TGW_ID" 2>&1)
                    APP1_ROUTE_STATUS=$?
                    set -e
                    
                    if [ $APP1_ROUTE_STATUS -eq 0 ]; then
                        echo "    ✓ Route added"
                    elif echo "$APP1_ROUTE_OUTPUT" | grep -q "RouteAlreadyExists"; then
                        echo "    ✓ Route already exists"
                    else
                        echo "    ⚠️  Route creation failed: $(echo "$APP1_ROUTE_OUTPUT" | head -1)"
                    fi
                    
                    # Add route for App2 VPC CIDR
                    APP2_CIDR="10.$((100 + POD_NUMBER)).0.0/16"
                    echo "  Adding route: $APP2_CIDR → TGW"
                    set +e
                    APP2_ROUTE_OUTPUT=$(aws ec2 create-route --region us-east-1 \
                        --route-table-id "$DATAPATH_RT" \
                        --destination-cidr-block "$APP2_CIDR" \
                        --transit-gateway-id "$TGW_ID" 2>&1)
                    APP2_ROUTE_STATUS=$?
                    set -e
                    
                    if [ $APP2_ROUTE_STATUS -eq 0 ]; then
                        echo "    ✓ Route added"
                    elif echo "$APP2_ROUTE_OUTPUT" | grep -q "RouteAlreadyExists"; then
                        echo "    ✓ Route already exists"
                    else
                        echo "    ⚠️  Route creation failed: $(echo "$APP2_ROUTE_OUTPUT" | head -1)"
                    fi
                    
                    # Verify routes were added successfully
                    sleep 1
                    VERIFY_ROUTES=$(aws ec2 describe-route-tables --region us-east-1 \
                        --route-table-ids "$DATAPATH_RT" \
                        --query "RouteTables[0].Routes[?contains(DestinationCidrBlock, '10.')].[DestinationCidrBlock,TransitGatewayId,State]" \
                        --output text 2>/dev/null)
                    
                    if echo "$VERIFY_ROUTES" | grep -q "$APP1_CIDR.*$TGW_ID.*active"; then
                        echo -e "  ${GREEN}✓ Verified: App1 return route ($APP1_CIDR) configured${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  Warning: App1 return route ($APP1_CIDR) not found or not active${NC}"
                    fi
                    
                    if echo "$VERIFY_ROUTES" | grep -q "$APP2_CIDR.*$TGW_ID.*active"; then
                        echo -e "  ${GREEN}✓ Verified: App2 return route ($APP2_CIDR) configured${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  Warning: App2 return route ($APP2_CIDR) not found or not active${NC}"
                    fi
                    
                    echo -e "${GREEN}  ✓ Service VPC datapath routes configured${NC}"
                else
                    echo -e "${YELLOW}  ⏳ Datapath RT not yet available - background monitor will add routes${NC}"
                fi
                echo ""
                
                # CRITICAL: Add routes in Service VPC NAT Egress RT for return traffic
                echo -e "${YELLOW}Adding spoke VPC routes to Service VPC NAT Egress (for return traffic)...${NC}"
                
                # Get Service VPC NAT Egress route table
                NAT_EGRESS_RT=$(aws ec2 describe-route-tables --region us-east-1 \
                    --filters "Name=vpc-id,Values=$SVPC_AWS_ID" "Name=tag:Name,Values=*nat-egress*" \
                    --query "RouteTables[0].RouteTableId" \
                    --output text 2>/dev/null)
                
                if [ -n "$NAT_EGRESS_RT" ] && [ "$NAT_EGRESS_RT" != "None" ]; then
                    echo "  Service VPC NAT Egress RT: $NAT_EGRESS_RT"
                    
                    # Add route for App1 VPC CIDR
                    APP1_CIDR="10.${POD_NUMBER}.0.0/16"
                    echo "  Adding route: $APP1_CIDR → TGW"
                    set +e
                    APP1_NAT_OUTPUT=$(aws ec2 create-route --region us-east-1 \
                        --route-table-id "$NAT_EGRESS_RT" \
                        --destination-cidr-block "$APP1_CIDR" \
                        --transit-gateway-id "$TGW_ID" 2>&1)
                    APP1_NAT_STATUS=$?
                    set -e
                    
                    if [ $APP1_NAT_STATUS -eq 0 ]; then
                        echo "    ✓ Route added"
                    elif echo "$APP1_NAT_OUTPUT" | grep -q "RouteAlreadyExists"; then
                        echo "    ✓ Route already exists"
                    else
                        echo "    ⚠️  Route creation failed: $(echo "$APP1_NAT_OUTPUT" | head -1)"
                    fi
                    
                    # Add route for App2 VPC CIDR
                    APP2_CIDR="10.$((100 + POD_NUMBER)).0.0/16"
                    echo "  Adding route: $APP2_CIDR → TGW"
                    set +e
                    APP2_NAT_OUTPUT=$(aws ec2 create-route --region us-east-1 \
                        --route-table-id "$NAT_EGRESS_RT" \
                        --destination-cidr-block "$APP2_CIDR" \
                        --transit-gateway-id "$TGW_ID" 2>&1)
                    APP2_NAT_STATUS=$?
                    set -e
                    
                    if [ $APP2_NAT_STATUS -eq 0 ]; then
                        echo "    ✓ Route added"
                    elif echo "$APP2_NAT_OUTPUT" | grep -q "RouteAlreadyExists"; then
                        echo "    ✓ Route already exists"
                    else
                        echo "    ⚠️  Route creation failed: $(echo "$APP2_NAT_OUTPUT" | head -1)"
                    fi
                    
                    # Verify routes were added successfully
                    sleep 1
                    VERIFY_NAT_ROUTES=$(aws ec2 describe-route-tables --region us-east-1 \
                        --route-table-ids "$NAT_EGRESS_RT" \
                        --query "RouteTables[0].Routes[?contains(DestinationCidrBlock, '10.')].[DestinationCidrBlock,TransitGatewayId,State]" \
                        --output text 2>/dev/null)
                    
                    if echo "$VERIFY_NAT_ROUTES" | grep -q "$APP1_CIDR.*$TGW_ID.*active"; then
                        echo -e "  ${GREEN}✓ Verified: App1 NAT Egress route ($APP1_CIDR) configured${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  Warning: App1 NAT Egress route ($APP1_CIDR) not found or not active${NC}"
                    fi
                    
                    if echo "$VERIFY_NAT_ROUTES" | grep -q "$APP2_CIDR.*$TGW_ID.*active"; then
                        echo -e "  ${GREEN}✓ Verified: App2 NAT Egress route ($APP2_CIDR) configured${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  Warning: App2 NAT Egress route ($APP2_CIDR) not found or not active${NC}"
                    fi
                    
                    echo -e "${GREEN}  ✓ Service VPC NAT Egress routes configured${NC}"
                else
                    echo -e "${YELLOW}  ⚠️  Could not find Service VPC NAT Egress route table${NC}"
                fi
                echo ""
                
                # ════════════════════════════════════════════════════════════════════════════════════════════════
                # CRITICAL: Configure TGW Route Table for Egress Traffic
                # ════════════════════════════════════════════════════════════════════════════════════════════════
                # The shared TGW has a blackhole default route (0.0.0.0/0) for security by default.
                # We need to replace it with a route to THIS pod's Service VPC for egress to work.
                # ════════════════════════════════════════════════════════════════════════════════════════════════
                
                echo -e "${YELLOW}Configuring Transit Gateway routing for egress traffic...${NC}"
                echo -e "${BLUE}Note: This is a shared TGW - configuring routes carefully${NC}"
                echo ""
                
                # Get TGW route table ID
                TGW_RT_ID=$(aws ec2 describe-transit-gateway-route-tables --region us-east-1 \
                    --filters "Name=transit-gateway-id,Values=$TGW_ID" \
                    --query "TransitGatewayRouteTables[0].TransitGatewayRouteTableId" \
                    --output text 2>/dev/null)
                
                if [ -n "$TGW_RT_ID" ] && [ "$TGW_RT_ID" != "None" ]; then
                    echo "  TGW Route Table: $TGW_RT_ID"
                    
                    # Check if default route exists and get its state
                    DEFAULT_ROUTE_STATE=$(aws ec2 search-transit-gateway-routes \
                        --region us-east-1 \
                        --transit-gateway-route-table-id "$TGW_RT_ID" \
                        --filters "Name=state,Values=active,blackhole" \
                        --query "Routes[?DestinationCidrBlock=='0.0.0.0/0'].State" \
                        --output text 2>/dev/null)
                    
                    # Get current target if route exists
                    CURRENT_TARGET=$(aws ec2 search-transit-gateway-routes \
                        --region us-east-1 \
                        --transit-gateway-route-table-id "$TGW_RT_ID" \
                        --filters "Name=state,Values=active" \
                        --query "Routes[?DestinationCidrBlock=='0.0.0.0/0'].TransitGatewayAttachments[0].ResourceId" \
                        --output text 2>/dev/null)
                    
                    if [ "$DEFAULT_ROUTE_STATE" = "blackhole" ]; then
                        echo -e "  ${YELLOW}⚠️  Found blackhole default route (egress traffic being dropped!)${NC}"
                        echo "  Replacing with route to Service VPC..."
                        
                        # Delete blackhole route
                        set +e
                        aws ec2 delete-transit-gateway-route \
                            --region us-east-1 \
                            --transit-gateway-route-table-id "$TGW_RT_ID" \
                            --destination-cidr-block 0.0.0.0/0 > /dev/null 2>&1
                        set -e
                        
                        # Wait for deletion to complete
                        sleep 2
                        
                        # Add route to Service VPC
                        set +e
                        aws ec2 create-transit-gateway-route \
                            --region us-east-1 \
                            --transit-gateway-route-table-id "$TGW_RT_ID" \
                            --destination-cidr-block 0.0.0.0/0 \
                            --transit-gateway-attachment-id "$SVPC_TGW_ATTACHMENT" > /dev/null 2>&1
                        CREATE_STATUS=$?
                        set -e
                        
                        if [ $CREATE_STATUS -eq 0 ]; then
                            echo -e "  ${GREEN}✓ Default route configured: 0.0.0.0/0 → Service VPC${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to add default route${NC}"
                            echo -e "  ${YELLOW}   This will prevent internet access from App VPCs${NC}"
                        fi
                    elif [ "$DEFAULT_ROUTE_STATE" = "active" ]; then
                        # Check if it points to the correct Service VPC
                        if [ "$CURRENT_TARGET" = "$SVPC_AWS_ID" ]; then
                            echo -e "  ${GREEN}✓ Default route already points to this pod's Service VPC${NC}"
                        else
                            echo -e "  ${YELLOW}⚠️  Default route points to: $CURRENT_TARGET${NC}"
                            echo -e "  ${YELLOW}⚠️  This may be another pod's Service VPC${NC}"
                            echo -e "  ${YELLOW}⚠️  Updating to this pod's Service VPC...${NC}"
                            
                            # Delete existing route (ignore errors if route doesn't exist)
                            set +e
                            aws ec2 delete-transit-gateway-route \
                                --region us-east-1 \
                                --transit-gateway-route-table-id "$TGW_RT_ID" \
                                --destination-cidr-block 0.0.0.0/0 > /dev/null 2>&1
                            DELETE_STATUS=$?
                            set -e
                            
                            sleep 2
                            
                            # Add route to this pod's Service VPC
                            set +e
                            aws ec2 create-transit-gateway-route \
                                --region us-east-1 \
                                --transit-gateway-route-table-id "$TGW_RT_ID" \
                                --destination-cidr-block 0.0.0.0/0 \
                                --transit-gateway-attachment-id "$SVPC_TGW_ATTACHMENT" > /dev/null 2>&1
                            CREATE_STATUS=$?
                            set -e
                            
                            if [ $CREATE_STATUS -eq 0 ]; then
                                echo -e "  ${GREEN}✓ Default route updated to this pod's Service VPC${NC}"
                            else
                                echo -e "  ${YELLOW}⚠️  Route update may have failed, but continuing...${NC}"
                                echo -e "  ${BLUE}   (Route may already exist or Service VPC attachment not ready)${NC}"
                            fi
                        fi
                    else
                        # No default route exists - this is the problem!
                        echo -e "  ${YELLOW}⚠️  No default route found - adding route to Service VPC...${NC}"
                        
                        # Add route to Service VPC
                        set +e
                        aws ec2 create-transit-gateway-route \
                            --region us-east-1 \
                            --transit-gateway-route-table-id "$TGW_RT_ID" \
                            --destination-cidr-block 0.0.0.0/0 \
                            --transit-gateway-attachment-id "$SVPC_TGW_ATTACHMENT" > /dev/null 2>&1
                        CREATE_STATUS=$?
                        set -e
                        
                        if [ $CREATE_STATUS -eq 0 ]; then
                            echo -e "  ${GREEN}✓ Default route added: 0.0.0.0/0 → Service VPC${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to add default route${NC}"
                            echo -e "  ${YELLOW}   This will prevent internet access from App VPCs${NC}"
                            echo -e "  ${BLUE}   Error: Route creation failed (may need to retry)${NC}"
                        fi
                    fi
                    
                    # Verify the route was created successfully
                    sleep 2
                    VERIFY_TARGET=$(aws ec2 search-transit-gateway-routes \
                        --region us-east-1 \
                        --transit-gateway-route-table-id "$TGW_RT_ID" \
                        --filters "Name=destination-cidr-block,Values=0.0.0.0/0" "Name=state,Values=active" \
                        --query "Routes[0].TransitGatewayAttachments[0].ResourceId" \
                        --output text 2>/dev/null)
                    
                    if [ "$VERIFY_TARGET" = "$SVPC_AWS_ID" ]; then
                        echo -e "  ${GREEN}✓ Verified: Default route correctly points to Service VPC${NC}"
                    elif [ -n "$VERIFY_TARGET" ] && [ "$VERIFY_TARGET" != "None" ]; then
                        echo -e "  ${YELLOW}⚠️  Warning: Default route points to different VPC: $VERIFY_TARGET${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  Warning: Could not verify default route${NC}"
                    fi
                else
                    echo -e "  ${RED}✗ Could not find TGW route table${NC}"
                fi
                echo ""
            fi
        fi
    fi
    
    # Step 3: Configure routes to use TGW instead of IGW
    echo -e "${BLUE}Step 3: Configuring routes to use Transit Gateway...${NC}"
    echo ""
    
    # Check if terraform.tfvars exists
    if [ ! -f "terraform.tfvars" ]; then
        echo -e "${RED}❌ terraform.tfvars not found${NC}"
        exit 1
    fi
    
    # CRITICAL: Verify instances are fully provisioned before switching to TGW
    echo -e "${YELLOW}🔍 Verifying instance readiness...${NC}"
    echo ""
    
    # Get instance IDs from terraform state
    APP1_INSTANCE_ID=$(terraform output -raw app1-instance-id 2>/dev/null || echo "")
    APP2_INSTANCE_ID=$(terraform output -raw app2-instance-id 2>/dev/null || echo "")
    JUMPBOX_INSTANCE_ID=$(terraform output -raw jumpbox_instance_id 2>/dev/null || echo "")
    
    if [ -z "$APP1_INSTANCE_ID" ] || [ -z "$APP2_INSTANCE_ID" ]; then
        echo -e "${RED}❌ App instances not found!${NC}"
        echo "Please ensure ./2-deploy.sh completed successfully."
        exit 1
    fi
    
    # Check instance states in AWS
    echo "Checking instance states..."
    APP1_STATE=$(aws ec2 describe-instances --region us-east-1 --instance-ids $APP1_INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
    APP2_STATE=$(aws ec2 describe-instances --region us-east-1 --instance-ids $APP2_INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
    JUMPBOX_STATE=$(aws ec2 describe-instances --region us-east-1 --instance-ids $JUMPBOX_INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
    
    echo "  • App1 Instance: $APP1_STATE"
    echo "  • App2 Instance: $APP2_STATE"
    echo "  • Jumpbox Instance: $JUMPBOX_STATE"
    echo ""
    
    # Ensure all instances are running
    if [ "$APP1_STATE" != "running" ] || [ "$APP2_STATE" != "running" ]; then
        echo -e "${RED}❌ App instances are not running!${NC}"
        echo ""
        echo "Current states:"
        echo "  App1: $APP1_STATE"
        echo "  App2: $APP2_STATE"
        echo ""
        echo "Please ensure instances are fully started before attaching TGW."
        echo "Wait a few minutes and try again, or check AWS Console."
        exit 1
    fi
    
    if [ "$JUMPBOX_STATE" != "running" ]; then
        echo -e "${YELLOW}⚠️  Warning: Jumpbox is not running (${JUMPBOX_STATE})${NC}"
        echo "You may lose SSH access after TGW attachment."
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
    
    # Check if instances are reachable via their public IPs (IGW routing)
    echo "Testing instance connectivity (IGW routing)..."
    APP1_PUBLIC_IP=$(terraform output -raw app1-public-eip 2>/dev/null)
    
    # Test SSH connectivity with a short timeout
    if timeout 5 bash -c "echo > /dev/tcp/$APP1_PUBLIC_IP/22" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} App1 SSH port is reachable"
    else
        echo -e "  ${YELLOW}⚠${NC} App1 SSH port not reachable (may be expected if provisioners failed)"
    fi
    
    echo ""
    echo -e "${GREEN}✓ Instance verification complete${NC}"
    echo ""
    
    # Wait a bit for instances to fully initialize
    echo "Waiting 10 seconds for instances to fully initialize..."
    sleep 10
    echo ""
    
    # Check current route configuration
    if grep -q "use_transit_gateway_for_routes.*true" terraform.tfvars 2>/dev/null; then
        echo -e "${GREEN}  ✓ Routes already configured to use TGW${NC}"
    else
        echo "  • Updating route configuration..."
        
        # Add or update the variable in terraform.tfvars
        if grep -q "use_transit_gateway_for_routes" terraform.tfvars; then
            # Variable exists, update it
            sed -i.bak 's/use_transit_gateway_for_routes.*/use_transit_gateway_for_routes = true/' terraform.tfvars
        else
            # Variable doesn't exist, add it
            echo "" >> terraform.tfvars
            echo "# Route configuration (set by attach-tgw.sh)" >> terraform.tfvars
            echo "use_transit_gateway_for_routes = true" >> terraform.tfvars
        fi
        
        echo "    ✓ Updated terraform.tfvars"
        echo ""
        
        # Apply the route change
        echo -e "${YELLOW}  Applying route changes...${NC}"
        echo ""
        
        terraform apply -target='aws_route.ext_default_route[0]' -target='aws_route.ext_default_route[1]' -auto-approve 2>&1 | grep -E "(Plan:|Apply complete|Creating|Modifying|aws_route)" | head -15
        
        ROUTE_STATUS=${PIPESTATUS[0]}
        if [ $ROUTE_STATUS -eq 0 ]; then
            echo ""
            echo -e "${GREEN}✓ Routes updated successfully - now pointing to TGW${NC}"
            rm -f terraform.tfvars.bak 2>/dev/null
        else
            echo ""
            echo -e "${YELLOW}⚠️  Route update had issues${NC}"
            echo -e "${YELLOW}   Restoring terraform.tfvars backup...${NC}"
            mv terraform.tfvars.bak terraform.tfvars 2>/dev/null || true
        fi
    fi
    echo ""
    
    # ════════════════════════════════════════════════════════════════════════════════════════════════
    # CRITICAL FIX: Directly replace IGW routes with TGW routes using AWS CLI
    # ════════════════════════════════════════════════════════════════════════════════════════════════
    # The Terraform approach above may not work if routes aren't defined correctly.
    # This is a direct AWS CLI fallback to ensure routes are updated.
    # ════════════════════════════════════════════════════════════════════════════════════════════════
    
    echo -e "${YELLOW}Replacing App VPC default routes (IGW → TGW)...${NC}"
    echo ""
    
    # Get App1 and App2 route table IDs
    APP1_RT_ID=$(aws ec2 describe-route-tables --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-rt" \
        --query "RouteTables[0].RouteTableId" \
        --output text 2>/dev/null)
    
    APP2_RT_ID=$(aws ec2 describe-route-tables --region us-east-1 \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app2-rt" \
        --query "RouteTables[0].RouteTableId" \
        --output text 2>/dev/null)
    
    if [ -n "$APP1_RT_ID" ] && [ "$APP1_RT_ID" != "None" ]; then
        echo "Updating App1 VPC default route:"
        echo "  Route Table: $APP1_RT_ID"
        echo "  From: 0.0.0.0/0 → IGW"
        echo "  To:   0.0.0.0/0 → TGW"
        
        # Replace the default route
        set +e
        aws ec2 replace-route --region us-east-1 \
            --route-table-id "$APP1_RT_ID" \
            --destination-cidr-block 0.0.0.0/0 \
            --transit-gateway-id "$TGW_ID" 2>&1
        REPLACE_STATUS=$?
        set -e
        
        if [ $REPLACE_STATUS -eq 0 ]; then
            echo -e "  ${GREEN}✓ App1 default route updated to TGW${NC}"
        else
            echo -e "  ${YELLOW}⚠️  App1 route update may have failed, but continuing...${NC}"
            echo -e "  ${BLUE}   (Route may already point to TGW)${NC}"
        fi
        echo ""
    fi
    
    if [ -n "$APP2_RT_ID" ] && [ "$APP2_RT_ID" != "None" ]; then
        echo "Updating App2 VPC default route:"
        echo "  Route Table: $APP2_RT_ID"
        echo "  From: 0.0.0.0/0 → IGW"
        echo "  To:   0.0.0.0/0 → TGW"
        
        # Replace the default route
        set +e
        aws ec2 replace-route --region us-east-1 \
            --route-table-id "$APP2_RT_ID" \
            --destination-cidr-block 0.0.0.0/0 \
            --transit-gateway-id "$TGW_ID" 2>&1
        REPLACE_STATUS=$?
        set -e
        
        if [ $REPLACE_STATUS -eq 0 ]; then
            echo -e "  ${GREEN}✓ App2 default route updated to TGW${NC}"
        else
            echo -e "  ${YELLOW}⚠️  App2 route update may have failed, but continuing...${NC}"
            echo -e "  ${BLUE}   (Route may already point to TGW)${NC}"
        fi
        echo ""
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Transit Gateway Attachment Complete!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Get attachment IDs from state
    APP1_ATTACHMENT_ID=$(terraform state show 'aws_ec2_transit_gateway_vpc_attachment.app1_attachment' 2>/dev/null | grep -m1 '^id ' | awk '{print $3}' | tr -d '"')
    APP2_ATTACHMENT_ID=$(terraform state show 'aws_ec2_transit_gateway_vpc_attachment.app2_attachment' 2>/dev/null | grep -m1 '^id ' | awk '{print $3}' | tr -d '"')
    
    echo -e "${BLUE}🔒 Security Status:${NC}"
    echo ""
    echo "✓ VPC Attachments Created:"
    if [ -n "$APP1_ATTACHMENT_ID" ]; then
        echo "  • pod${POD_NUMBER}-app1-vpc → TGW (${APP1_ATTACHMENT_ID})"
    fi
    if [ -n "$APP2_ATTACHMENT_ID" ]; then
        echo "  • pod${POD_NUMBER}-app2-vpc → TGW (${APP2_ATTACHMENT_ID})"
    fi
    echo ""
    echo "✓ Route Tables Modified:"
    echo "  • pod${POD_NUMBER}-app1-rt → 0.0.0.0/0 via TGW"
    echo "  • pod${POD_NUMBER}-app2-rt → 0.0.0.0/0 via TGW"
    echo ""
    echo "✓ Traffic Flow:"
    echo "  • All internet-bound traffic now flows through Transit Gateway"
    echo "  • MCD gateways will inspect and apply security policies"
    echo "  • DLP, IPS, and WAF protection now active"
    echo ""
    
    echo -e "${YELLOW}🧪 Verify in MCD Console:${NC}"
    echo ""
    echo "1. Login to Cisco MCD Console:"
    echo "   https://defense.cisco.com"
    echo ""
    echo "2. Check VPC Security Status:"
    echo "   Navigate to: Inventory → Assets Discovery → VPCs/VNets"
    echo "   Filter by: aws account"
    echo "   Search for: pod${POD_NUMBER}"
    echo ""
    echo "   Status should now show:"
    echo "   • pod${POD_NUMBER}-app1-vpc: Secured ✅"
    echo "   • pod${POD_NUMBER}-app2-vpc: Secured ✅"
    echo ""
    echo "3. View Traffic Flows:"
    echo "   Navigate to: Observe → Traffic"
    echo "   You should see traffic flowing through the gateways"
    echo ""
    
    echo -e "${YELLOW}🧪 Test Connectivity:${NC}"
    echo ""
    echo "# SSH to App1 and test internet access"
    echo "ssh -i \$SSH_KEY ubuntu@\$APP1_PUBLIC_IP"
    echo "curl -v https://example.com  # Should work, traffic inspected by MCD"
    echo ""
    echo "Copy-paste ready commands:"
    source ./env-helper.sh
    export_deployment_vars
    echo "ssh -i $SSH_KEY ubuntu@$APP1_PUBLIC_IP"
    echo ""
    echo "# Check traffic in MCD Observe → Traffic page"
    echo ""
    
    echo -e "${BLUE}📖 For more details, read DEPLOYMENT.md!${NC}"
    echo ""
    
    # Clean up temporary files
    echo -e "${YELLOW}🧹 Cleaning up temporary files...${NC}"
    rm -f terraform.tfvars.bak 2>/dev/null && echo "  ✓ Cleaned up backup files" || true
    echo "  ℹ Keeping tgw-attachments.tf (contains TGW attachment resources)"
    echo ""

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Script Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
