# 📦 Postgres to CockroachDB Migration of Replicated Order Pipeline Demo


This project demonstrates a full PostgreSQL → CockroachDB replication pipeline using [`molt`](https://github.com/cockroachdb/molt), with real-time logical replication of order data.  Many thanks to Arun Sankaranarayanan for help with failback authentication.

---

## 📁 Project Files

| Filename                | Description                                                                |
|------------------------|----------------------------------------------------------------------------|
| `orders_with_retry_fk.py` | Python script to generate, insert, and fill order data into PostgreSQL     |
| `full_pipeline.sh`       | Full setup pipeline script: configures Postgres, converts schema, runs MOLT |
| `Dockerfile`              | Image definition for a container that runs `orders_with_retry_fk.py`        |

---

## 🚀 Quick Start

### 1. 🛠 Prerequisites

Make sure you have the following installed:

- 🐍 Python 3.x with `venv` and required packages
- 🐘 `podman` or `docker`
- 🪳 `cockroachdb/cockroach` container image
- 🧬 `cockroachdb/molt` container image
- 🐓 `postgres` container image

> 💡 This guide uses `podman`, but Docker users can adapt commands as needed.

---
### 2. 🐘 Build the sample order container
`% podman build -t order-app:latest .`

This will create a container for order-app.


### 3. 🔄 Run the Full Pipeline

```bash
chmod +x full_pipeline.sh
./full_pipeline.sh
```

The script will:

Start PostgreSQL
Enable logical replication
Generate and insert order data
Dump and convert schema
Start CockroachDB
Apply schema and remove foreign keys
Start MOLT replication
Failback to PostgreSQL
⚠️ The script will pause at each step and wait for you to press [Enter] to continue. Use this time to inspect output, logs, or states.

```bash
./full_pipeline.sh --reset
```

This will reset the environment, clean up containers, remove logs, remove data, remove certificates, etc.



Information below is old and kept for reference.....

###4. 🔁 Start the Live Replication Console
When the script reaches Step 10, open a new terminal in the same directory and run:

export PG_DSN="postgresql://admin:secret@localhost:5432/sampledb"

podman run --rm --network=host \
  -v $(pwd):/app order-app \
  --dsn "$PG_DSN" \
  --generate --insert --fill
This simulates continuous order activity and real-time replication into CockroachDB.




🧪 Test Replication Latency

Run this in the CockroachDB SQL shell to inspect replication latency:

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

AND on SOURCE

podman exec -it postgres psql -U admin -d sampledb -c "SELECT
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 order_fills_count | orders_count |         current_time          
-------------------+--------------+-------------------------------
            100363 |       110000 | 2025-06-06 04:33:54.951227+00



###CHECK COUNTS
 podman exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=host.docker.internal -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"

### 5. Stop the app running against postgres

### 6. Stop molt

### 7. Start molt going from crdb to postgres

export PG_DSN_MOLT="postgres://admin:secret@host.docker.internal:5432/sampledb?sslmode=disable"
export CRDB_DSN_MOLT="postgresql://root@host.docker.internal:26257/defaultdb?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"

podman run --rm -it \
  -v "./certs:/certs" \
  -v "./failback.json:/failback.json" \
  -p 30005:30005 \
  cockroachdb/molt \
  fetch \
  --target "$PG_DSN_MOLT" \
  --source "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable \
  --table-handling none \
  --mode failback \
  --changefeeds-path '/failback.json' \
  --logging=debug --replicator-flags "-v --tlsSelfSigned --disableAuthentication" | tee "$FETCH_LOG"

### 8. Start the app running against crdb and show data flowing to pgsql

podman run --rm --network=host \
  -v $(pwd):/app -v "./certs:/certs" order-app \
  --dsn "$CRDB_DSN_MOLT" \
  --generate --insert --fill

### 9. 🔁 Reset the Environment

To completely clean up and restart:

./full_pipeline.sh --reset
This will:

Stop and remove all containers
Delete schema files and replication artifacts
Reset your environment to a fresh state


📝 Notes

The script checks for and activates your Python virtual environment.
MOLT requires WAL-level logical replication.
The foreign key in CockroachDB is removed to allow safe truncation.



