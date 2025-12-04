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
FETCH_LOG="fetch.log"
VERIFY_LOG="verify.log"

PG_DSN="postgres://admin:secret@localhost:5432/sampledb"
PG_DSN_MOLT="postgres://admin:secret@host.docker.internal:5432/sampledb?sslmode=disable"
CRDB_DSN_MOLT="postgresql://root@host.docker.internal:26257/defaultdb?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"
CRDB_DSN_REPLICATOR="postgresql://root@host.docker.internal:26257/defaultdb?sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key&sslmode=verify-full&sslrootcert=./certs/ca.pem"

echo "Fetching latest docker images..."
podman pull cockroachdb/molt
podman pull cockroachdb/replicator

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
  rm -f "$SCHEMA_FILE" "$CONVERTED_SCHEMA" "$FETCH_LOG" "$VERIFY_LOG"
  echo "✅ Environment fully reset."
  exit 0
fi

# ========================
# 1. Start Postgres
# ========================
echo "🚀 [1/17] Starting Postgres container..."
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
echo "🛠️  [2/17] Configuring PostgreSQL for logical replication..."

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
echo "✅ [3/17] Verifying PostgreSQL replication settings..."
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW wal_level;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_replication_slots;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_wal_senders;"
echo " Populate sample data into PG database Next..."
pause

# ========================
# 4. Populate sample data
# ========================
echo "📦 [4/17] Inserting test orders into Postgres..."
python3 orders_with_retry_fk.py --dsn "$PG_DSN" --generate --insert --fill
echo "Dump schema from Postgres for CRDB target Next..."
pause

# ========================
# 5. Dump schema from Postgres
# ========================
echo "📄 [5/17] Dumping schema to $SCHEMA_FILE..."
mkdir -p "$SCHEMA_DIR"
podman exec -i postgres pg_dump -U admin -d sampledb --schema-only -t orders -t order_fills > "$SCHEMA_FILE"
echo "Starting CockroachDB container Next..."
pause

# ========================
# 6. Create CockroachDB Certificates
# ========================
echo "🪵 [6/17] Creating CockroachDB certificates..."
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
openssl x509 -in ./certs/ca.crt -out ./certs/ca.pem -outform PEM

pause

# ========================
# 7. Start CockroachDB
# ========================
echo "🪵 [7/17] Starting CockroachDB container..."
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
echo "🔁 [8/17] Converting schema for CockroachDB using molt..."
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
echo "📥 [9/17] Applying converted schema to CockroachDB..."
podman exec -i crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ < "$CONVERTED_SCHEMA"
#pause

# ========================
# 10. Verify CockroachDB schema
# ========================
echo "🔍 [10/17] Verifying CockroachDB schema..."
podman exec -it crdb cockroach sql --host=127.0.0.1 --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SHOW CREATE ALL TABLES;"
echo "Run molt fetch with replication Next in Continous mode , in new window run order-app --dsn $PG_DSN --generate --insert --fill"
echo "Run SQL counts in source and target"
pause

echo "Checking counts between postgres and CRDB..."
echo "Postgres should have data in it and CRDB should not, as no transfer has occurred yet."
 podman exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=host.docker.internal -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"

# ========================
# 11. Run molt fetch 
# ========================
echo "🚚 [11/17] Running molt fetch..."
podman run --rm -it \
  --name=molt_fetch
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
  --mode data-load \
  --logging=debug --replicator-flags "-v" | tee "$FETCH_LOG"

echo "Getting the CDC Cursor for late use with Replicator so we can begin streaming from the correct timestamp."

CDC_CURSOR=$(grep cdc_cursor $FETCH_LOG | head -n 1 | sed 's/.*cdc_cursor":"//' | sed 's/".*//')
echo "CDC timestamp: $CDC_CURSOR"
pause

# ========================
# 12. Run molt verify to compare the source data and CRDB data (any activity since the data load was done will result in false differences)... 
# ========================
echo "🚚 [12/17] Running molt verify to compare the source data and CRDB data (any activity since the data load was done will result in false differences)..."
podman run --rm -it \
  --name=molt_verify \
  -v "$SCHEMA_DIR:/molt-bucket" \
  -v "./certs:/certs" \
  cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --source "$PG_DSN_MOLT" \
  --target "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable | tee "$VERIFY_LOG"
pause

echo "Pretty print MOLT Verify output..."
pause
cat $VERIFY_LOG | tail -n +2 | jq
pause
echo "Checking counts between postgres and CRDB..."
echo "Postgres should have data in it and CRDB should have the same count as long as no new data has been generated since the fetch."
 podman exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=host.docker.internal -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"

# ========================
# 13. Populate sample data
# ========================
echo "📦 [13/17] Running workload that puts data into Postgres..."
python3 orders_with_retry_fk.py --dsn "$PG_DSN" --generate --insert --fill
pause

echo "Checking counts between postgres and CRDB..."
echo "Postgres should have more data in it than CRDB, as replication has not been started yet."
 podman exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=host.docker.internal -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"

# ========================
# 14. Run replicator for replication... 
# ========================
echo "🚚 [14/17] Running replication with replicator..."
podman run \
  -d \
  --name=replicator_forward \
  -v "./certs:/certs" \
  cockroachdb/replicator \
  pglogical \
  -v \
  --stagingCreateSchema \
  --targetSchema defaultdb.public \
  --sourceConn "$PG_DSN_MOLT" \
  --targetConn "$CRDB_DSN_REPLICATOR" \
  --slotName replication_slot \
  --publicationName alltables

sleep 3

echo "View MOLT Replicator log output..."
pause
podman logs replicator_forward
pause
echo "Checking counts between postgres and CRDB..."
echo "Once replication has caught up, both Postgres and CRDB should have the same counts..."
 podman exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 podman exec -it crdb cockroach sql --certs-dir=./certs/ --host=host.docker.internal -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
pause

echo "Running molt verify to compare the source data and CRDB data (any activity since the last set of data was loaded will result in false differences)..."
podman run --rm -it \
  --name=molt_verify \
  -v "$SCHEMA_DIR:/molt-bucket" \
  -v "./certs:/certs" \
  cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --source "$PG_DSN_MOLT" \
  --target "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable | tee "$VERIFY_LOG"
pause
echo "Pretty print MOLT Verify output..."
pause
cat $VERIFY_LOG | tail -n +2 | jq
pause

# ========================
# 15. Stop app
# ========================
echo "[15/17] Stop the workload generating data if it is still running."
pause

# ========================
# 16. Start MOLT in failback mode
# ========================
echo "[16/17] Continue to start MOLT in failback mode."
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
# 17. Done
# ========================
echo "🎉 [17/17] Pipeline complete!"

