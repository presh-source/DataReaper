# Terraform Configuration — Declares required OCI provider
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

# OCI Provider — Authenticates dynamically 
provider "oci" {
  region              = var.region
  auth                = var.oci_auth_method
  config_file_profile = var.oci_auth_profile
  
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}