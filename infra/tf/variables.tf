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
  type        = string
  description = "OCI region"
}

variable "tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID"
}

variable "user_ocid" {
  type        = string
  description = "OCI user OCID"
}

variable "fingerprint" {
  type        = string
  description = "OCI fingerprint"
}

variable "private_key_path" {
  type        = string
  description = "OCI private key path"
}

variable "freeform_tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources for tracking and organization"
}
