FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y gcc libpq-dev && \
    pip install --no-cache-dir psycopg2-binary && \
    apt-get remove -y gcc && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

COPY . /app

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "orders_with_retry_fk.py"]

