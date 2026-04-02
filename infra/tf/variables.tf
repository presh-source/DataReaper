variable "availability_domain" {
  type        = string
  description = "OCI availability domain where resources will be deployed"
}

variable "compartment_id" {
  type        = string
  description = "OCID of the compartment to create resources in"
}

variable "project_name" {
  type        = string
  description = "Project name used as prefix for all resource display names"
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key for remote access to the compute instance"
}

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "oci_auth_method" {
  type    = string
  default = "SecurityToken"
}

variable "oci_auth_profile" {
  type    = string
  default = "Default"
}

variable "tenancy_ocid" {
  type    = string
  default = ""
}

variable "user_ocid" {
  type    = string
  default = ""
}

variable "fingerprint" {
  type    = string
  default = ""
}

variable "private_key_path" {
  type    = string
  default = ""
}

variable "freeform_tags" {
  type        = map(string)
  description = "Tags applied to all resources for tracking and organization"
}
