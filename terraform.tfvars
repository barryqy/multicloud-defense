aws_access_key = "REMOVED_AWS_ACCESS_KEY"
region         = "us-east-1"
pod_number     = 50

# pod_number is now pre-configured - no need to enter it again during terraform plan/apply
# aws_secret_key is automatically fetched from the lab credential server

# Route configuration (set by attach-tgw.sh)
use_transit_gateway_for_routes = true
