#!/bin/bash

# Force Cleanup Script
# Use this if normal terraform destroy fails or resources are stuck

set -e

# Function to sanitize output by removing sensitive values
sanitize_output() {
    sed -E 's/AKIA[A-Z0-9]{16}/AKIA************/g' | \
    sed -E 's/[A-Za-z0-9/+=]{40}/****REDACTED****/g' | \
    sed -E 's/"api_key":\s*"[^"]*"/"api_key": "****REDACTED****"/g' | \
    sed -E 's/aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]*/aws_secret_access_key = ****REDACTED****/g'
}

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Force Cleanup - Last Resort                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  WARNING: This script forcefully removes resources"
echo "    Use only if normal 'terraform destroy' fails"
echo ""

# Prompt for pod number
read -p "Enter your pod number (1-60): " POD_NUMBER

# Validate pod number
if ! [[ "$POD_NUMBER" =~ ^[0-9]+$ ]] || [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 60 ]; then
    echo "❌ Error: Pod number must be between 1 and 60"
    exit 1
fi

echo ""
read -p "⚠️  Are you ABSOLUTELY sure? This cannot be undone. (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Force cleanup cancelled"
    exit 0
fi

echo ""
echo "🔧 Setting up AWS CLI..."
if ! command -v aws &> /dev/null; then
    echo "   AWS CLI not found. Please install it first:"
    echo "   https://aws.amazon.com/cli/"
    exit 1
fi

# Source shared credentials helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.credentials-helper.sh"

# Get credentials (uses cache or fetches)
if ! get_aws_credentials; then
    echo "❌ Failed to get credentials"
    exit 1
fi

# Configure AWS CLI temporarily
export AWS_DEFAULT_REGION="us-east-1"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Cleaning up Multicloud Defense resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run MCD cleanup script first
if [ -f "${SCRIPT_DIR}/cleanup-mcd-resources.sh" ]; then
    echo "🔧 Running MCD resource cleanup..."
    bash "${SCRIPT_DIR}/cleanup-mcd-resources.sh" "$POD_NUMBER" || {
        echo "⚠️  MCD cleanup encountered issues, but continuing with AWS cleanup..."
    }
    echo ""
else
    echo "⚠️  MCD cleanup script not found, skipping MCD cleanup"
    echo "   MCD resources may need to be manually deleted from the console"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Cleaning up AWS resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🔍 Finding resources for pod $POD_NUMBER..."
echo ""

REGION="us-east-1"

# Function to delete resources
delete_instances() {
    echo "🗑️  Terminating EC2 instances..."
    
    # Find app instances, jumpbox, AND MCD gateway instances
    INSTANCES=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1,pod${POD_NUMBER}-app2,pod${POD_NUMBER}-jumpbox,*pod${POD_NUMBER}*gw*" \
                  "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$INSTANCES" ]; then
        for INSTANCE in $INSTANCES; do
            echo "   Terminating instance: $INSTANCE"
            aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE 2>/dev/null || true
        done
        echo "   Waiting for instances to terminate..."
        sleep 45  # Increased wait time for gateway instances
    else
        echo "   No instances found"
    fi
}

delete_key_pairs() {
    echo "🔑 Deleting key pairs..."
    aws ec2 delete-key-pair --region $REGION --key-name "pod${POD_NUMBER}-keypair" 2>/dev/null || true
    echo "   ✓ Attempted to delete pod${POD_NUMBER}-keypair"
}

delete_eips() {
    echo "📌 Releasing Elastic IPs..."
    EIPS=$(aws ec2 describe-addresses \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-eip,pod${POD_NUMBER}-app2-eip,pod${POD_NUMBER}-jumpbox-eip,pod${POD_NUMBER}-ingress-gateway-eip" \
        --query 'Addresses[].AllocationId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$EIPS" ]; then
        for EIP in $EIPS; do
            echo "   Releasing EIP: $EIP"
            aws ec2 release-address --region $REGION --allocation-id $EIP 2>/dev/null || true
        done
    else
        echo "   No EIPs found"
    fi
}

