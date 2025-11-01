terraform {
  required_providers {
    ciscomcd = {
      source = "CiscoDevNet/ciscomcd"
    }
    aws = {
      source = "hashicorp/aws"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

locals {
  _cred_dir = "${path.root}/.terraform"
  _aws_key_file = "${local._cred_dir}/.aws-secret.key"
  _mcd_api_file = abspath("${local._cred_dir}/.mcd-api.json")
  _mcd_json_content = fileexists(local._mcd_api_file) ? file(local._mcd_api_file) : ""
}

provider "ciscomcd" {
  api_key_file = file("${path.root}/.terraform/.mcd-api.json")
}

provider "aws" {
  region     = var.region
  access_key = var.aws_access_key
  secret_key = trimspace(file(local._aws_key_file))
}
