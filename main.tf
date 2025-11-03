resource "ciscomcd_address_object" "app1-egress-addr-object" {
  name        = "pod${var.pod_number}-app1-egress"
  description = "Address Object for app1 egress"
  type        = "DYNAMIC_USER_DEFINED_TAG"
  tag_list {
    tag_key       = "role"
    tag_value     = "pod${var.pod_number}-prod"
    resource_type = "RESOURCE_INSTANCE"
  }
}

resource "ciscomcd_address_object" "app2-egress-addr-object" {
  name        = "pod${var.pod_number}-app2-egress"
  description = "Address Object for app2 egress"
  type        = "DYNAMIC_USER_DEFINED_TAG"
  tag_list {
    tag_key       = "role"
    tag_value     = "pod${var.pod_number}-shared"
    resource_type = "RESOURCE_INSTANCE"
  }
}

resource "ciscomcd_address_object" "app1-ingress-addr-object" {
  name            = "pod${var.pod_number}-app1-ingress"
  description     = "Address Object for App1"
  type            = "STATIC"
  value           = ["10.${var.pod_number}.100.10"]
  backend_address = true
}

resource "ciscomcd_address_object" "app2-ingress-addr-object" {
  name            = "pod${var.pod_number}-app2-ingress"
  description     = "Address Object for App2"
  type            = "STATIC"
  value           = ["10.${100 + var.pod_number}.100.10"]
  backend_address = true
}

resource "ciscomcd_service_object" "app1_svc_http" {
  name           = "pod${var.pod_number}-app1"
  description    = "App1 Service Object - Port 80"
  service_type   = "ReverseProxy"
  protocol       = "TCP"
  transport_mode = "HTTP"
  source_nat     = false
  port {
    destination_ports = "80"
    backend_ports     = "80"
  }
  backend_address_group = ciscomcd_address_object.app1-ingress-addr-object.id
}

resource "ciscomcd_service_object" "app2_svc_http" {
  name           = "pod${var.pod_number}-app2"
  description    = "App2 Service Object - Port 8080"
  service_type   = "ReverseProxy"
  protocol       = "TCP"
  transport_mode = "HTTP"
  source_nat     = false
  port {
    destination_ports = "8080"
    backend_ports     = "80"  # App2 listens on port 80, but ingress is on 8080
  }
  backend_address_group = ciscomcd_address_object.app2-ingress-addr-object.id
}

resource "ciscomcd_profile_dlp" "block-ssn-dlp" {
  name        = "pod${var.pod_number}-block-ssn"
  description = "DLP Profile"
  dlp_filter_list {
    static_patterns = ["US Social Security Number", "US Social Security Number Without Dashes"]
    count           = 1
    action          = "Deny Log"
  }
}

resource "ciscomcd_service_vpc" "svpc-aws" {
  name               = "pod${var.pod_number}-svpc-aws"
  csp_account_name   = "bayuan"
  region             = "us-east-1"
  cidr               = "192.168.${var.pod_number}.0/24"
  availability_zones = ["us-east-1a"]
  use_nat_gateway    = false
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw.id
  
  # CRITICAL: Protect shared TGW from accidental modifications
  # The TGW is shared across all 50 pods and must never be changed
  lifecycle {
    ignore_changes = [transit_gateway_id]
  }
}

resource "ciscomcd_policy_rule_set" "egress_policy" {
  name = "pod${var.pod_number}-egress-policy"
}