delete_nat_gateways() {
    echo "🌐 Deleting NAT Gateways..."
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-vpc,pod${POD_NUMBER}-app2-vpc,pod${POD_NUMBER}-svpc-aws" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    for VPC in $VPCS; do
        NAT_GWS=$(aws ec2 describe-nat-gateways \
            --region $REGION \
            --filter "Name=vpc-id,Values=$VPC" \
            --query 'NatGateways[].NatGatewayId' \
            --output text 2>/dev/null || true)
        
        for NAT in $NAT_GWS; do
            echo "   Deleting NAT Gateway: $NAT"
            aws ec2 delete-nat-gateway --region $REGION --nat-gateway-id $NAT 2>/dev/null || true
        done
    done
}

delete_vpc_endpoints() {
    echo "🔌 Deleting VPC Endpoints..."
    
    # Get all VPCs for this pod
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$VPCS" ]; then
        for VPC in $VPCS; do
            VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
                --region $REGION \
                --filters "Name=vpc-id,Values=$VPC" \
                --query 'VpcEndpoints[].VpcEndpointId' \
                --output text 2>/dev/null || true)
            
            if [ -n "$VPC_ENDPOINTS" ]; then
                for VPCE_ID in $VPC_ENDPOINTS; do
                    VPCE_SERVICE=$(aws ec2 describe-vpc-endpoints \
                        --region $REGION \
                        --vpc-endpoint-ids $VPCE_ID \
                        --query 'VpcEndpoints[0].ServiceName' \
                        --output text 2>/dev/null || echo "unknown")
                    
                    echo "   Deleting VPC Endpoint: $VPCE_ID ($VPCE_SERVICE)"
                    aws ec2 delete-vpc-endpoints \
                        --region $REGION \
                        --vpc-endpoint-ids $VPCE_ID 2>/dev/null || \
                        echo "     Failed to delete $VPCE_ID"
                done
                
                # Wait for endpoints to be deleted
                echo "   Waiting for VPC endpoints to delete..."
                sleep 15
            fi
        done
    else
        echo "   No VPCs found for pod${POD_NUMBER}"
    fi
}

delete_vpc_endpoint_services() {
    echo "🔌 Deleting VPC Endpoint Service Configurations (for Gateway LBs)..."
    
    # Find VPC Endpoint Services that contain pod number in their associated Gateway LB
    VPCE_SERVICES=$(aws ec2 describe-vpc-endpoint-service-configurations \
        --region $REGION \
        --query "ServiceConfigurations[?GatewayLoadBalancerArns && contains(to_string(GatewayLoadBalancerArns), 'pod${POD_NUMBER}')].ServiceId" \
        --output text 2>/dev/null || true)
    
    if [ -n "$VPCE_SERVICES" ]; then
        echo "   Found $(echo $VPCE_SERVICES | wc -w | tr -d ' ') VPC Endpoint Service(s)"
        for VPCE_SVC_ID in $VPCE_SERVICES; do
            VPCE_SVC_NAME=$(aws ec2 describe-vpc-endpoint-service-configurations \
                --region $REGION \
                --service-ids $VPCE_SVC_ID \
                --query 'ServiceConfigurations[0].ServiceName' \
                --output text 2>/dev/null || echo "unknown")
            
            echo "   Deleting VPC Endpoint Service: $VPCE_SVC_ID"
            echo "      Service Name: $VPCE_SVC_NAME"
            aws ec2 delete-vpc-endpoint-service-configurations \
                --region $REGION \
                --service-ids $VPCE_SVC_ID 2>/dev/null && \
                echo "      ✓ Deleted" || \
                echo "      Failed to delete $VPCE_SVC_ID"
        done
        
        # Wait for VPC Endpoint Services to be deleted
        echo "   Waiting for VPC Endpoint Services to delete..."
        sleep 15
    else
        echo "   No VPC Endpoint Services found for pod${POD_NUMBER}"
    fi
}

