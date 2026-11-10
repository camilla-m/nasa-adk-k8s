# 🚀 Agentes da NASA no GKE com Google ADK

Tutorial passo a passo: dois agentes de IA feitos com o
[Google Agent Development Kit (ADK)](https://google.github.io/adk-docs/) conversam
entre si para explicar o espaço para crianças, usando imagens reais da NASA.
Depois a gente coloca tudo para rodar no **Google Kubernetes Engine (GKE)**,
criando a infraestrutura com **Terraform**.

Versão simplificada de [camilla-m/agents-k8s-google-tf](https://github.com/camilla-m/agents-k8s-google-tf):
sem scripts, cada comando é copiado, colado e explicado. Todo passo termina com
um **✅ Confira** dizendo o que você deve ver antes de seguir.

## O que vamos construir

```
 Você: "O que é um buraco negro?"
   │
   ▼
┌───────────────┐   "pesquise imagens de      ┌───────────────┐   GET /search?q=black hole   ┌──────────────────┐
│   professor   │ ──── buraco negro" ───────▶ │   astronomo   │ ──────────────────────────▶ │  API de imagens   │
│ (root_agent)  │ ◀─── títulos, datas, URLs ── │               │ ◀────────── JSON ─────────── │  da NASA          │
└───────────────┘                              └───────────────┘                              └──────────────────┘
   │
   ▼
 Resposta simples, com comparação do dia a dia, curiosidade e links das imagens
```

- **astronomo**: tem uma ferramenta (`buscar_imagens_nasa`) que consulta a
  [biblioteca de imagens da NASA](https://images.nasa.gov). Não precisa de chave.
- **professor**: é quem conversa com você. Ele não sabe buscar nada sozinho:
  pede ajuda ao `astronomo` e traduz a resposta para linguagem de criança.

Os dois usam o Gemini (`gemini-3.1-flash-lite`) como modelo.

## Estrutura do projeto

```
.
├── agents/nasa_agents/
│   ├── __init__.py       # o ADK procura o pacote aqui
│   └── agent.py          # os 2 agentes + a ferramenta da NASA
├── terraform/            # cluster GKE, registro de imagens e permissões
├── k8s/app.yaml          # Namespace, ServiceAccount, Deployment e Service
├── config.env.example    # suas configurações (projeto, região, modelo)
├── Dockerfile
├── cloudbuild.yaml       # build da imagem no Google Cloud (não precisa de Docker local)
└── requirements.txt
```

---

## Passo 0: onde rodar

**Recomendado: [Cloud Shell](https://shell.cloud.google.com).** Já vem com
`gcloud`, `kubectl`, Terraform e Python instalados e com login feito. Pule direto
para o passo 1.

**No seu computador**, instale:

| Ferramenta | Para quê |
|---|---|
| Python 3.10+ | rodar os agentes localmente |
| [gcloud](https://cloud.google.com/sdk/docs/install) | falar com o Google Cloud |
| [Terraform](https://developer.hashicorp.com/terraform/install) 1.5+ | criar a infraestrutura |
| kubectl + `gke-gcloud-auth-plugin` | falar com o cluster |

No macOS:

```bash
brew install --cask google-cloud-sdk
brew install terraform kubectl
gcloud components install gke-gcloud-auth-plugin
```

Nos dois casos você precisa de um **projeto no Google Cloud com billing ativado**.

> ⚠️ **Não use zsh para colar os loops deste tutorial sem ler o aviso:** no zsh,
> `$m:algo` vira outra coisa. Os comandos aqui já usam `${m}`, que funciona em
> bash e zsh. Se for adaptar algum, mantenha as chaves.

---

## Passo 1: clonar e configurar

```bash
cd ~
git clone https://github.com/camilla-m/nasa-adk-k8s.git || git -C nasa-adk-k8s pull
cd ~/nasa-adk-k8s
[ -f config.env ] || cp config.env.example config.env
```

O `config.env` guarda tudo que muda de pessoa para pessoa. Coloque o ID do seu
projeto nele (troque `coloque-seu-projeto-aqui` na primeira linha):

```bash
MEU_PROJETO="coloque-seu-projeto-aqui"
sed -i.bak "s/seu-projeto/$MEU_PROJETO/" config.env
```

**Todo passo daqui para frente começa com `source config.env`.** Se o terminal
fechar ou o Cloud Shell reiniciar (ele reinicia sozinho depois de um tempo parado),
as variáveis voltam na hora e você continua de onde parou.

**Só no seu computador** (no Cloud Shell não precisa), faça login. São dois
comandos porque o primeiro é para o `gcloud` e o segundo para o Terraform:

```bash
gcloud auth login
gcloud auth application-default login
```

✅ **Confira:**

```bash
cd ~/nasa-adk-k8s && source config.env
echo "Projeto: $PROJECT_ID"
gcloud billing projects describe $PROJECT_ID --format="value(billingEnabled)"
```

Deve aparecer o seu projeto e `True`. Se aparecer `False`, ative o billing no
console antes de seguir (sem billing nada funciona, e o erro só aparece lá na frente).

---

## Passo 2: rodar os agentes no seu computador (ou no Cloud Shell)

Antes de pensar em Kubernetes, vamos ver os agentes funcionando.

```bash
cd ~/nasa-adk-k8s && source config.env
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt
```

Agora diga ao ADK como chegar no Gemini. Escolha **uma** das opções:

**Opção A: chave do Google AI Studio (mais rápido de configurar)**

Gere uma chave grátis em https://aistudio.google.com/apikey e:

```bash
export GOOGLE_API_KEY="sua-chave"
```

> A chave grátis é a primeira a levar `503 high demand` quando o Gemini está
> cheio. Se acontecer, use a opção B.

**Opção B: Vertex AI no seu projeto (o mesmo caminho que o GKE vai usar)**

```bash
unset GOOGLE_API_KEY
gcloud services enable aiplatform.googleapis.com
export GOOGLE_GENAI_USE_VERTEXAI=TRUE
export GOOGLE_CLOUD_PROJECT=$PROJECT_ID
export GOOGLE_CLOUD_LOCATION=$GEMINI_LOCATION
```

Suba a interface do ADK:

```bash
pkill -f "adk web"; adk web --port 8080 --allow_origins 'regex:https://.*\.cloudshell\.dev' agents
```

> O `--allow_origins` é para o Cloud Shell: o ADK recusa com `403` chamadas que
> vêm de um endereço diferente do servidor, e o Web Preview abre a página em
> `https://8080-....cloudshell.dev`. Sem ele, a interface fica preta/vazia.

Abra a interface:
- **No computador:** http://localhost:8080
- **No Cloud Shell:** botão **Web Preview** (ícone de olho no topo) → **Preview on port 8080**.
  Se a tela ficar vazia, acrescente `/dev-ui/` no final da URL e confira se o
  `adk web` foi iniciado com o `--allow_origins` acima.

Escolha **nasa_agents** no canto superior esquerdo e pergunte, por exemplo:

- "O que é um buraco negro?"
- "Me mostra fotos de Saturno"
- "Como foi a Apollo 11?"

✅ **Confira:** clique nos eventos à esquerda da conversa. Você deve ver o
`professor` chamando o `astronomo`, e o `astronomo` chamando `buscar_imagens_nasa`.
É a conversa entre os dois agentes. A resposta leva alguns segundos, porque são
4 chamadas ao Gemini em sequência.

Se der erro, olhe o terminal onde o `adk web` está rodando e procure na tabela de
[problemas comuns](#problemas-comuns). Pare o servidor com `Ctrl+C`.

---

## Passo 3: entender o código

Tudo está em [agents/nasa_agents/agent.py](agents/nasa_agents/agent.py). São três peças:

**1. A ferramenta** é uma função Python comum. O ADK lê o nome, os parâmetros e a
docstring e explica para o Gemini como usá-la:

```python
def buscar_imagens_nasa(termo: str) -> dict:
    """Busca imagens na biblioteca pública da NASA (images.nasa.gov). ..."""
```

**2. O astronomo** é um `LlmAgent` que recebe essa ferramenta:

```python
astronomo = LlmAgent(
    name="astronomo",
    model=MODEL,
    instruction="Você é um astrônomo da NASA. Use a ferramenta buscar_imagens_nasa ...",
    tools=[buscar_imagens_nasa],
)
```

**3. O professor** recebe o astronomo **como ferramenta**, usando `AgentTool`.
É isso que faz um agente conversar com o outro:

```python
root_agent = LlmAgent(
    name="professor",
    model=MODEL,
    instruction="... peça primeiro ao agente astronomo ...",
    tools=[AgentTool(agent=astronomo)],
)
```

O nome `root_agent` é obrigatório: é ele que o `adk web` procura.

O `MODEL` lê o nome do modelo da variável `GEMINI_MODEL` e já vem com **retry**:
se o Gemini responder `503` (sobrecarregado), ele tenta de novo até 5 vezes,
esperando 1s, 2s, 4s e 8s. Sem isso, o ADK desiste na primeira falha.

---

## Passo 4: criar a infraestrutura com Terraform

Veja o que o [terraform/main.tf](terraform/main.tf) cria:

1. Liga as APIs: GKE, Artifact Registry, Cloud Build e Vertex AI
2. Um repositório no **Artifact Registry** para a imagem Docker
3. Um cluster **GKE Autopilot** (o Google gerencia os nós, você só paga pelos pods)
4. Uma permissão de **Workload Identity**: o ServiceAccount `nasa-agents` do
   Kubernetes pode chamar o Vertex AI. Assim o pod usa o Gemini sem nenhuma chave
5. Permissões para o Cloud Build publicar a imagem

O projeto e a região vêm do `config.env` (as variáveis `TF_VAR_*`), então não
precisa editar nenhum arquivo do Terraform:

```bash
cd ~/nasa-adk-k8s && source config.env
terraform -chdir=terraform init
terraform -chdir=terraform plan     # só mostra o que vai ser criado
terraform -chdir=terraform apply    # cria de verdade; digite "yes"
```

O cluster demora uns **10 minutos**. Se o terminal cair no meio, não tem
problema: rode o `source config.env` e o `apply` de novo, ele continua de onde parou.

✅ **Confira:** termina com `Apply complete!` e mostra os outputs `image` e
`get_credentials`. Se falhar com erro de permissão ou "API not enabled" logo depois
de ligar as APIs, espere 1 minuto e rode o `apply` de novo.

---

## Passo 5: conferir se o modelo existe no seu projeto

Os modelos Gemini mudam rápido, e o mesmo nome pode existir no AI Studio mas não
no Vertex, ou existir só em algumas regiões. Melhor descobrir agora do que com o
pod já no ar. Este comando testa o modelo do `config.env` e algumas alternativas:

```bash
cd ~/nasa-adk-k8s && source config.env
TOKEN=$(gcloud auth print-access-token)
for loc in global us-central1; do
  host=$([ $loc = global ] && echo aiplatform.googleapis.com || echo $loc-aiplatform.googleapis.com)
  for m in $GEMINI_MODEL gemini-3.5-flash-lite gemini-2.5-flash; do
    printf "%-12s %-24s " $loc $m
    curl -s -o /dev/null -w "%{http_code}  %{time_total}s\n" -X POST \
      "https://${host}/v1/projects/${PROJECT_ID}/locations/${loc}/publishers/google/models/${m}:generateContent" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"contents":[{"role":"user","parts":[{"text":"oi"}]}]}'
  done
done
```

✅ **Confira:** a primeira linha (`global` + o seu `GEMINI_MODEL`) deve dar `200`.

| Resultado | O que fazer |
|---|---|
| `200` na primeira linha | siga para o passo 6 |
| `404` na primeira, `200` em outra | edite `GEMINI_MODEL` e `GEMINI_LOCATION` no `config.env` com a combinação que deu 200 |
| `503` | modelo sobrecarregado; escolha outra combinação com 200 |
| `403` | billing desligado ou a API do Vertex ainda ligando; espere 1 minuto |
| `400` em tudo | `PROJECT_ID` vazio; rode `source config.env` |

---

## Passo 6: construir a imagem Docker

O [Dockerfile](Dockerfile) é bem curto: instala as dependências, copia a pasta
`agents/` e roda `adk web` na porta 8080.

Vamos construir no **Cloud Build**, assim não precisa de Docker instalado e a
imagem já sai no formato certo (amd64) mesmo em Mac com Apple Silicon:

```bash
cd ~/nasa-adk-k8s && source config.env
gcloud builds submit --config cloudbuild.yaml --substitutions _IMAGE=$IMAGE
```

Leva uns 2 minutos.

✅ **Confira:**

```bash
gcloud artifacts docker images describe $IMAGE --format="value(image_summary.digest)"
```

Deve aparecer um `sha256:...`. Se der `NOT_FOUND`, o build não terminou: veja o
erro no final da saída do `builds submit`. Erro de permissão logo depois do
`terraform apply` costuma ser propagação de IAM: espere 2 minutos e rode de novo.

---

## Passo 7: conectar o kubectl ao cluster

```bash
cd ~/nasa-adk-k8s && source config.env
gcloud container clusters get-credentials nasa-agents --region $REGION
```

✅ **Confira:**

```bash
kubectl get namespaces
```

Deve listar `default`, `kube-system` e outros.

> `kubectl get nodes` vazio é **normal** no Autopilot: os nós só são criados
> quando aparece um pod para rodar. Pelo mesmo motivo, os pods do `kube-system`
> ficam `Pending` até o passo 8.

---

## Passo 8: fazer o deploy

O [k8s/app.yaml](k8s/app.yaml) tem quatro objetos:

| Objeto | Para quê |
|---|---|
| `Namespace nasa` | separa nossa aplicação do resto do cluster |
| `ServiceAccount nasa-agents` | a identidade que recebeu permissão de Vertex AI no passo 4 |
| `Deployment nasa-agents` | roda 1 pod com a imagem dos agentes |
| `Service nasa-agents` | dá um endereço interno estável para o pod |

O arquivo tem marcadores (`IMAGE_URL`, `PROJECT_ID`, `MODEL_NAME`,
`MODEL_LOCATION`). O `sed` troca pelos valores do `config.env` e entrega o
resultado para o `kubectl`:

```bash
cd ~/nasa-adk-k8s && source config.env
sed -e "s|IMAGE_URL|$IMAGE|" -e "s|PROJECT_ID|$PROJECT_ID|" \
    -e "s|MODEL_NAME|$GEMINI_MODEL|" -e "s|MODEL_LOCATION|$GEMINI_LOCATION|" \
    k8s/app.yaml | kubectl apply -f -
kubectl rollout status -n nasa deployment/nasa-agents --timeout=10m
```

O `rollout status` espera sozinho o pod ficar pronto. Na **primeira vez leva de 3 a
6 minutos**, e é normal ficar um tempo parado em `Waiting for deployment...`:

| Etapa | Tempo típico |
|---|---|
| Autopilot cria um nó | 2 a 5 min |
| Baixa a imagem | ~1 min |
| `adk web` sobe | 10 a 20 s |

Quer ver o que está acontecendo enquanto espera? Em outra aba:
`kubectl get events -n nasa -w`.

✅ **Confira:** termina com `deployment "nasa-agents" successfully rolled out`.

Se der `timed out`, veja o motivo:

```bash
kubectl describe pod -n nasa -l app=nasa-agents | tail -20
```

`ImagePullBackOff` quer dizer que a imagem não existe (volte ao passo 6).
`FailedScaleUp` com `quota` quer dizer que faltou quota de CPU na região.

---

## Passo 9: conversar com os agentes no cluster

O `adk web` não tem login, então o Service **não** fica exposto na internet.
Usamos um túnel do seu terminal até o cluster. O `pkill` fecha algum túnel antigo
que esteja segurando a porta 8080 (senão dá `address already in use`), e o `&`
deixa o túnel rodando em segundo plano para você continuar usando o terminal:

```bash
cd ~/nasa-adk-k8s && source config.env
pkill -f "kubectl port-forward"; pkill -f "adk web"
kubectl port-forward -n nasa service/nasa-agents 8080:80 > /tmp/port-forward.log 2>&1 &
sleep 3 && curl -s localhost:8080/health
```

✅ **Confira:** deve aparecer `{"status":"ok"}`.

Abra a interface do mesmo jeito do passo 2 (http://localhost:8080 ou **Web
Preview → port 8080** no Cloud Shell) e converse. Agora quem responde é o pod no
GKE, falando com o Gemini pelo Vertex AI via Workload Identity.

### Pela API REST

```bash
# cria uma sessão de conversa e guarda o id
SESSION=$(curl -s -X POST localhost:8080/apps/nasa_agents/users/eu/sessions \
  -H "Content-Type: application/json" -d '{}' | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "Sessão: $SESSION"

# manda uma pergunta
curl -s -X POST localhost:8080/run -H "Content-Type: application/json" -d '{
  "app_name": "nasa_agents",
  "user_id": "eu",
  "session_id": "'"$SESSION"'",
  "new_message": {"role": "user", "parts": [{"text": "O que é uma nebulosa?"}]}
}' | grep -oE '"author":"[a-z_]+"|"text":"[^"]{0,150}'
```

✅ **Confira:** aparecem linhas com `"author":"astronomo"` e `"author":"professor"`,
e o texto da resposta. Se aparecer `Internal Server Error`, veja o erro real no log:

```bash
kubectl logs -n nasa deployment/nasa-agents --tail=50 | grep -E "Error|error" | tail -5
```

e procure na tabela de [problemas comuns](#problemas-comuns).

### Se o túnel cair

O túnel cai quando o pod é trocado (por exemplo depois de um `kubectl set env`)
ou quando o Cloud Shell reinicia. É só rodar o primeiro bloco deste passo de novo.

---

## Passo 10: limpar tudo

O cluster custa dinheiro enquanto existir. Quando terminar:

```bash
cd ~/nasa-adk-k8s && source config.env
pkill -f "kubectl port-forward"
kubectl delete namespace nasa
terraform -chdir=terraform destroy   # digite "yes"
```

O `terraform destroy` apaga o cluster e o repositório de imagens (com as imagens
dentro). As APIs continuam ligadas, mas não custam nada paradas.

---

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `403 BILLING_DISABLED` | projeto sem billing | ative billing no console e espere alguns minutos |
| `404 Publisher model ... was not found` (Vertex) | modelo não existe nessa região do Vertex | rode o teste do passo 5 e troque no cluster sem rebuild: `kubectl set env -n nasa deployment/nasa-agents GEMINI_MODEL=<modelo> GOOGLE_CLOUD_LOCATION=<local>` |
| `404 ... no longer available to new users` (AI Studio) | modelo aposentado | troque `GEMINI_MODEL` por um modelo atual |
| `503 UNAVAILABLE ... high demand` | Gemini sobrecarregado | o agente já tenta 5 vezes sozinho; se continuar, troque de modelo (um "lite" tem menos fila) ou use o Vertex em vez da chave grátis |
| `403 PERMISSION_DENIED ... aiplatform` no log do pod | permissão de Workload Identity ainda propagando | espere 2 a 5 minutos e tente de novo |
| Interface do ADK preta/vazia e `403` no console do navegador (F12) | o ADK recusa a origem `*.cloudshell.dev` do Web Preview | local: rode o `adk web` com o `--allow_origins` do passo 2; no cluster: a imagem já tem a flag (refaça os passos 6 e 8 se a sua imagem for antiga) |
| `address already in use` no port-forward | túnel antigo ou `adk web` local usando a porta 8080 | `pkill -f "kubectl port-forward"; pkill -f "adk web"` |
| Pod em `ImagePullBackOff` | a imagem não foi publicada | refaça o passo 6 e depois o 8 |
| Pod `Pending` por 1 a 5 minutos | o Autopilot está criando um nó | normal, o `rollout status` espera sozinho |
| Erros estranhos depois de um tempo parado (400, variável vazia) | o terminal ou o Cloud Shell reiniciou | `cd ~/nasa-adk-k8s && source config.env` |
| `gke-gcloud-auth-plugin not found` | plugin não instalado | `gcloud components install gke-gcloud-auth-plugin` |
| `adk: command not found` | venv não ativado | `source .venv/bin/activate` |

## Menção honrosa: pegadinhas que apareceram testando

Este tutorial já evita cada uma delas, mas vale saber por que os passos são do
jeito que são.

1. **O mesmo modelo pode existir no AI Studio e não no Vertex.** O
   `gemini-3.1-flash-lite` funcionava com a chave do AI Studio, mas no GKE dava
   `404 Publisher model ... was not found`: no Vertex ele só existe no endpoint
   **global**, não em `us-central1`. Por isso o passo 5 testa o modelo antes do
   deploy, e o `config.env` usa `GEMINI_LOCATION="global"`. O cluster continua em
   `us-central1`; só a chamada ao Gemini vai para o global.
2. **Modelo da moda vive lotado.** O flash mais novo ficou dando `503 high demand`
   por muito tempo, principalmente com a chave grátis do AI Studio. O ADK não tenta
   de novo por padrão, então o `agent.py` configura retry. Um modelo "lite" tem
   menos fila e é bem mais rápido, o que importa porque cada pergunta faz 4
   chamadas ao Gemini.
3. **`kubectl get nodes` vazio no Autopilot é normal.** Os nós só nascem quando
   aparece um pod. Por isso o passo 8 usa `kubectl rollout status`, que espera
   sozinho, em vez de deixar a pessoa olhando um `Pending` sem saber se travou.
4. **No zsh, `$m:algo` não é o que parece.** Em `"$m:generateContent"` o zsh lê o
   `:g` como modificador da variável e a URL sai quebrada (404 vazio). Os loops
   usam `${m}`.
5. **O Cloud Shell esquece as variáveis.** Depois de um tempo parado ele reinicia, e
   `$PROJECT_ID` vazio vira `projects//...` na URL (400 em toda chamada). Por isso
   tudo mora no `config.env` e todo passo começa com `source config.env`.
6. **Porta 8080 ocupada.** Rodar o port-forward duas vezes (ou com o `adk web`
   local ainda aberto) dá `address already in use`. Por isso o passo 9 começa com
   `pkill`.

7. **Tela preta no Web Preview do Cloud Shell.** O ADK protege o servidor contra
   páginas de outros sites e responde `403` quando o `Origin` da chamada não bate
   com o endereço do servidor. O Web Preview abre em `https://8080-....cloudshell.dev`,
   então tudo era recusado e a interface ficava preta. A imagem e o passo 2 já
   liberam só esse domínio com `--allow_origins 'regex:https://.*\.cloudshell\.dev'`.

## Ideias para continuar

- Dar mais uma ferramenta ao `astronomo` (por exemplo a
  [APOD](https://api.nasa.gov), foto astronômica do dia)
- Criar um terceiro agente, como um "poeta" que transforma a resposta em rima
- Trocar o `port-forward` por um Ingress com
  [Identity-Aware Proxy](https://cloud.google.com/iap/docs/enabling-kubernetes-howto)
  para acessar com login do Google
