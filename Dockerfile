FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir psycopg2-binary

COPY . /app

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "orders_with_retry_fk.py"]

