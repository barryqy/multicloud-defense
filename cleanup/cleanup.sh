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
echo "🔍 Finding resources for pod $POD_NUMBER..."
echo ""

REGION="us-east-1"

# Function to delete resources
delete_instances() {
    echo "🗑️  Terminating EC2 instances..."
    INSTANCES=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1,pod${POD_NUMBER}-app2" \
                  "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || true)
    
    if [ -n "$INSTANCES" ]; then
        for INSTANCE in $INSTANCES; do
            echo "   Terminating instance: $INSTANCE"
            aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE 2>/dev/null || true
        done
        echo "   Waiting for instances to terminate..."
        sleep 30
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
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-eip,pod${POD_NUMBER}-app2-eip" \
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
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-app1-vpc,pod${POD_NUMBER}-app2-vpc" \
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
    sleep 15  # Wait for resources to be released
    
    # Get ALL VPCs for this pod (including MCD-created ones)
    VPCS=$(aws ec2 describe-vpcs \
        --region $REGION \
        --filters "Name=tag:Name,Values=pod${POD_NUMBER}-*" \
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

