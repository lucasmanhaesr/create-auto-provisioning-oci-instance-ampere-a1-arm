# Backend nativo "oci" (Terraform >= 1.12) para persistir o state entre execuções.
# Configuração parcial de propósito: bucket/namespace/region/credenciais são
# passados em tempo de "terraform init" via -backend-config, vindos de secrets
# do GitHub Actions. Isso evita commitar segredos ou nomes específicos da tenancy.
#
# É essa persistência de state que garante que a VCN, o Internet Gateway, a
# Route Table e a Subnet só sejam criados uma vez: a partir da 2a execução o
# Terraform vê que já existem no state e não recria nada, só tenta (de novo)
# criar a instância caso ela ainda não exista (ex: por falta de capacidade).
terraform {
	backend "oci" {}
}
