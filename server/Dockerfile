FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8003
# Shell form (not exec-form array) so ${PORT} actually expands — lets a
# compose file override the listen port without a rebuild, same as
# ios-bridge's PORT env var.
CMD uvicorn main:app --host 0.0.0.0 --port ${PORT:-8003}
