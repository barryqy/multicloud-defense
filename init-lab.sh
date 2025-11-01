#!/bin/bash

# Multicloud Defense Lab - Initialization Script
# This script sets up credentials for both Terraform and AWS CLI

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Multicloud Defense Lab - Credential Setup            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Prompt for lab password (only once!)
echo "════════════════════════════════════════════════════════════"
echo "🔐 🔐 🔐  PASSWORD REQUIRED  🔐 🔐 🔐"
echo "════════════════════════════════════════════════════════════"
echo ""
read -sp "👉 Enter lab password: " LAB_PASSWORD
echo ""
echo ""

if [ -z "$LAB_PASSWORD" ]; then
    echo "❌ Password cannot be empty"
    exit 1
fi

# Prompt for student pod number
echo "════════════════════════════════════════════════════════════"
echo "📋 📋 📋  STUDENT POD NUMBER  📋 📋 📋"
echo "════════════════════════════════════════════════════════════"
echo ""
read -p "👉 Enter your student pod number (1-60): " POD_NUMBER
echo ""

# Validate pod number
if [ -z "$POD_NUMBER" ]; then
    echo "❌ Pod number cannot be empty"
    exit 1
fi

if ! [[ "$POD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "❌ Pod number must be a number"
    exit 1
fi

if [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 60 ]; then
    echo "❌ Pod number must be between 1 and 60"
    exit 1
fi

echo "✓ Pod number validated: $POD_NUMBER"
echo ""

export LAB_PASSWORD

# Source shared credentials helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.credentials-helper.sh"

echo "🔄 Fetching credentials from secure source..."

# Fetch credentials using the helper
if ! _c2; then
    echo "❌ Failed to fetch credentials"
    echo "   Please check your password and internet connection"
    exit 1
fi

echo "✓ Credentials retrieved successfully"
echo ""

# Fetch MCD credentials
echo "🔄 Fetching MCD API credentials..."
_a="YUhSMGNITTZMeTlyY3k1aVlYSnllWE5sWTNWeVpTNWpiMjB2WTNKbFpHVnVkR2xoYkhNPQo="
_b=$(echo "$_a"|base64 -d)
_u=$(echo "$_b"|base64 -d)
_h1="WC1MYWItSUQ="
_h2="WC1TZXNzaW9uLVBhc3N3b3Jk"
_v1="bWNk"

API_RESPONSE=$(curl -s "$_u" -H "$(echo "$_h1"|base64 -d): $(echo "$_v1"|base64 -d)" -H "$(echo "$_h2"|base64 -d): $LAB_PASSWORD" 2>/dev/null)

if [ -z "$API_RESPONSE" ]; then
    echo "❌ Failed to fetch MCD credentials"
    exit 1
fi

# Extract credentials using Python
MCD_CREDS=$(echo "$API_RESPONSE" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('API_KEY_FILE',''))" 2>/dev/null)

if [ -z "$MCD_CREDS" ]; then
    echo "❌ Failed to parse MCD credentials"
    exit 1
fi

echo "✓ MCD credentials retrieved"
echo ""

# Create .terraform directory if it doesn't exist
mkdir -p .terraform
chmod 700 .terraform

# Write credential files for Terraform
echo "📝 Writing credential files..."

AWS_CRED_FILE=".terraform/.aws-secret.key"
MCD_CRED_FILE=".terraform/.mcd-api.json"

echo -n "$AWS_SECRET" > "$AWS_CRED_FILE"
echo -n "$MCD_CREDS" > "$MCD_CRED_FILE"

chmod 600 "$AWS_CRED_FILE"
chmod 600 "$MCD_CRED_FILE"

echo "✓ Credential files created"
echo "  - $AWS_CRED_FILE"
echo "  - $MCD_CRED_FILE"
echo ""

# Update terraform.tfvars with pod number
echo "📝 Updating terraform.tfvars with pod number..."
cat > terraform.tfvars << EOF
aws_access_key = "AKIAQNABJV7JQE5BB3XS"
region         = "us-east-1"
pod_number     = $POD_NUMBER

# pod_number is now pre-configured - no need to enter it again during terraform plan/apply
# aws_secret_key is automatically fetched from https://pastebin.com/raw/er9293Dh

EOF

echo "✓ Pod number saved to terraform.tfvars"
echo ""

# Export environment variables for Terraform
echo "🔒 Exporting credentials as environment variables..."
AWS_ACCESS_KEY="AKIAQNABJV7JQE5BB3XS"
export TF_VAR_aws_access_key="$AWS_ACCESS_KEY"
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"

echo "✓ Environment variables configured"
echo ""

# Configure AWS CLI if installed
if command -v aws &> /dev/null; then
    echo "🔧 Configuring AWS CLI..."
    
    mkdir -p ~/.aws
    chmod 700 ~/.aws
    
    cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
    
    cat > ~/.aws/config << EOF
[default]
region = us-east-1
output = json
EOF
    
    chmod 600 ~/.aws/credentials
    chmod 600 ~/.aws/config
    
    echo "✓ AWS CLI configured"
else
    echo "ℹ️  AWS CLI not installed (optional)"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Lab initialization complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "You can now deploy your lab environment:"
echo ""
echo "  🚀 Quick Deploy (Recommended):"
echo "     ./deploy.sh"
echo ""
echo "  Or manually with Terraform:"
echo "     terraform init"
echo "     terraform plan"
echo "     terraform apply"
echo ""
echo "💡 Your pod number ($POD_NUMBER) is now configured."
echo "💡 You won't be prompted for password or pod number again!"
echo "💡 The deploy.sh script handles re-deployments automatically!"
echo ""

# Clean up
cleanup_credentials

