#!/bin/bash
#source ~/dbworkload-env/bin/activate
set -euo pipefail


# podman run --rm --network=host -v $(pwd):/app order-app --dsn "$PG_DSN" --generate --insert --fill 


# ========================
# Configuration
# ========================
SCHEMA_DIR="/Users/lukens/Downloads/MOLT_demo_fromPG_toCRDB_withMOapp/cockroach-collections-main/molt-bucket"
SCHEMA_FILE="$SCHEMA_DIR/postgres_schema.sql"
CONVERTED_SCHEMA="$SCHEMA_FILE.1"
FETCH_LOG="$SCHEMA_DIR/fetch.log"

PG_DSN="postgres://admin:secret@localhost:5432/sampledb"
PG_DSN_MOLT="postgres://admin:secret@host.docker.internal:5432/sampledb?sslmode=disable"
CRDB_DSN_MOLT="postgresql://root@host.docker.internal:26257/defaultdb?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"

pause() {
  echo ""
  read -p "⏸️  Press [Enter] to continue to the next step..." _
  echo ""
}

# ========================
# --reset option
# ========================
if [[ "${1:-}" == "--reset" ]]; then
  echo "🧹 Resetting environment..."

  echo "🛑 Stopping and removing containers..."
  podman rm -f postgres 2>/dev/null || true
  podman rm -f crdb 2>/dev/null || true
  rm -f index.txt* serial.txt* ./certs/*

  echo "🧼 Removing volume and files..."
  podman volume rm pgdata 2>/dev/null || true
  rm -f ./postgresql.conf
  rm -f "$SCHEMA_FILE" "$CONVERTED_SCHEMA" "$FETCH_LOG"
  echo "✅ Environment fully reset."
  exit 0
fi

# ========================
# 1. Start Postgres
# ========================
echo "🚀 [1/14] Starting Postgres container..."
podman run --rm -d --name postgres -p 5432:5432 \
  -e POSTGRES_USER=admin \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=sampledb \
  -v pgdata:/var/lib/postgresql/data \
  docker.io/library/postgres:15
echo "Configure logical replication Next..."
pause

# ========================
# 2. Configure logical replication
# ========================
echo "🛠️  [2/14] Configuring PostgreSQL for logical replication..."

echo "📤 Copying postgresql.conf from container..."
sleep 5
podman cp postgres:/var/lib/postgresql/data/postgresql.conf ./postgresql.conf

echo "🔧 Editing WAL settings..."
sed -i '' 's/^#*wal_level.*/wal_level = logical/' ./postgresql.conf
sed -i '' 's/^#*max_replication_slots.*/max_replication_slots = 4/' ./postgresql.conf
sed -i '' 's/^#*max_wal_senders.*/max_wal_senders = 4/' ./postgresql.conf

echo "📥 Copying updated config back and restarting container..."
podman cp ./postgresql.conf postgres:/var/lib/postgresql/data/postgresql.conf
podman restart postgres
sleep 5
echo " Validate replication settings Next..."
pause

# ========================
# 3. Validate replication settings
# ========================
echo "✅ [3/14] Verifying PostgreSQL replication settings..."
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW wal_level;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_replication_slots;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_wal_senders;"
echo " Populate sample data into PG database Next..."
pause

# ========================
# 4. Populate sample data
# ========================
echo "📦 [4/14] Inserting test orders into Postgres..."
python3 orders_with_retry_fk.py --dsn "$PG_DSN" --generate --insert --fill
echo "Dump schema from Postgres for CRDB target Next..."
pause

# ========================
# 5. Dump schema from Postgres
# ========================
echo "📄 [5/14] Dumping schema to $SCHEMA_FILE..."
mkdir -p "$SCHEMA_DIR"
podman exec -i postgres pg_dump -U admin -d sampledb --schema-only -t orders -t order_fills > "$SCHEMA_FILE"
echo "Starting CockroachDB container Next..."
pause

# ========================
# 6. Create CockroachDB Certificates
# ========================
echo "🪵 [6/14] Creating CockroachDB certificates..."
rm -f index.txt* serial.txt* ./certs/*
openssl genrsa -out ./certs/ca.key 2048
openssl req -new -x509 -config ca.cnf -key ./certs/ca.key -out ./certs/ca.crt -days 365 -batch
touch index.txt
echo '01' > serial.txt
openssl genrsa -out certs/node.key 2048
openssl req -new -config node.cnf -key ./certs/node.key -out ./certs/node.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_node_req -out ./certs/node.crt -outdir ./certs/ -in ./certs/node.csr -batch
openssl x509 -in ./certs/node.crt -text | grep "X509v3 Subject Alternative Name" -A 1
openssl genrsa -out ./certs/client.root.key 2048
openssl req -new -config client.cnf -key ./certs/client.root.key -out ./certs/client.root.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_client_req -out ./certs/client.root.crt -outdir ./certs/ -in ./certs/client.root.csr -batch
pause

# ========================
# 7. Start CockroachDB
# ========================
echo "🪵 [7/14] Starting CockroachDB container..."
podman run -d -v "./certs:/cockroach/certs" --env COCKROACH_DATABASE=defaultdb --env COCKROACH_USER=root --env COCKROACH_PASSWORD=password --name=crdb -p 26257:26257 -p 8080:8080 cockroachdb/cockroach start-single-node --http-addr=crdb:8080
sleep 5

until podman exec crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SELECT 1;" &>/dev/null; do
  echo "⏳ Waiting for CockroachDB to become ready..."
  sleep 2
done
podman exec crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SET CLUSTER SETTING kv.rangefeed.enabled=true;" 

echo "Converting schema for CockroachDB using molt, apply to CRDB and Verify  Next..."
pause

# ========================
# 8. Convert schema with molt
# ========================
echo "🔁 [8/14] Converting schema for CockroachDB using molt..."
podman run --rm \
  -v "$SCHEMA_DIR:/molt-data" \
  -v "./certs:/certs" \
  cockroachdb/molt convert postgres \
  --schema /molt-data/postgres_schema.sql \
  --url "$CRDB_DSN_MOLT"
#pause

# ========================
# 9. Apply schema to CockroachDB
# ========================
echo "📥 [9/14] Applying converted schema to CockroachDB..."
podman exec -i crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ < "$CONVERTED_SCHEMA"
#pause

# ========================
# 10. Verify CockroachDB schema
# ========================
echo "🔍 [10/14] Verifying CockroachDB schema..."
podman exec -it crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SHOW CREATE ALL TABLES;"
echo "Run molt fetch with replication Next in Continous mode , in new window run order-app --dsn $PG_DSN --generate --insert --fill"
echo "Run SQL counts in source and target"
pause

# ========================
# 11. Run molt fetch with replication
# ========================
echo "🚚 [11/14] Running molt fetch with data + replication..."
podman run --rm -it \
  -v "$SCHEMA_DIR:/molt-bucket" \
  -v "./certs:/certs" \
  cockroachdb/molt \
  fetch \
  --source "$PG_DSN_MOLT" \
  --target "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable \
  --table-handling truncate-if-exists \
  --direct-copy \
  --pglogical-replication-slot-name replication_slot \
  --mode data-load-and-replication \
  --logging=debug --replicator-flags "-v" | tee "$FETCH_LOG"
pause

# ========================
# 12. Stop app
# ========================
echo "[12/14] Stop the app if still running."
pause

# ========================
# 13. Start MOLT in failback mode
# ========================
echo "[13/14] Continue to start MOLT in failback mode."
pause

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

pause

# ========================
# 14. Done
# ========================
echo "🎉 [14/14] Pipeline complete!"

