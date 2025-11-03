data "ciscomcd_service_object" "sample-egress-forward-snat-tcp" {
  name = "sample-egress-forward-snat-tcp"
}

data "ciscomcd_service_object" "sample-egress-forward-tcp" {
  name = "sample-egress-forward-tcp"
}

data "ciscomcd_address_object" "internet_addr_obj" {
  name = "internet"
}

data "ciscomcd_address_object" "any_addr_obj" {
  name = "any"
}

data "ciscomcd_profile_network_intrusion" "ciscomcd-sample-ips-balanced-alert" {
  name = "ciscomcd-sample-ips-balanced-alert"
}

# Shared Transit Gateway for all pods (HARDCODED - NEVER CREATED)
# This is a static, shared resource that exists for all 50 pods
# ID: tgw-0a878e2f5870e2ccf
# This data source simply references the existing TGW - it will NEVER create a new one
data "aws_ec2_transit_gateway" "tgw" {
  id = "tgw-0a878e2f5870e2ccf"
}

# Commented out temporarily - requires secure.sh to create Service VPC first
# data "aws_security_group" "datapath-sg" {
#   filter {
#     name   = "group-name"
#     values = ["pod${var.pod_number}-svpc-aws-datapath-sg"]
#   }
#   depends_on = [ciscomcd_service_vpc.svpc-aws, ciscomcd_gateway.aws-egress-gw, ciscomcd_gateway.aws-ingress-gw]
# }

# resource "aws_security_group_rule" "datapath-rule" {
#   type              = "ingress"
#   from_port         = 0
#   to_port           = 65535
#   protocol          = "-1"
#   cidr_blocks       = ["68.154.48.186/32", "10.0.0.0/8", "83.97.13.0/24"]
#   security_group_id = data.aws_security_group.datapath-sg.id
# }
