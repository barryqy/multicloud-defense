# ════════════════════════════════════════════════════════════
# Main Terraform Configuration - AWS Resources Only
# ════════════════════════════════════════════════════════════
# This file contains AWS infrastructure resources.
#
# MCD (Cisco Multicloud Defense) resources are in: mcd-resources.tf.disabled
# That file is activated by Step 3 (3-secure.sh) during deployment.
# ════════════════════════════════════════════════════════════

# Get current AWS account ID dynamically
data "aws_caller_identity" "current" {}

# IAM role ARN for gateways (dynamic account ID)
# This is used by mcd-resources.tf when it's activated
locals {
  gateway_iam_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ciscomcd-gateway-role"
}
