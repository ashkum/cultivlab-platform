# services/founder-console/Dockerfile
# CultivLab Founder Console — FastAPI + HTMX operator dashboard.
#
# Build:  docker build -t cultivlab-founder-console services/founder-console/
# Run:    docker compose up -d founder-console   (via infra/docker-compose.yml)

FROM python:3.12-slim

WORKDIR /app

# Install deps first so layer is cached unless requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bundle HTMX locally — avoids CDN dependency + SRI mismatch in browsers
RUN mkdir -p /app/static && \
    python -c "import urllib.request; urllib.request.urlretrieve('https://unpkg.com/htmx.org@1.9.12/dist/htmx.min.js', '/app/static/htmx.min.js')"

COPY app/ ./app/

EXPOSE 8080

# Uvicorn: single worker is fine for the solo-founder audience.
# LOG_LEVEL info keeps logs readable in docker compose logs.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
