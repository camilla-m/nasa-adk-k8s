FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agents/ ./agents/

# `adk web` serve a interface de chat (/dev-ui) e a API REST na mesma porta.
# --allow_origins: o ADK recusa (403) chamadas vindas de outro endereço; o Web
# Preview do Cloud Shell abre a página em https://8080-....cloudshell.dev.
EXPOSE 8080
CMD ["adk", "web", "--host", "0.0.0.0", "--port", "8080", \
     "--allow_origins", "regex:https://.*\\.cloudshell\\.dev", "agents"]
