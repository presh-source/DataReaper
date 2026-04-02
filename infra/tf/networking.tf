# Virtual Cloud Network — The private network that contains all resources
resource "oci_core_vcn" "internal" {
  compartment_id = var.compartment_id
  display_name   = "${var.project_name}-vcn"
  dns_label      = "internal"
  cidr_block     = "10.10.0.0/20"
  freeform_tags  = var.freeform_tags
}

# Internet Gateway — Allows traffic between the VCN and the public internet
resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  display_name   = "${var.project_name}-igw"
  freeform_tags  = var.freeform_tags
  vcn_id         = oci_core_vcn.internal.id
  enabled        = true
}

# Route Table — Directs all outbound traffic (0.0.0.0/0) through the Internet Gateway
resource "oci_core_route_table" "public_route_table" {
  compartment_id = var.compartment_id
  display_name   = "${var.project_name}-public-route-table"
  freeform_tags  = var.freeform_tags
  vcn_id         = oci_core_vcn.internal.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Public Subnet — A 256-IP slice of the VCN where internet-facing resources live
resource "oci_core_subnet" "public_subnet" {
  compartment_id    = var.compartment_id
  display_name      = "${var.project_name}-public-subnet"
  freeform_tags     = var.freeform_tags
  vcn_id            = oci_core_vcn.internal.id
  cidr_block        = "10.10.0.0/24"
  route_table_id    = oci_core_route_table.public_route_table.id
  security_list_ids = [oci_core_security_list.public_security_list.id]
  dns_label         = "public"
}

# Security List — Firewall rules controlling inbound/outbound traffic for the public subnet
resource "oci_core_security_list" "public_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "${var.project_name}-public-security-list"
  freeform_tags  = var.freeform_tags

  # SSH
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Airflow Web UI
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # MongoDB
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 27017
      max = 27017
    }
  }

  # MinIO API + Console
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 9000
      max = 9001
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}
