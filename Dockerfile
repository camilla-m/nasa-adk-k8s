FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agents/ ./agents/

# `adk web` serve a interface de chat (/dev-ui) e a API REST na mesma porta.
EXPOSE 8080
CMD ["adk", "web", "--host", "0.0.0.0", "--port", "8080", "agents"]
