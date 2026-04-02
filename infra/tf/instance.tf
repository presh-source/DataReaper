# Compute Instance — ARM-based Ubuntu server running Docker and Airflow pipelines
resource "oci_core_instance" "compute_instance" {
  compartment_id      = var.compartment_id
  display_name        = "${var.project_name}-instance"
  freeform_tags       = var.freeform_tags
  availability_domain = var.availability_domain
  shape               = "VM.Standard.A1.Flex"
  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = filebase64("${path.module}/../scripts/init.sh")
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public_subnet.id
    display_name     = "${var.project_name}-vnic"
    assign_public_ip = true
    hostname_label   = var.project_name
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_22_04.images[0].id
  }
}

# Image Lookup — Fetches the latest ARM-compatible Ubuntu 22.04 image from OCI
data "oci_core_images" "ubuntu_22_04" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Block Volume — 150 GB storage for Docker volumes, MongoDB data, and MinIO objects
resource "oci_core_volume" "data_volume" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = "${var.project_name}-data-volume"
  size_in_gbs         = 150
  freeform_tags       = var.freeform_tags
}

# Volume Attachment — Attaches the block volume to the compute instance
resource "oci_core_volume_attachment" "data_volume_attachment" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.compute_instance.id
  volume_id       = oci_core_volume.data_volume.id
  display_name    = "${var.project_name}-data-volume-attachment"
}
