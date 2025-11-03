#!/bin/bash

# Export all deployment environment variables
export_deployment_vars() {
    export POD_NUMBER="${POD_NUMBER:-$(grep 'pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')}"
    export APP1_PUBLIC_IP=$(terraform output -raw app1-public-eip 2>/dev/null || echo "N/A")
    export APP2_PUBLIC_IP=$(terraform output -raw app2-public-eip 2>/dev/null || echo "N/A")
    export APP1_PRIVATE_IP=$(terraform output -raw app1-private-ip 2>/dev/null || echo "N/A")
    export APP2_PRIVATE_IP=$(terraform output -raw app2-private-ip 2>/dev/null || echo "N/A")
    export JUMPBOX_PUBLIC_IP=$(terraform output -raw jumpbox_public_ip 2>/dev/null || echo "N/A")
    export INGRESS_GATEWAY_PUBLIC_IP=$(aws ec2 describe-instances --region us-east-1 \
        --filters "Name=tag:Name,Values=*pod${POD_NUMBER}*ingress*" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null || echo "N/A")
    export APP1_PUBLIC_URL="http://${INGRESS_GATEWAY_PUBLIC_IP}"
    export SSH_KEY="pod${POD_NUMBER}-private-key"
}

# Display all environment variables
show_deployment_vars() {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════════════════"
    echo "🔧 Environment Variables Exported"
    echo "════════════════════════════════════════════════════════════════════════════════════════════════"
    echo "  POD_NUMBER=$POD_NUMBER"
    echo "  APP1_PUBLIC_IP=$APP1_PUBLIC_IP"
    echo "  APP2_PUBLIC_IP=$APP2_PUBLIC_IP"
    echo "  APP1_PRIVATE_IP=$APP1_PRIVATE_IP"
    echo "  APP2_PRIVATE_IP=$APP2_PRIVATE_IP"
    echo "  JUMPBOX_PUBLIC_IP=$JUMPBOX_PUBLIC_IP"
    echo "  INGRESS_GATEWAY_PUBLIC_IP=$INGRESS_GATEWAY_PUBLIC_IP"
    echo "  APP1_PUBLIC_URL=$APP1_PUBLIC_URL"
    echo "  SSH_KEY=$SSH_KEY"
    echo ""
    echo "Access Methods:"
    echo "  SSH to Jumpbox:  ssh -i \$SSH_KEY ubuntu@\$JUMPBOX_PUBLIC_IP"
    echo "  HTTP to App1:    curl \$APP1_PUBLIC_URL"
    echo "  (or open \$APP1_PUBLIC_URL in your browser)"
    echo ""
}