resource "ciscomcd_policy_rules" "egress-ew-policy-rules" {
  rule_set_id = ciscomcd_policy_rule_set.egress_policy.id
  rule {
    name                      = "egress-internet-with-dlp"
    description               = "Egress to internet with IPS and DLP inspection"
    action                    = "Allow Log"
    state                     = "ENABLED"
    service                   = data.ciscomcd_service_object.sample-egress-forward-snat-tcp.id
    source                    = ciscomcd_address_object.app1-egress-addr-object.id
    destination               = data.ciscomcd_address_object.internet_addr_obj.id
    type                      = "Forwarding"
    network_intrusion_profile = data.ciscomcd_profile_network_intrusion.ciscomcd-sample-ips-balanced-alert.id
    dlp_profile               = ciscomcd_profile_dlp.block-ssn-dlp.id
  }
  rule {
    name                      = "egress-app2-internet-with-dlp"
    description               = "App2 egress to internet with IPS and DLP inspection"
    action                    = "Allow Log"
    state                     = "ENABLED"
    service                   = data.ciscomcd_service_object.sample-egress-forward-snat-tcp.id
    source                    = ciscomcd_address_object.app2-egress-addr-object.id
    destination               = data.ciscomcd_address_object.internet_addr_obj.id
    type                      = "Forwarding"
    network_intrusion_profile = data.ciscomcd_profile_network_intrusion.ciscomcd-sample-ips-balanced-alert.id
    dlp_profile               = ciscomcd_profile_dlp.block-ssn-dlp.id
  }
  rule {
    name        = "east-west-app1-app2"
    description = "Allow traffic between App1 and App2"
    action      = "Allow Log"
    state       = "ENABLED"
    service     = data.ciscomcd_service_object.sample-egress-forward-tcp.id
    source      = ciscomcd_address_object.app1-egress-addr-object.id
    destination = ciscomcd_address_object.app2-egress-addr-object.id
    type        = "Forwarding"
  }
}

resource "ciscomcd_policy_rule_set" "ingress_policy" {
  name = "pod${var.pod_number}-ingress-policy"
}

resource "ciscomcd_policy_rules" "ingress-policy-rules" {
  rule_set_id = ciscomcd_policy_rule_set.ingress_policy.id
  rule {
    name                      = "app1-http"
    description               = "App1 HTTP on port 80"
    type                      = "ReverseProxy"
    action                    = "Allow Log"
    service                   = ciscomcd_service_object.app1_svc_http.id
    source                    = data.ciscomcd_address_object.any_addr_obj.id
    network_intrusion_profile = data.ciscomcd_profile_network_intrusion.ciscomcd-sample-ips-balanced-alert.id
    state                     = "ENABLED"
  }
  rule {
    name                      = "app2-http"
    description               = "App2 HTTP on port 8080"
    type                      = "ReverseProxy"
    action                    = "Allow Log"
    service                   = ciscomcd_service_object.app2_svc_http.id
    source                    = data.ciscomcd_address_object.any_addr_obj.id
    network_intrusion_profile = data.ciscomcd_profile_network_intrusion.ciscomcd-sample-ips-balanced-alert.id
    state                     = "ENABLED"
  }
}

resource "ciscomcd_gateway" "aws-egress-gw" {
  name                  = "pod${var.pod_number}-egress-gw-aws"
  csp_account_name      = "bayuan"
  instance_type         = "AWS_M5_LARGE"
  mode                  = "HUB"
  gateway_state         = "ACTIVE"
  policy_rule_set_id    = ciscomcd_policy_rule_set.egress_policy.id
  min_instances         = 1
  max_instances         = 1
  health_check_port     = 65534
  region                = "us-east-1"
  vpc_id                = ciscomcd_service_vpc.svpc-aws.id
  aws_iam_role_firewall = "arn:aws:iam::698990355236:role/ciscomcd-gateway-role"
  gateway_image         = "24.06-07"
  ssh_key_pair          = "pod${var.pod_number}-keypair"
  security_type         = "EGRESS"
}

resource "ciscomcd_gateway" "aws-ingress-gw" {
  name                  = "pod${var.pod_number}-ingress-gw-aws"
  csp_account_name      = "bayuan"
  instance_type         = "AWS_M5_LARGE"
  mode                  = "HUB"
  gateway_state         = "ACTIVE"
  policy_rule_set_id    = ciscomcd_policy_rule_set.ingress_policy.id
  min_instances         = 1
  max_instances         = 1
  health_check_port     = 65534
  region                = "us-east-1"
  vpc_id                = ciscomcd_service_vpc.svpc-aws.id
  aws_iam_role_firewall = "arn:aws:iam::698990355236:role/ciscomcd-gateway-role"
  gateway_image         = "24.06-07"
  ssh_key_pair          = "pod${var.pod_number}-keypair"
  security_type         = "INGRESS"
}
