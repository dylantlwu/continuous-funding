# Live funding recorder + read-only dashboard for Railway. Build context is the validation/ folder only (see railway.json),
# so nothing outside it (in particular the repository's .env) is ever uploaded.
FROM python:3.12-slim
WORKDIR /app
COPY . /app/validation
ENV PYTHONUNBUFFERED=1 RECORDER_DB=/data/live.sqlite
CMD ["python", "-m", "validation.service"]
