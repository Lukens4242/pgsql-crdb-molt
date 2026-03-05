# Postgres to CockroachDB Migration of Replicated Order Pipeline Demo


This project demonstrates a full PostgreSQL to CockroachDB replication pipeline using [`molt`](https://github.com/cockroachdb/molt), with real-time logical replication of order data.  Many thanks to Arun Sankaranarayanan for help with failback authentication.

---

## Project Files

| Filename                          | Description                                                                 |
|-----------------------------------|-----------------------------------------------------------------------------|
| `orders_with_retry_fk.py`        | Python script to generate, insert, and fill order data into PostgreSQL      |
| `full_pipeline.sh`               | Full setup pipeline script: configures Postgres, converts schema, runs MOLT |
| `demo_molt_postgres_preload_images.sh` | Pre-pulls container images to avoid delays during the demo            |
| `Dockerfile`                      | Image definition for a container that runs `orders_with_retry_fk.py`        |

---

## Quick Start

### 1. Prerequisites

Make sure you have the following installed:

- Python 3.x with `venv` and required packages
- `podman` or `docker`
- `cockroachdb/cockroach` container image
- `cockroachdb/molt` container image
- `postgres` container image

> This guide uses `podman` by default, but Docker is fully supported via the `--docker` flag.

---
### 2. Build the sample order container
```bash
podman build -t order-app:latest .
```

This will create a container for order-app.


### 3. Run the Full Pipeline

```bash
chmod +x full_pipeline.sh
./full_pipeline.sh
```

The script will:

- Start PostgreSQL
- Enable logical replication
- Generate and insert order data
- Dump and convert schema
- Start CockroachDB
- Apply schema and remove foreign keys
- Start MOLT replication
- Set up failback to PostgreSQL

The script will pause at each step and wait for you to press [Enter] to continue. Use this time to inspect output, logs, or states.

#### Pipeline flags

| Flag              | Description                                      |
|-------------------|--------------------------------------------------|
| `--docker`        | Use `docker` as the container runtime             |
| `--podman`        | Use `podman` as the container runtime (default)   |
| `--nopause`, `-n` | Skip interactive pauses between stages            |
| `--skipto N`, `-s N` | Skip ahead to stage N                          |
| `--width N`, `-w N`  | Set text wrapping width (default: 80)           |
| `--reset`, `-r`   | Reset the environment (see below)                 |

#### Pre-pull images (optional)

To avoid delays during the demo, pre-pull images first:

```bash
# Uses docker by default; set DOCKER=podman to use podman
DOCKER=podman bash demo_molt_postgres_preload_images.sh
```

#### Reset the environment

```bash
./full_pipeline.sh --reset
```

This will:

- Stop and remove all containers
- Delete schema files and replication artifacts
- Reset your environment to a fresh state

---

## Test Replication Latency

Run this in the CockroachDB SQL shell to inspect replication latency:

```sql
WITH latency_roll AS (
    SELECT
        ROUND(EXTRACT(EPOCH FROM (
            crdb_internal.approximate_timestamp(crdb_internal_mvcc_timestamp) - fill_time
        )), 0) AS latency_seconds,
        COUNT(1) AS count
    FROM public.order_fills
    WHERE fill_time > NOW() - INTERVAL '60 minutes'
    GROUP BY latency_seconds
)
SELECT
    latency_seconds,
    COUNT(*)
FROM latency_roll
ORDER BY latency_seconds;
```

## Check Row Counts

On PostgreSQL:
```bash
podman exec -it postgres psql -U admin -d sampledb -c "SELECT
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
```

On CockroachDB:
```bash
podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=172.27.0.102 -e "SELECT
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
```

---

## Notes

- The pipeline uses a custom bridge network (`moltdemo`, subnet `172.27.0.0/16`) with fixed container IPs. Manual commands in this README use the same network addresses.
- MOLT requires WAL-level logical replication.
- The `order_fills` table intentionally omits a foreign key on `order_id` to allow safe truncation during replication.
- All credentials and TLS-disable flags in this project are for local demo purposes only. Use proper secrets management and TLS in production.
