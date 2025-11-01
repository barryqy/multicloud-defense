variable "aws_access_key" {
  type        = string
  description = "AWS Access Key"
  sensitive   = true
}

variable "pod_number" {
  type        = number
  description = "Student pod number (1-60) - automatically configured by init-lab.sh"
  
  validation {
    condition     = var.pod_number >= 1 && var.pod_number <= 60
    error_message = "Pod number must be between 1 and 60."
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