delete_load_balancers() {
    echo "⚖️  Deleting Load Balancers (MCD Gateways)..."
    
    # Method 1: Find by name pattern (if it contains pod number)
    LBS_BY_NAME=$(aws elbv2 describe-load-balancers \
        --region $REGION \
        --query "LoadBalancers[?contains(LoadBalancerName, 'pod${POD_NUMBER}')].LoadBalancerArn" \
        --output text 2>/dev/null || true)
    
    # Method 2: Find by VPC ID (more reliable for MCD-created LBs)
    # Get all VPCs for this pod
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-vpc,pod${POD_NUMBER}-app2-vpc,pod${POD_NUMBER}-svpc-aws,pod${POD_NUMBER}-mgmt-vpc" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    LBS_BY_VPC=""
    for VPC in $VPCS; do
        VPC_LBS=$(aws elbv2 describe-load-balancers \
            --region $REGION \
            --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" \
            --output text 2>/dev/null || true)
        LBS_BY_VPC="$LBS_BY_VPC $VPC_LBS"
    done
    
    # Combine and deduplicate
    ALL_LBS=$(echo "$LBS_BY_NAME $LBS_BY_VPC" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
    
    if [ -n "$ALL_LBS" ]; then
        LB_COUNT=$(echo "$ALL_LBS" | wc -l | tr -d ' ')
        echo "   Found $LB_COUNT load balancer(s)"
        
        # Separate Gateway LBs from others (Gateway LBs need VPC Endpoint Service deletion first)
        GATEWAY_LBS=""
        OTHER_LBS=""
        
        for LB_ARN in $ALL_LBS; do
            LB_TYPE=$(aws elbv2 describe-load-balancers \
                --region $REGION \
                --load-balancer-arns $LB_ARN \
                --query 'LoadBalancers[0].Type' \
                --output text 2>/dev/null || echo "unknown")
            
            if [ "$LB_TYPE" = "gateway" ]; then
                GATEWAY_LBS="$GATEWAY_LBS $LB_ARN"
            else
                OTHER_LBS="$OTHER_LBS $LB_ARN"
            fi
        done
        
        # Delete non-gateway load balancers first (Network, Application LBs)
        if [ -n "$OTHER_LBS" ]; then
            echo ""
            echo "   Deleting Network/Application Load Balancers first..."
            for LB_ARN in $OTHER_LBS; do
                LB_NAME=$(aws elbv2 describe-load-balancers \
                    --region $REGION \
                    --load-balancer-arns $LB_ARN \
                    --query 'LoadBalancers[0].LoadBalancerName' \
                    --output text 2>/dev/null || echo "unknown")
                
                LB_TYPE=$(aws elbv2 describe-load-balancers \
                    --region $REGION \
                    --load-balancer-arns $LB_ARN \
                    --query 'LoadBalancers[0].Type' \
                    --output text 2>/dev/null || echo "unknown")
                
                echo "      Deleting: $LB_NAME (Type: $LB_TYPE)"
                aws elbv2 delete-load-balancer \
                    --region $REGION \
                    --load-balancer-arn $LB_ARN 2>/dev/null && \
                    echo "      ✓ Deleted" || \
                    echo "      Failed to delete $LB_NAME"
            done
            echo "      Waiting 30 seconds for Network/Application LBs to delete..."
            sleep 30
        fi
        
        # Handle Gateway Load Balancers (need VPC Endpoint Service deletion first)
        if [ -n "$GATEWAY_LBS" ]; then
            echo ""
            echo "   Deleting Gateway Load Balancers (with VPC Endpoint Services)..."
            
            # Step 1: Delete VPC Endpoint Services for Gateway LBs
            delete_vpc_endpoint_services
            
            # Step 2: Delete Gateway Load Balancers
            for LB_ARN in $GATEWAY_LBS; do
                LB_NAME=$(aws elbv2 describe-load-balancers \
                    --region $REGION \
                    --load-balancer-arns $LB_ARN \
                    --query 'LoadBalancers[0].LoadBalancerName' \
                    --output text 2>/dev/null || echo "unknown")
                
                echo "      Deleting Gateway LB: $LB_NAME"
                aws elbv2 delete-load-balancer \
                    --region $REGION \
                    --load-balancer-arn $LB_ARN 2>/dev/null && \
                    echo "      ✓ Deleted" || \
                    echo "      Failed to delete $LB_NAME (may need more time)"
            done
            
            echo "      Waiting 45 seconds for Gateway LBs to delete..."
            sleep 45
        fi
        
        echo ""
        echo "   ✓ Load balancer deletion complete"
    else
        echo "   No load balancers found for pod${POD_NUMBER}"
    fi
}

delete_tgw_attachments() {
    echo "🔗 Deleting Transit Gateway VPC Attachments..."
    
    # Find all TGW attachments for this pod's VPCs
    TGW_ATTACHMENTS=$(aws ec2 describe-transit-gateway-vpc-attachments \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
        --query 'TransitGatewayVpcAttachments[?State!=`deleted`].TransitGatewayAttachmentId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$TGW_ATTACHMENTS" ]; then
        echo "   Found $(echo $TGW_ATTACHMENTS | wc -w | tr -d ' ') TGW attachment(s)"
        for ATTACH_ID in $TGW_ATTACHMENTS; do
            ATTACH_NAME=$(aws ec2 describe-transit-gateway-vpc-attachments \
                --region $REGION \
                --transit-gateway-attachment-ids $ATTACH_ID \
                --query 'TransitGatewayVpcAttachments[0].Tags[?Key==`Name`].Value' \
                --output text 2>/dev/null || echo "unknown")
            
            echo "   Deleting TGW Attachment: $ATTACH_ID ($ATTACH_NAME)"
            aws ec2 delete-transit-gateway-vpc-attachment \
                --region $REGION \
                --transit-gateway-attachment-id $ATTACH_ID 2>/dev/null || \
                echo "     Failed to delete $ATTACH_ID"
        done
        
        # Wait for attachments to be deleted
        echo "   Waiting for TGW attachments to delete..."
        sleep 30
        
        # Verify deletion
        REMAINING=$(aws ec2 describe-transit-gateway-vpc-attachments \
            --region $REGION \
            --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
            --query 'TransitGatewayVpcAttachments[?State!=`deleted`].TransitGatewayAttachmentId' \
            --output text 2>/dev/null || true)
        
        if [ -n "$REMAINING" ]; then
            echo "   ⚠️  Some attachments still deleting, waiting another 30 seconds..."
            sleep 30
        fi
    else
        echo "   No TGW attachments found for pod${POD_NUMBER}"
    fi
}

delete_network_interfaces() {
    echo "🔌 Deleting Network Interfaces..."
    
    # First, get all security groups for this pod
    SGS=$(aws ec2 describe-security-groups \
        --region $REGION \
        --filters "Name=group-name,Values=pod${POD_NUMBER}-*" \
        --query 'SecurityGroups[].GroupId' \
        --output text 2>/dev/null || true)
    
    # Get all VPCs for this pod
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    # Find ENIs by security group
    ENIS=""
    if [ -n "$SGS" ]; then
        for SG in $SGS; do
            SG_ENIS=$(aws ec2 describe-network-interfaces \
                --region $REGION \
                --filters "Name=group-id,Values=$SG" \
                --query 'NetworkInterfaces[].NetworkInterfaceId' \
                --output text 2>/dev/null || true)
            ENIS="$ENIS $SG_ENIS"
        done
    fi
    
    # Find ENIs by VPC
    if [ -n "$VPCS" ]; then
        for VPC in $VPCS; do
            VPC_ENIS=$(aws ec2 describe-network-interfaces \
                --region $REGION \
                --filters "Name=vpc-id,Values=$VPC" \
                --query 'NetworkInterfaces[].NetworkInterfaceId' \
                --output text 2>/dev/null || true)
            ENIS="$ENIS $VPC_ENIS"
        done
    fi
    
    # Also try the description filter as fallback
    DESC_ENIS=$(aws ec2 describe-network-interfaces \
        --region $REGION \
        --filters "Name=description,Values=*pod${POD_NUMBER}*" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || true)
    ENIS="$ENIS $DESC_ENIS"
    
    # Remove duplicates and whitespace
    ENIS=$(echo $ENIS | tr ' ' '\n' | sort -u | tr '\n' ' ')
    
    if [ -n "$ENIS" ]; then
        echo "   Found $(echo $ENIS | wc -w | tr -d ' ') network interface(s)"
        for ENI in $ENIS; do
            echo "   Checking ENI: $ENI"
            
            # Get ENI details
            ENI_STATUS=$(aws ec2 describe-network-interfaces \
                --region $REGION \
                --network-interface-ids $ENI \
                --query 'NetworkInterfaces[0].Status' \
                --output text 2>/dev/null || echo "unknown")
            
            ENI_DESC=$(aws ec2 describe-network-interfaces \
                --region $REGION \
                --network-interface-ids $ENI \
                --query 'NetworkInterfaces[0].Description' \
                --output text 2>/dev/null || echo "")
            
            echo "     Status: $ENI_STATUS, Description: $ENI_DESC"
            
            # Check if ENI is attached
            ATTACHMENT=$(aws ec2 describe-network-interfaces \
                --region $REGION \
                --network-interface-ids $ENI \
                --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
                --output text 2>/dev/null || echo "")
            
            # If attached, detach it first
            if [ -n "$ATTACHMENT" ] && [ "$ATTACHMENT" != "None" ]; then
                echo "     Detaching ENI: $ENI (attachment: $ATTACHMENT)"
                aws ec2 detach-network-interface --region $REGION --attachment-id $ATTACHMENT --force 2>/dev/null || true
                sleep 5
            fi
            
            # Delete the ENI
            echo "     Deleting ENI: $ENI"
            aws ec2 delete-network-interface --region $REGION --network-interface-id $ENI 2>/dev/null || \
                echo "     Failed to delete $ENI (may still be in use)"
        done
        
        # Wait for ENIs to be fully deleted
        echo "   Waiting for ENIs to be deleted..."
        sleep 15
    else
        echo "   No network interfaces found for pod${POD_NUMBER}"
        echo "   (Checked by: security groups, VPCs, and description)"
    fi
}

delete_security_groups() {
    echo "🛡️  Deleting Security Groups..."
    sleep 5  # Brief wait after ENI deletion
    
    # Find all security groups for this pod (including MCD-created ones)
    SGS=$(aws ec2 describe-security-groups \
        --region $REGION \
        --filters "Name=group-name,Values=pod${POD_NUMBER}-*" \
        --query 'SecurityGroups[].GroupId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$SGS" ]; then
        for SG in $SGS; do
            SG_NAME=$(aws ec2 describe-security-groups \
                --region $REGION \
                --group-ids $SG \
                --query 'SecurityGroups[0].GroupName' \
                --output text 2>/dev/null || echo "unknown")
            
            echo "   Deleting Security Group: $SG ($SG_NAME)"
            aws ec2 delete-security-group --region $REGION --group-id $SG 2>/dev/null || \
                echo "     Failed to delete $SG (may have dependencies, will retry)"
        done
        
        # Retry failed deletions after a wait
        echo "   Retrying failed security group deletions..."
        sleep 10
        for SG in $SGS; do
            aws ec2 delete-security-group --region $REGION --group-id $SG 2>/dev/null || true
        done
    else
        echo "   No security groups found for pod${POD_NUMBER}"
    fi
}

delete_vpcs() {
    echo "🏢 Deleting VPCs and dependencies..."
    
    # IMPORTANT: Wait longer for load balancers and network interfaces to fully release
    echo "   Waiting 30 seconds for load balancer network interfaces to be fully released..."
    sleep 30
    
    # Get ALL VPCs for this pod (including MCD-created ones)
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-vpc,pod${POD_NUMBER}-app2-vpc,pod${POD_NUMBER}-svpc-aws,pod${POD_NUMBER}-mgmt-vpc" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null || true)
    
    if [ -z "$VPCS" ]; then
        echo "   No VPCs found for pod${POD_NUMBER}"
        return
    fi
    
    echo "   Found $(echo $VPCS | wc -w | tr -d ' ') VPC(s) to clean up"
    
    for VPC in $VPCS; do
        VPC_NAME=$(aws ec2 describe-vpcs \
            --region $REGION \
            --vpc-ids $VPC \
            --query 'Vpcs[0].Tags[?Key==`Name`].Value' \
            --output text 2>/dev/null || echo "unknown")
        
        echo "   Processing VPC: $VPC ($VPC_NAME)"
        
        # Delete IGWs first
        IGWS=$(aws ec2 describe-internet-gateways \
            --region $REGION \
            --filters "Name=attachment.vpc-id,Values=$VPC" \
            --query 'InternetGateways[].InternetGatewayId' \
            --output text 2>/dev/null || true)
        
        for IGW in $IGWS; do
            echo "     Detaching and deleting IGW: $IGW"
            aws ec2 detach-internet-gateway --region $REGION --internet-gateway-id $IGW --vpc-id $VPC 2>/dev/null || true
            sleep 2
            aws ec2 delete-internet-gateway --region $REGION --internet-gateway-id $IGW 2>/dev/null || true
        done
        
        # Delete NAT Gateways if any remain
        NATS=$(aws ec2 describe-nat-gateways \
            --region $REGION \
            --filter "Name=vpc-id,Values=$VPC" \
            --query 'NatGateways[?State==`available`].NatGatewayId' \
            --output text 2>/dev/null || true)
        
        for NAT in $NATS; do
            echo "     Deleting NAT Gateway: $NAT"
            aws ec2 delete-nat-gateway --region $REGION --nat-gateway-id $NAT 2>/dev/null || true
        done
        
        # Delete Subnets
        SUBNETS=$(aws ec2 describe-subnets \
            --region $REGION \
            --filters "Name=vpc-id,Values=$VPC" \
            --query 'Subnets[].SubnetId' \
            --output text 2>/dev/null || true)
        
        for SUBNET in $SUBNETS; do
            echo "     Deleting Subnet: $SUBNET"
            aws ec2 delete-subnet --region $REGION --subnet-id $SUBNET 2>/dev/null || true
        done
        
        # Delete Route Tables (except main)
        RTS=$(aws ec2 describe-route-tables \
            --region $REGION \
            --filters "Name=vpc-id,Values=$VPC" \
            --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
            --output text 2>/dev/null || true)
        
        for RT in $RTS; do
            echo "     Deleting Route Table: $RT"
            aws ec2 delete-route-table --region $REGION --route-table-id $RT 2>/dev/null || true
        done
        
        # Delete any remaining Security Groups (except default)
        VPC_SGS=$(aws ec2 describe-security-groups \
            --region $REGION \
            --filters "Name=vpc-id,Values=$VPC" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null || true)
        
        for SG in $VPC_SGS; do
            echo "     Deleting Security Group: $SG"
            aws ec2 delete-security-group --region $REGION --group-id $SG 2>/dev/null || true
        done
        
        # Finally, delete VPC
        echo "     Deleting VPC: $VPC"
        aws ec2 delete-vpc --region $REGION --vpc-id $VPC 2>/dev/null || \
            echo "     Failed to delete VPC (may have dependencies)"
    done
    
    # Retry VPC deletion after waiting for dependencies
    echo "   Retrying VPC deletions..."
    sleep 10
    for VPC in $VPCS; do
        aws ec2 delete-vpc --region $REGION --vpc-id $VPC 2>/dev/null || true
    done
}

# Execute cleanup in order
delete_instances
delete_key_pairs
delete_load_balancers      # Delete MCD load balancers first
delete_tgw_attachments     # Delete TGW attachments before trying to delete VPCs
delete_vpc_endpoints       # Delete VPC Endpoints before ENIs
delete_network_interfaces  # Delete ENIs before EIPs (ENIs may have EIPs attached)
delete_eips
delete_nat_gateways
delete_security_groups
delete_vpcs

# Clean up local files
echo ""
echo "🧹 Cleaning up local files..."
cd ..

rm -f "pod${POD_NUMBER}-private-key" 2>/dev/null || true
rm -f "pod${POD_NUMBER}-public-key" 2>/dev/null || true
rm -rf .terraform/ 2>/dev/null || true
rm -f .terraform.lock.hcl 2>/dev/null || true

# Clean up credentials
cleanup_credentials

echo ""
echo "✅ Force cleanup complete!"
echo ""
echo "Note: Some resources may still exist if they couldn't be deleted."
echo "Check the AWS Console to verify all resources are removed."
echo ""

