"""
Dois agentes ADK conversando:

- astronomo: busca imagens reais na biblioteca de imagens da NASA.
- professor (root_agent): fala com o usuário, pede ajuda ao astronomo
  e explica o resultado como se fosse para uma criança de 10 anos.

O professor enxerga o astronomo como uma ferramenta (AgentTool): ele manda
uma pergunta, o astronomo responde, e o professor usa a resposta.
"""

import os

import requests
from google.adk.agents import LlmAgent
from google.adk.models import Gemini
from google.adk.tools.agent_tool import AgentTool
from google.genai import types

# Se o Gemini responder 429/503 ("high demand"), tenta de novo até 5 vezes,
# esperando 1s, 2s, 4s, 8s entre as tentativas. Sem isso o ADK desiste na primeira.
MODEL = Gemini(
    model=os.getenv("GEMINI_MODEL", "gemini-3.8-flash"),
    retry_options=types.HttpRetryOptions(attempts=5),
)


def buscar_imagens_nasa(termo: str) -> dict:
    """Busca imagens na biblioteca pública da NASA (images.nasa.gov).

    Args:
        termo: O que procurar, em inglês (ex: "saturn", "black hole", "apollo 11").

    Returns:
        Um dict com até 3 imagens, cada uma com titulo, data, descricao e url.
    """
    try:
        resp = requests.get(
            "https://images-api.nasa.gov/search",
            params={"q": termo, "media_type": "image", "page_size": 3},
            timeout=10,
        )
        resp.raise_for_status()
    except requests.RequestException as e:
        return {"erro": f"Falha ao falar com a API da NASA: {e}"}

    imagens = []
    for item in resp.json()["collection"]["items"]:
        info = item["data"][0]
        imagens.append({
            "titulo": info.get("title"),
            "data": info.get("date_created", "")[:10],
            "descricao": info.get("description", "")[:500],
            "url": item["links"][0]["href"] if item.get("links") else None,
        })
    return {"termo": termo, "imagens": imagens}


astronomo = LlmAgent(
    name="astronomo",
    model=MODEL,
    description="Astrônomo que pesquisa imagens reais no acervo da NASA e descreve o que elas mostram.",
    instruction="""Você é um astrônomo da NASA.
Use a ferramenta buscar_imagens_nasa para pesquisar o assunto pedido
(traduza o termo para inglês antes de buscar).
Responda com um resumo técnico curto de cada imagem encontrada: título, data e URL.
Nunca invente dados: use só o que a ferramenta devolver.""",
    tools=[buscar_imagens_nasa],
)

root_agent = LlmAgent(
    name="professor",
    model=MODEL,
    description="Professor que explica astronomia para crianças.",
    instruction="""Você é um professor de ciências animado que explica o espaço para crianças de 10 anos.
Quando o usuário perguntar sobre qualquer coisa do espaço, peça primeiro ao agente
astronomo para pesquisar imagens da NASA sobre o assunto.
Depois explique a resposta dele com palavras simples, uma comparação do dia a dia
e uma curiosidade divertida. Mostre as URLs das imagens no final. Responda em português.""",
    tools=[AgentTool(agent=astronomo)],
)
