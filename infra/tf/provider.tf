# Terraform Configuration — Declares required OCI provider
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }

  backend "oci" {

  }
}

# OCI Provider — Authenticates dynamically 
provider "oci" {
  auth                = "config_file"
  config_file_profile = "DEFAULT"
  region              = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}