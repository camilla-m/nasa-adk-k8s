# 🚀 Agentes da NASA no GKE com Google ADK

Tutorial passo a passo: dois agentes de IA feitos com o
[Google Agent Development Kit (ADK)](https://google.github.io/adk-docs/) conversam
entre si para explicar o espaço para crianças, usando imagens reais da NASA.
Depois a gente coloca tudo para rodar no **Google Kubernetes Engine (GKE)**,
criando a infraestrutura com **Terraform**.

Versão simplificada de [camilla-m/agents-k8s-google-tf](https://github.com/camilla-m/agents-k8s-google-tf):
sem scripts, cada comando é digitado e explicado.

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
├── Dockerfile
├── cloudbuild.yaml       # build da imagem no Google Cloud (não precisa de Docker local)
└── requirements.txt
```

---

## Passo 0: pré-requisitos

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

Você também precisa de um **projeto no Google Cloud com billing ativado**
(sem billing o Gemini responde `403 BILLING_DISABLED`).

---

## Passo 1: rodar os agentes no seu computador

Antes de pensar em Kubernetes, vamos ver os agentes funcionando.

```bash
git clone https://github.com/camilla-m/nasa-adk-k8s.git
cd nasa-adk-k8s

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Agora diga ao ADK como chegar no Gemini. Escolha **uma** das opções:

**Opção A: chave do Google AI Studio (mais rápido)**

Gere uma chave grátis em https://aistudio.google.com/apikey e:

```bash
export GOOGLE_API_KEY="sua-chave"
```

**Opção B: Vertex AI no seu projeto (o mesmo que o GKE vai usar)**

```bash
gcloud auth application-default login
export GOOGLE_GENAI_USE_VERTEXAI=TRUE
export GOOGLE_CLOUD_PROJECT="seu-projeto"
export GOOGLE_CLOUD_LOCATION=global   # modelos novos ficam no endpoint global
```

Suba a interface de desenvolvimento do ADK:

```bash
adk web agents
```

Abra http://localhost:8000, escolha **nasa_agents** no canto superior esquerdo
e pergunte, por exemplo:

- "O que é um buraco negro?"
- "Me mostra fotos de Saturno"
- "Como foi a Apollo 11?"

Clique nos eventos à esquerda da conversa: você vê o `professor` chamando o
`astronomo`, e o `astronomo` chamando `buscar_imagens_nasa`. É a conversa entre
os dois agentes acontecendo.

> Prefere o terminal? `adk run agents/nasa_agents`

Pare o servidor com `Ctrl+C` quando terminar.

---

## Passo 2: entender o código

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

---

## Passo 3: preparar o Google Cloud

Faça login (os dois comandos são necessários: o primeiro é para o `gcloud`,
o segundo para o Terraform):

```bash
gcloud auth login
gcloud auth application-default login
```

Guarde o ID do projeto e a região em variáveis. Vamos usar nos próximos passos:

```bash
export PROJECT_ID="seu-projeto"
export REGION="us-central1"
gcloud config set project $PROJECT_ID
```

---

## Passo 4: criar a infraestrutura com Terraform

Veja o que o [terraform/main.tf](terraform/main.tf) cria:

1. Liga as APIs: GKE, Artifact Registry, Cloud Build e Vertex AI
2. Um repositório no **Artifact Registry** para a imagem Docker
3. Um cluster **GKE Autopilot** (o Google gerencia os nós, você só paga pelos pods)
4. Uma permissão de **Workload Identity**: o ServiceAccount `nasa-agents` do
   Kubernetes pode chamar o Vertex AI. Assim o pod usa o Gemini sem nenhuma chave
5. Permissões para o Cloud Build publicar a imagem

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars` e coloque o ID do seu projeto. Depois:

```bash
terraform init      # baixa o provider do Google
terraform plan      # mostra o que vai ser criado (nada é criado ainda)
terraform apply     # cria de verdade; digite "yes" para confirmar
```

O cluster demora uns **10 minutos**. Quando terminar, o Terraform mostra dois
outputs. Guarde a imagem numa variável e volte para a raiz do projeto:

```bash
export IMAGE=$(terraform output -raw image)
echo $IMAGE
cd ..
```

---

## Passo 5: construir a imagem Docker

O [Dockerfile](Dockerfile) é bem curto: instala as dependências, copia a pasta
`agents/` e roda `adk web` na porta 8080.

Vamos construir no **Cloud Build**, assim não precisa de Docker instalado e a
imagem já sai no formato certo (amd64) mesmo em Mac com Apple Silicon:

```bash
gcloud builds submit --config cloudbuild.yaml --substitutions _IMAGE=$IMAGE
```

Leva uns 2 minutos. No final aparece `SUCCESS` e a imagem está no Artifact Registry:

```bash
gcloud artifacts docker images list $REGION-docker.pkg.dev/$PROJECT_ID/nasa-agents
```

---

## Passo 6: conectar o kubectl ao cluster

```bash
gcloud container clusters get-credentials nasa-agents --region $REGION
kubectl get nodes
```

> No Autopilot é normal `kubectl get nodes` mostrar poucos nós (ou nenhum).
> Os nós são criados quando aparecem pods para rodar.

---

## Passo 7: fazer o deploy

O [k8s/app.yaml](k8s/app.yaml) tem quatro objetos:

| Objeto | Para quê |
|---|---|
| `Namespace nasa` | separa nossa aplicação do resto do cluster |
| `ServiceAccount nasa-agents` | a identidade que recebeu permissão de Vertex AI no passo 4 |
| `Deployment nasa-agents` | roda 1 pod com a imagem dos agentes |
| `Service nasa-agents` | dá um endereço interno estável para o pod |

O arquivo tem dois marcadores, `IMAGE_URL` e `PROJECT_ID`. O `sed` troca pelos
valores reais e entrega o resultado para o `kubectl`:

```bash
sed -e "s|IMAGE_URL|$IMAGE|" -e "s|PROJECT_ID|$PROJECT_ID|" k8s/app.yaml | kubectl apply -f -
```

Acompanhe o pod subindo (no Autopilot o primeiro pod pode levar 1 ou 2 minutos,
enquanto o nó é criado):

```bash
kubectl get pods -n nasa -w
```

Espere aparecer `1/1 Running` e saia com `Ctrl+C`.

---

## Passo 8: conversar com os agentes no cluster

O `adk web` não tem login, então o Service **não** fica exposto na internet.
Usamos um túnel do seu computador até o cluster:

```bash
kubectl port-forward -n nasa service/nasa-agents 8080:80
```

Abra http://localhost:8080 e converse como no passo 1. Agora quem responde é o
pod no GKE, falando com o Gemini pelo Vertex AI via Workload Identity.

### Pela API REST (opcional)

Com o port-forward rodando, em outro terminal:

```bash
# cria uma sessão de conversa
curl -X POST localhost:8080/apps/nasa_agents/users/eu/sessions/s1 \
  -H "Content-Type: application/json" -d '{}'

# manda uma pergunta
curl -X POST localhost:8080/run -H "Content-Type: application/json" -d '{
  "app_name": "nasa_agents",
  "user_id": "eu",
  "session_id": "s1",
  "new_message": {"role": "user", "parts": [{"text": "O que é uma nebulosa?"}]}
}'
```

A resposta é a lista de eventos da conversa: dá para ver o `professor` chamando
o `astronomo`, a busca na NASA e a resposta final.

### Ver os logs

```bash
kubectl logs -n nasa deployment/nasa-agents -f
```

---

## Passo 9: limpar tudo

O cluster custa dinheiro enquanto existir. Quando terminar:

```bash
kubectl delete -f k8s/app.yaml
cd terraform
terraform destroy   # digite "yes"
```

O `terraform destroy` apaga o cluster e o repositório de imagens (com as imagens
dentro). As APIs continuam ligadas, mas não custam nada paradas.

---

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `403 BILLING_DISABLED` | projeto sem billing | ative billing no console e espere alguns minutos |
| `403 PERMISSION_DENIED ... aiplatform.endpoints.predict` no log do pod | permissão de Workload Identity ainda propagando | espere 2 a 5 minutos e tente de novo |
| Pod em `ImagePullBackOff` | o passo 5 não terminou ou `$IMAGE` estava vazio no passo 7 | `echo $IMAGE`, refaça o passo 5 e depois o 7 |
| Pod `Pending` por 1 ou 2 minutos | o Autopilot está criando um nó | normal, só esperar |
| `gke-gcloud-auth-plugin not found` | plugin não instalado | `gcloud components install gke-gcloud-auth-plugin` |
| `adk: command not found` | venv não ativado | `source .venv/bin/activate` |
| `503 UNAVAILABLE ... high demand` | Gemini sobrecarregado (temporário) | o agente já tenta 5 vezes sozinho; se ainda falhar, espere uns minutos ou troque `GEMINI_MODEL` |
| `404 Publisher model ... was not found` (Vertex) | modelo não existe nessa região do Vertex | use `GOOGLE_CLOUD_LOCATION=global`, ou troque `GEMINI_MODEL`; no cluster: `kubectl set env -n nasa deployment/nasa-agents GEMINI_MODEL=<modelo>` |
| `404 ... no longer available to new users` (AI Studio) | modelo aposentado | troque `GEMINI_MODEL` por um modelo atual |

## Menção honrosa: pegadinhas que apareceram testando

Coisas que pegaram a gente na primeira vez que rodamos este tutorial de ponta a ponta.

**1. O mesmo modelo pode existir no AI Studio e não no Vertex (ou o contrário).**
O `gemini-3.1-flash-lite` funcionava com a chave do AI Studio (passo 1, opção A),
mas no GKE dava `404 Publisher model ... was not found`. No Vertex ele só existe no
endpoint **global**, não em `us-central1`. Por isso o `k8s/app.yaml` usa
`GOOGLE_CLOUD_LOCATION=global`. O cluster continua em `us-central1`, só a chamada
ao Gemini vai para o global.

Para descobrir quais modelos o seu projeto alcança no Vertex:

```bash
export PROJECT_ID="seu-projeto"
TOKEN=$(gcloud auth print-access-token)
for loc in us-central1 global; do
  host=$([ $loc = global ] && echo aiplatform.googleapis.com || echo $loc-aiplatform.googleapis.com)
  for m in gemini-3.1-flash-lite gemini-3.5-flash-lite gemini-2.5-flash; do
    printf "%-12s %-24s " $loc $m
    curl -s -o /dev/null -w "%{http_code}  %{time_total}s\n" -X POST \
      "https://${host}/v1/projects/${PROJECT_ID:?defina PROJECT_ID}/locations/${loc}/publishers/google/models/${m}:generateContent" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"contents":[{"role":"user","parts":[{"text":"oi"}]}]}'
  done
