# Ampere A1 (Always Free) - auto-provisionamento via GitHub Actions

Este repositório cria uma instância `VM.Standard.A1.Flex` (Ampere/ARM, always free)
na OCI. Como esse shape costuma retornar `Out of host capacity`, um workflow do
GitHub Actions roda `terraform apply` a cada 12 minutos até a criação dar certo,
e então se desativa sozinho.

## Arquitetura

- **`main.tf`**: instância, VCN, Subnet (pública), Internet Gateway e Route Table.
  Os recursos de rede têm `lifecycle { prevent_destroy = true }` e só são criados
  na primeira execução - as seguintes reaproveitam o mesmo state.
- **`backend.tf`**: state do Terraform guardado no OCI Object Storage (backend
  nativo `oci`, Terraform >= 1.12), para persistir entre execuções do workflow.
- **`keys.tf`**: gera um par de chaves SSH (`tls_private_key`), usado na
  instância e também salvo como Secret num OCI Vault (`DEFAULT`, chave
  `SOFTWARE`, sem custo relevante).
- **`.github/workflows/apply.yml`**: agenda (`cron: */12 * * * *`) o
  `terraform apply`. Quando o apply tem sucesso, o próprio job roda
  `gh workflow disable` para parar de tentar.

## Passo a passo de configuração (uma vez só)

### 1. Criar a chave de API OCI (autenticação do Terraform)
1. Console OCI → avatar (canto superior direito) → **My Profile**.
2. Menu lateral → **API Keys** → **Add API Key**.
3. **Generate API Key Pair** → baixe a chave privada (`.pem`).
4. Copie o bloco de configuração mostrado (`user`, `fingerprint`, `tenancy`, `region`).

### 2. Criar o bucket para o state do Terraform
1. Console → **Storage → Buckets**.
2. Anote o **namespace** (topo da página: "Bucket in namespace `<namespace>`").
3. **Create Bucket** → nome, ex. `terraform-state` → opções padrão → Create.

### 3. Criar o repositório no GitHub e enviar o código
```bash
git commit -m "Initial commit: infra Ampere A1 com retry e state remoto"
git remote add origin https://github.com/<seu-usuario>/<seu-repo>.git
git branch -M main
git push -u origin main
```

### 4. Ajustar permissões do workflow
Repositório → **Settings → Actions → General → Workflow permissions** →
marcar **"Read and write permissions"** → Save.
(Necessário para o job conseguir se auto-desativar depois do sucesso.)

### 5. Cadastrar os secrets
**Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Valor |
|---|---|
| `OCI_TENANCY_OCID` | OCID da tenancy |
| `OCI_USER_OCID` | OCID do usuário (passo 1) |
| `OCI_FINGERPRINT` | fingerprint da API key (passo 1) |
| `OCI_PRIVATE_KEY` | conteúdo completo do `.pem` do passo 1, incluindo `-----BEGIN PRIVATE KEY-----`/`-----END PRIVATE KEY-----` |
| `OCI_REGION` | ex: `us-ashburn-1` |
| `OCI_NAMESPACE` | namespace do passo 2 |
| `TF_STATE_BUCKET` | nome do bucket do passo 2 |

`GITHUB_TOKEN` é automático, não precisa criar.

### 6. Testar manualmente
Aba **Actions** → workflow **"Ampere A1 auto-provision"** → **Run workflow**.
- Falhou com `Out of host capacity`: normal, é o que o schedule vai ficar
  tentando resolver.
- Falhou com erro de autenticação/backend: revise os secrets do passo 5.
- Sucesso: a instância foi criada e o workflow se desativa sozinho.

### 7. Depois que a instância for criada
- **IP público**: `terraform output instance_public_ip` (rodando localmente
  com os mesmos secrets como variáveis de ambiente) ou no Console da instância.
- **Chave SSH privada**: Console → **Identity & Security → Vault** →
  `vault-ampere-a1-ssh-keys` → **Secrets** → `ampere-a1-ssh-private-key` →
  **View Secret Contents** (vem em Base64). Via CLI:
  ```bash
  oci secrets secret-bundle get --secret-id <OCID_DO_SECRET> \
    --query 'data."secret-bundle-content".content' --raw-output | base64 -d > id_rsa
  chmod 600 id_rsa
  ssh -i id_rsa ubuntu@<IP_PUBLICO>
  ```

## Como reativar o workflow (se a instância for terminada e você quiser recriar)

O `gh workflow disable` só pausa os gatilhos (`schedule` e `workflow_dispatch`);
o arquivo do workflow continua no repositório. Para reativar:

**Pela interface do GitHub:**
1. Aba **Actions** do repositório.
2. Na lista à esquerda, clique em **"Ampere A1 auto-provision"** (vai aparecer
   marcado como *Disabled* / esmaecido).
3. Clique em **"Enable workflow"** no aviso que aparece no topo da página.

**Pela CLI (`gh`):**
```bash
gh workflow enable apply.yml
```

Depois de reativado, o schedule volta a rodar a cada 12 minutos normalmente
(ou dispare manualmente com `gh workflow run apply.yml` / botão **Run workflow**
na interface) até criar a instância de novo - e ele vai se desativar sozinho
outra vez quando conseguir.
