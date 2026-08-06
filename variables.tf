variable "tenancy_ocid" {
	description = "OCID da tenancy OCI. Também usado como compartment_id (recursos ficam no compartimento raiz, igual ao script original)."
	type        = string
}

variable "user_ocid" {
	description = "OCID do usuário OCI usado para autenticação da API."
	type        = string
}

variable "fingerprint" {
	description = "Fingerprint da chave de API OCI do usuário."
	type        = string
}

variable "private_key_path" {
	description = "Caminho local (no runner) para o arquivo .pem da chave de API OCI."
	type        = string
}

variable "region" {
	description = "Região OCI onde os recursos serão criados."
	type        = string
	default     = "us-ashburn-1"
}
