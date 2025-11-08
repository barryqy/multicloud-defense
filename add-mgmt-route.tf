resource "aws_route" "mgmt_to_apps_via_tgw" {
  route_table_id         = "rtb-0dad4740f423d5ad7"
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = "tgw-0a878e2f5870e2ccf"
}
