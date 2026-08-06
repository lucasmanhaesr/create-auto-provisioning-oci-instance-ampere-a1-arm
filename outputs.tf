output "instance_public_ip" {
	description = "IP publico da instancia (para SSH)."
	value       = oci_core_instance.generated_oci_core_instance.public_ip
}

output "ssh_public_key_openssh" {
	description = "Chave publica SSH gerada."
	value       = tls_private_key.ssh_key.public_key_openssh
}

output "ssh_private_key_pem" {
	description = "Chave privada SSH gerada (tambem disponivel no OCI Vault)."
	value       = tls_private_key.ssh_key.private_key_openssh
	sensitive   = true
}

output "ssh_private_key_vault_secret_id" {
	description = "OCID do secret no Vault com a chave privada."
	value       = oci_vault_secret.ssh_private_key_secret.id
}

output "ssh_public_key_vault_secret_id" {
	description = "OCID do secret no Vault com a chave publica."
	value       = oci_vault_secret.ssh_public_key_secret.id
}
