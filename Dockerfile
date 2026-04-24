FROM python:3.12-slim

WORKDIR /app

# curl is used by the Docker/Podman healthcheck
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Borrow the uv binary from the official image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install dependencies first (layer-cached until lockfile changes)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY main.py .

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