done
```

`200` funciona. Troque no cluster sem rebuild:
`kubectl set env -n nasa deployment/nasa-agents GEMINI_MODEL=<modelo> GOOGLE_CLOUD_LOCATION=<local>`.

**2. Modelo da moda vive lotado (`503 UNAVAILABLE ... high demand`).**
O modelo flash mais novo ficou dando 503 por muito tempo, principalmente com a
chave grátis do AI Studio. O ADK não tenta de novo por padrão, então o
[agent.py](agents/nasa_agents/agent.py) configura `retry_options` (5 tentativas
com espera crescente). Se mesmo assim falhar, use um modelo "lite": além de ter
menos fila, é bem mais rápido, e cada pergunta faz 4 chamadas ao Gemini
(professor, astronomo, astronomo de novo, professor).

**3. `kubectl get nodes` vazio no Autopilot é normal.**
Os nós só nascem quando aparece um pod para rodar. Antes do passo 7, os pods do
`kube-system` (como o `kube-dns`) ficam `Pending`, e isso também é normal. O
primeiro deploy leva de 3 a 6 minutos: criar o nó (2 a 5 min), baixar a imagem
(~1 min) e subir o `adk web`. Acompanhe com `kubectl get events -n nasa -w`.

**4. No zsh, `$m:algo` não é o que parece.**
Em scripts com `"$m:generateContent"`, o zsh lê o `:g` como modificador da
variável e a URL sai quebrada (404 vazio). Use sempre `${m}:generateContent`.

**5. O Cloud Shell esquece as variáveis.**
Se a sessão reiniciar, `$PROJECT_ID`, `$REGION` e `$IMAGE` somem, e os comandos
falham de jeitos estranhos (como 400 em toda chamada ao Vertex, porque a URL
virou `projects//...`). Recrie:

```bash
export PROJECT_ID="seu-projeto"
export REGION="us-central1"
export IMAGE=$(terraform -chdir=terraform output -raw image)
```

## Ideias para continuar

- Dar mais uma ferramenta ao `astronomo` (por exemplo a
  [APOD](https://api.nasa.gov), foto astronômica do dia)
- Criar um terceiro agente, como um "poeta" que transforma a resposta em rima
- Trocar o `port-forward` por um Ingress com
  [Identity-Aware Proxy](https://cloud.google.com/iap/docs/enabling-kubernetes-howto)
  para acessar com login do Google
