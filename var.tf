variable "aws_access_key" {
  type        = string
  description = "AWS Access Key"
  sensitive   = true
}

variable "pod_number" {
  type        = number
  description = "Student pod number (1-50) - automatically configured by init-lab.sh"
  
  validation {
    condition     = var.pod_number >= 1 && var.pod_number <= 50
    error_message = "Pod number must be between 1 and 50."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "transit_gateway_name" {
  type        = string
  description = "Name for the Transit Gateway"
  default     = "mcd-transit-gateway"
}

variable "use_transit_gateway_for_routes" {
  type        = bool
  description = "If true, route traffic through Transit Gateway. If false, route through Internet Gateway."
  default     = false  # Start with IGW routing, changed to true by 5-attach-tgw.sh
}
