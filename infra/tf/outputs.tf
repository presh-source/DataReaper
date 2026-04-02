output "instance_public_ip" {
  description = "Public IP of the compute instance"
  value       = oci_core_instance.compute_instance.public_ip
}

output "instance_private_ip" {
  description = "Private IP of the compute instance"
  value       = oci_core_instance.compute_instance.private_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i <path-to-private-key> ubuntu@${oci_core_instance.compute_instance.public_ip}"
}
