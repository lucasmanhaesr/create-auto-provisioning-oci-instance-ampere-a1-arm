# Ampere A1 ARM (Always Free) - auto-provisionamento via GitHub Actions e gatilho via systemd timer - APENAS PARA FINS EDUCACIONAIS

Este repositório cria uma instância `VM.Standard.A1.Flex` (Ampere/ARM, always free)
na OCI. Como esse shape quase sempre retorna `Out of host capacity`, o
`terraform apply` é executado repetidamente (a cada ~12 minutos) até a criação
dar certo, e então o agendamento se desativa sozinho.

> **Por que não confiar só no `schedule` do GitHub?**
> O agendador de `cron` do GitHub Actions é *best-effort*: ele atrasa e
> **frequentemente descarta** execuções agendadas de intervalo curto (como
> `*/12`), ainda mais em repositórios novos/de baixa atividade. Na prática o
> `schedule` pode não disparar **nenhuma** vez. Por isso o gatilho de verdade
> é **externo**: um `systemd timer` rodando numa instância sempre-ligada chama
> o workflow via API do GitHub a cada 12 minutos (ver
> [Disparo confiável](#6-disparo-confiável-a-cada-12-min-systemd-timer)). O
> `schedule` continua no workflow apenas como reforço.

## Arquitetura

- **`main.tf`**: instância, VCN, Subnet (pública), Internet Gateway e Route Table.
  Os recursos de rede têm `lifecycle { prevent_destroy = true }` e só são criados
  na primeira execução - as seguintes reaproveitam o mesmo state.
- **`backend.tf`**: state do Terraform guardado no OCI Object Storage (backend
  nativo `oci`, Terraform >= 1.12), para persistir entre execuções do workflow.
- **`keys.tf`**: gera um par de chaves SSH (`tls_private_key`), usado na
  instância e também salvo como Secret num OCI Vault (`DEFAULT`, chave
  `SOFTWARE`, sem custo relevante).
- **`.github/workflows/apply.yml`**: roda `terraform init` + `terraform apply`.
  O passo do apply trata três desfechos (ver [status](#como-ler-o-status-das-execuções))
  e, no sucesso, roda `gh workflow disable` para parar de tentar.
- **Disparador externo (fora deste repo)**: um `systemd timer` numa instância
  sempre-ligada que aciona o workflow (`workflow_dispatch`) a cada 12 min. É o
  que garante a cadência confiável; ver a seção de configuração.

## Como ler o status das execuções

O status do apply foi desenhado para ser **honesto** - você não precisa abrir o
log para saber o que aconteceu:

| Status no GitHub | Significado |
|---|---|
| 🟢 **Verde (success)** | A instância foi **criada de verdade**. É o único caso verde, e o agendamento se desativa. |
| ⚪ **Cinza (cancelled)** | `Out of host capacity` - tentativa normal, sem capacidade no momento. O job cancela a si mesmo (não gera e-mail) e o próximo ciclo tenta de novo. |
| 🔴 **Vermelho (failure)** | Erro **real** que precisa de atenção (autenticação, cota, config...). O GitHub te notifica por e-mail. |

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
(Necessário para o job conseguir se auto-desativar e se auto-cancelar.)

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

### 6. Disparo confiável a cada 12 min (systemd timer)

Em vez de depender do `schedule` do GitHub (que descarta crons frequentes), use
uma **instância Linux sempre-ligada** (ex.: uma micro AMD do próprio free tier)
para acionar o workflow via API a cada 12 minutos.

**6.1. Criar um token (fine-grained PAT)**
GitHub → **Settings** (do usuário) → **Developer settings** → **Personal access
tokens → Fine-grained tokens** → **Generate new token**:
- **Resource owner:** seu usuário.
- **Repository access:** *Only select repositories* → este repositório.
- **Permissions → Repository permissions → Actions: Read and write** (o
  *Metadata: Read* é marcado automaticamente).
- Escolha uma validade (evite "sem expiração"). Gere e copie o `github_pat_...`.

**6.2. Criar o script disparador na instância** em `~/oci-a1-trigger/trigger.sh`
(troque `REPO` pelo seu `usuario/repo`):
```bash
#!/usr/bin/env bash
set -uo pipefail
BASE="$HOME/oci-a1-trigger"
TOKEN_FILE="$BASE/token"
LOG="$BASE/trigger.log"
REPO="<seu-usuario>/<seu-repo>"
WORKFLOW="apply.yml"
REF="main"
TIMER="oci-a1-trigger.timer"
API="https://api.github.com"

ts(){ date "+%Y-%m-%d %H:%M:%S%z"; }
log(){ echo "$(ts) $*" >> "$LOG"; }

if [ ! -s "$TOKEN_FILE" ]; then
  log "ERRO: token ausente/vazio em $TOKEN_FILE."
  exit 0
fi
TOKEN="$(tr -d ' \t\r\n' < "$TOKEN_FILE")"
AUTH="Authorization: Bearer $TOKEN"
ACCEPT="Accept: application/vnd.github+json"
VER="X-GitHub-Api-Version: 2022-11-28"

# Se o workflow ja foi desativado (instancia criada), para o timer e sai.
STATE="$(curl -sS -H "$AUTH" -H "$ACCEPT" -H "$VER" \
  "$API/repos/$REPO/actions/workflows/$WORKFLOW" | jq -r '.state // "unknown"')"
case "$STATE" in
  active) ;;
  disabled_manually|disabled_inactivity)
    log "Workflow '$STATE' (instancia provavelmente criada). Parando o timer."
    systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
    exit 0 ;;
  *) log "AVISO: estado do workflow = '$STATE'. Tentando dispatch mesmo assim." ;;
esac

# Dispara o workflow.
CODE="$(curl -sS -o "$BASE/last_response.json" -w '%{http_code}' \
  -X POST -H "$AUTH" -H "$ACCEPT" -H "$VER" \
  "$API/repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
  -d "{\"ref\":\"$REF\"}")"
if [ "$CODE" = "204" ]; then
  log "OK: workflow disparado (HTTP 204)."
else
  MSG="$(jq -r '.message // "sem mensagem"' "$BASE/last_response.json" 2>/dev/null)"
  log "FALHA no dispatch (HTTP $CODE): $MSG"
fi
```
Precisa de `curl` e `jq` instalados. Depois: `chmod +x ~/oci-a1-trigger/trigger.sh`.

**6.3. Guardar o token** (rode na instância; **não** deixa rastro no histórico):
```bash
umask 077; cat > ~/oci-a1-trigger/token
```
Cole o token, tecle **Enter** e depois **Ctrl+D**. Confira com
`ls -l ~/oci-a1-trigger/token` (deve estar `-rw-------`).

**6.4. Criar o serviço e o timer do systemd:**
```bash
sudo tee /etc/systemd/system/oci-a1-trigger.service >/dev/null <<'UNIT'
[Unit]
Description=Dispara o workflow Ampere A1 (GitHub Actions) via API
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/home/ubuntu/oci-a1-trigger/trigger.sh
UNIT

sudo tee /etc/systemd/system/oci-a1-trigger.timer >/dev/null <<'UNIT'
[Unit]
Description=Dispara o workflow Ampere A1 a cada 12 minutos

[Timer]
OnCalendar=*:0/12
Persistent=true
Unit=oci-a1-trigger.service

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now oci-a1-trigger.timer
```
(Ajuste o caminho em `ExecStart` se o usuário não for `ubuntu`.)

**6.5. Monitorar:**
```bash
# proximo disparo agendado
systemctl list-timers oci-a1-trigger.timer

# historico de disparos
tail -n 20 ~/oci-a1-trigger/trigger.log

# o loop ainda esta rodando? (active = tentando; inactive = parou por sucesso)
systemctl is-active oci-a1-trigger.timer
```

O script consulta o estado do workflow antes de cada disparo: **quando a
instância é criada, o workflow se auto-desativa e o próprio script para o
timer** (`systemctl disable --now`). Não fica disparando à toa.

### 7. Testar manualmente
Aba **Actions** → workflow **"Ampere A1 auto-provision"** → **Run workflow**.
- Ficou **cancelado (cinza)** com `Out of host capacity`: normal, é o que o
  loop vai ficar tentando resolver.
- Ficou **vermelho**: erro real (autenticação/backend/cota) - revise os secrets
  do passo 5 e a config.
- Ficou **verde**: a instância foi criada e o workflow se desativa sozinho.

## Depois que a instância for criada
- O agendamento se desativa sozinho (no GitHub) e o `systemd timer` da instância
  também para sozinho no ciclo seguinte.
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

## Como reativar (se a instância for terminada e você quiser recriar)

O sucesso desativa **duas** coisas: os gatilhos do workflow (`gh workflow
disable`) e o `systemd timer` na instância. Para recriar, religue os dois:

**No GitHub** (interface): aba **Actions** → **"Ampere A1 auto-provision"**
(aparece como *Disabled*) → **"Enable workflow"**. Ou via CLI:
```bash
gh workflow enable apply.yml
```

**Na instância disparadora**:
```bash
sudo systemctl enable --now oci-a1-trigger.timer
```

Depois disso o loop volta a rodar a cada 12 minutos até criar a instância de
novo - e tudo se desativa sozinho outra vez quando conseguir.

## Minutos de GitHub Actions para repositórios (público vs privado)

Rodando a cada 12 min, o workflow executa ~120 vezes/dia. Em **repositório
privado no plano Free** isso consome os 2.000 min/mês gratuitos (cada execução
conta como no mínimo 1 minuto) e o Actions para quando o limite estoura. Opções:

- **Deixar o repositório público**: minutos de Actions ficam **ilimitados e
  gratuitos**. Os secrets continuam criptografados e protegidos mesmo em repo
  público; apenas os arquivos `.tf` ficam visíveis. foi a minha decisão para deixar esse repo público
- **Aumentar o intervalo** (ex.: `OnCalendar=*:0/30` no timer) para caber no
  limite grátis (~1.440 min/mês).
- **Instalar o terrform em uma distro linux**: instale toda a infraestrutura de provisionamento
em uma distro linux, necessário terraform.
