FROM python:3.12-slim

WORKDIR /app

# curl is required by this image's docker-compose healthcheck (CMD curl -f
# http://localhost:8004/health) -- python:3.12-slim doesn't ship it, which
# left the container permanently stuck in "starting"/"unhealthy" even once
# the app itself was serving fine.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8003
# Shell form (not exec-form array) so ${PORT} actually expands — lets a
# compose file override the listen port without a rebuild, same as
# ios-bridge's PORT env var.
#
# 127.0.0.1, not 0.0.0.0: this only runs under network_mode: host and is
# reached externally solely via the Cloudflare tunnel connecting to
# 127.0.0.1:8004 (~/.cloudflared/upscaler-bridge-ingress.yml) -- binding all
# interfaces was unnecessary direct exposure alongside the tunnel path.
CMD uvicorn main:app --host 127.0.0.1 --port ${PORT:-8003}
