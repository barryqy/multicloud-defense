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
read -p "👉 Enter your student pod number (1-50): " POD_NUMBER
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

if [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt 50 ]; then
    echo "❌ Pod number must be between 1 and 50"
    exit 1
fi

echo "✓ Pod number validated: $POD_NUMBER"
echo ""

export LAB_PASSWORD

# Source shared credentials helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.credentials-helper.sh"

echo "🔄 Fetching credentials from key-service..."

# Fetch credentials using the helper
if ! fetch_lab_credentials; then
    echo "❌ Failed to fetch credentials"
    echo "   Please check your password and internet connection"
    exit 1
fi

echo "✓ Credentials retrieved successfully"
echo ""

if [ -z "$MCD_API_KEY_JSON" ]; then
    echo "❌ Failed to parse MCD credentials"
    exit 1
fi

echo "✓ MCD API credentials ready"
echo "✓ MCD credentials retrieved"
echo ""

# Create .terraform directory if it doesn't exist
mkdir -p .terraform
chmod 700 .terraform

# Write credential files for Terraform
echo "📝 Writing credential files..."

AWS_ACCESS_FILE=".terraform/.aws-access.key"
AWS_CRED_FILE=".terraform/.aws-secret.key"
MCD_CRED_FILE=".terraform/.mcd-api.json"

printf '%s' "$AWS_ACCESS_KEY" > "$AWS_ACCESS_FILE"
printf '%s' "$AWS_SECRET" > "$AWS_CRED_FILE"

printf '%s' "$MCD_API_KEY_JSON" | python3 -c '
import base64
import json
import sys

try:
    mcd_data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

full_json_str = json.dumps(mcd_data)
encoded = base64.b64encode(full_json_str.encode()).decode()
print(encoded, end="")
' > "$MCD_CRED_FILE"

if [ $? -ne 0 ] || [ ! -s "$MCD_CRED_FILE" ]; then
    echo "❌ Failed to process MCD credentials"
    exit 1
fi

chmod 600 "$AWS_ACCESS_FILE"
chmod 600 "$AWS_CRED_FILE"
chmod 600 "$MCD_CRED_FILE"

echo "✓ Credential files created"
echo "  - $AWS_ACCESS_FILE"
echo "  - $AWS_CRED_FILE"
echo "  - $MCD_CRED_FILE"
echo ""

# Update terraform.tfvars with pod number
echo "📝 Updating terraform.tfvars with pod number..."
cat > terraform.tfvars << EOF
region         = "us-east-1"
pod_number     = $POD_NUMBER

# pod_number is now pre-configured - no need to enter it again during terraform plan/apply
# AWS credentials are fetched from key-service into .terraform/
EOF

echo "✓ Pod number saved to terraform.tfvars"
echo ""

# Export environment variables for Terraform
echo "🔒 Exporting credentials as environment variables..."
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
echo "💡 Your pod number ($POD_NUMBER) is now configured."
echo ""

# Clean up
cleanup_credentials
