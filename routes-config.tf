# Route Configuration
# This file controls whether default routes point to IGW or TGW
# Modified by attach-tgw.sh to enable traffic inspection

resource "aws_route" "ext_default_route" {
  count                  = 2
  route_table_id         = aws_route_table.app-route[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  
  # Route through TGW if attach-tgw.sh has been run, otherwise through IGW
  gateway_id         = var.use_transit_gateway_for_routes ? null : aws_internet_gateway.int_gw[count.index].id
  transit_gateway_id = var.use_transit_gateway_for_routes ? data.aws_ec2_transit_gateway.tgw.id : null
  
  # Only depend on TGW attachments if using TGW
  dynamic "timeouts" {
    for_each = var.use_transit_gateway_for_routes ? [1] : []
    content {
      create = "5m"
    }
  }
  
  depends_on = [
    aws_internet_gateway.int_gw,
    data.aws_ec2_transit_gateway.tgw
  ]
  
  lifecycle {
    create_before_destroy = true
  }
}

