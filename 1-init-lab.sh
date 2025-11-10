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

# Extract MCD credentials - NEW FORMAT: MCD_API_KEY contains complete JSON
MCD_API_KEY_JSON=$(echo "$API_RESPONSE" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('MCD_API_KEY',''))" 2>/dev/null)

if [ -n "$MCD_API_KEY_JSON" ]; then
    # New format: MCD_API_KEY contains complete JSON with all fields
    echo "✓ Using new MCD_API_KEY format (complete JSON)"
else
    echo "❌ Failed to parse MCD credentials"
    echo "   MCD_API_KEY field not found in response"
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

# Write AWS credentials
echo -n "$AWS_SECRET" > "$AWS_CRED_FILE"

# Write MCD credentials - store FULL JSON and base64 encode (like AWS)
# The ciscomcd Terraform provider needs ALL fields from the API key
echo "$API_RESPONSE" > /tmp/mcd_api_response.json

python3 << 'PYSCRIPT' > "$MCD_CRED_FILE"
import json, base64, sys

try:
    # Read API response
    with open('/tmp/mcd_api_response.json', 'r') as f:
        response = json.load(f)
    
    # Get MCD_API_KEY (it's a JSON string within the response)
    mcd_json_str = response.get('MCD_API_KEY', '')
    
    if not mcd_json_str:
        sys.exit(1)
    
    # Parse the MCD_API_KEY JSON - this contains ALL fields needed by the provider
    mcd_data = json.loads(mcd_json_str)
    
    # Store the FULL JSON (ciscomcd Terraform provider needs all fields)
    # This includes: apiKeyID, apiKeySecret, publicKey, privateKey,
    # apiServer, apiServerPort, restAPIServer, restAPIServerPort, etc.
    full_json_str = json.dumps(mcd_data)
    
    # Base64 encode for obfuscation (same as AWS credentials)
    encoded = base64.b64encode(full_json_str.encode()).decode()
    print(encoded, end='')
except Exception as e:
    sys.exit(1)
PYSCRIPT

if [ $? -ne 0 ] || [ ! -s "$MCD_CRED_FILE" ]; then
    echo "❌ Failed to process MCD credentials"
    rm -f /tmp/mcd_api_response.json
    exit 1
fi

rm -f /tmp/mcd_api_response.json

chmod 600 "$AWS_CRED_FILE"
chmod 600 "$MCD_CRED_FILE"

echo "✓ Credential files created (base64 encoded)"
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
# aws_secret_key is automatically fetched from the lab credential server

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
echo "💡 Your pod number ($POD_NUMBER) is now configured."
echo ""

# Clean up
cleanup_credentials

