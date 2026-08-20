# Gera o par de chaves SSH usado para acessar a instância (substitui a chave
# fixa que vinha hardcoded no console). Como o state é persistido (backend.tf),
# essa chave só é gerada UMA vez; execuções seguintes reusam a mesma.
resource "tls_private_key" "ssh_key" {
	algorithm = "RSA"
	rsa_bits  = 2048
}

# Cópia local, útil quando o terraform é aplicado manualmente numa máquina.
# Atenção: se aplicado via GitHub Actions, o runner é efêmero e este arquivo
# não sobrevive entre execuções - a cópia durável é o OCI Vault abaixo.
resource "local_sensitive_file" "ssh_private_key" {
	filename        = "${path.module}/generated/oci_a1.key"
	content         = tls_private_key.ssh_key.private_key_openssh
	file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
	filename = "${path.module}/generated/oci_a1.key.pub"
	content  = tls_private_key.ssh_key.public_key_openssh
}

# Vault "DEFAULT" com chave "SOFTWARE": sem custo relevante (chaves
# software-protected são gratuitas; evite vault_type = VIRTUAL_PRIVATE, que é caro).
resource "oci_kms_vault" "ssh_key_vault" {
	compartment_id = var.tenancy_ocid
	display_name   = "vault-ampere-a1-ssh-keys"
	vault_type     = "DEFAULT"
}

resource "oci_kms_key" "ssh_key_wrapping_key" {
	compartment_id      = var.tenancy_ocid
	display_name        = "key-ampere-a1-ssh-keys"
	management_endpoint = oci_kms_vault.ssh_key_vault.management_endpoint
	protection_mode      = "SOFTWARE"
	key_shape {
		algorithm = "AES"
		length    = 32
	}
}

resource "oci_vault_secret" "ssh_private_key_secret" {
	compartment_id = var.tenancy_ocid
	vault_id       = oci_kms_vault.ssh_key_vault.id
	key_id         = oci_kms_key.ssh_key_wrapping_key.id
	secret_name    = "ampere-a1-ssh-private-key"
	description    = "Chave privada SSH gerada pelo Terraform para acesso a instancia Ampere A1"
	secret_content {
		content_type = "BASE64"
		content      = base64encode(tls_private_key.ssh_key.private_key_openssh)
	}
}

resource "oci_vault_secret" "ssh_public_key_secret" {
	compartment_id = var.tenancy_ocid
	vault_id       = oci_kms_vault.ssh_key_vault.id
	key_id         = oci_kms_key.ssh_key_wrapping_key.id
	secret_name    = "ampere-a1-ssh-public-key"
	description    = "Chave publica SSH gerada pelo Terraform para acesso a instancia Ampere A1"
	secret_content {
		content_type = "BASE64"
		content      = base64encode(tls_private_key.ssh_key.public_key_openssh)
	}
}
