#!/bin/bash
#source ~/dbworkload-env/bin/activate
set -euo pipefail

# ========================
# Configuration
# ========================

#Pick one of the two below to use and uncomment it.
#DOCKER="docker" 
DOCKER="podman"

SCHEMA_DIR="./cockroach-collections-main/molt-bucket"
SCHEMA_FILE="$SCHEMA_DIR/postgres_schema.sql"
CONVERTED_SCHEMA="$SCHEMA_FILE.1"
FETCH_LOG="fetch.log"
VERIFY_LOG="verify.log"

PG_IP="172.27.0.101"
CRDB_IP="172.27.0.102"
MOLT_IP="172.27.0.103"
REP_IP="172.27.0.104"
PG_DSN_MOLT="postgres://admin:secret@pgsql_host:5432/sampledb?sslmode=disable"
CRDB_DSN_MOLT="postgresql://root@crdb_host:26257/defaultdb?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"
CRDB_DSN_STAGING="postgresql://root@crdb_host:26257/_replicator?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"
CRDB_DSN_REPLICATOR="postgresql://root@$CRDB_IP:26257/defaultdb?sslcert=/certs/client.root.crt&sslkey=/certs/client.root.key&sslmode=verify-full&sslrootcert=/certs/ca.pem"
CRDB_DSN_WORKLOAD="postgresql://root@crdb_host:26257/defaultdb?sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key&sslmode=verify-full&sslrootcert=./certs/ca.crt"

pause() {
  echo ""
  read -p "⏸️  Press [Enter] to continue..." 
  echo ""
}

checkcounts() {
 echo "Postgresql count..." 
 $DOCKER exec -it postgres psql -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 echo "Cockroach count..."
 $DOCKER exec -it crdb cockroach sql --certs-dir=./certs/ --host=$CRDB_IP -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
}

verifyprintpretty() {
 cat $VERIFY_LOG | tail -n +2 | jq
}

verify() {
  $DOCKER run --rm -it \
  --name=molt_verify \
  --hostname=molt_verify \
  --ip=$MOLT_IP \
  --net=moltdemo \
  -v "$SCHEMA_DIR:/molt-bucket" \
  -v "./certs:/certs" \
  cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --source "$PG_DSN_MOLT" \
  --target "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable | tee "$VERIFY_LOG"
}

generatedata() {
  #python3 orders_with_retry_fk.py --dsn "$1" --generate --insert --fill
  $DOCKER run --rm --network=moltdemo -v $(pwd):/app order-app --dsn "$1" --generate --insert --fill 
}

# ========================
# --reset option
# ========================
if [[ "${1:-}" == "--reset" ]]; then
  echo "🧹 Resetting environment..."

  echo "🛑 Stopping and removing containers..."
  $DOCKER rm -f postgres 2>/dev/null || true
  $DOCKER rm -f crdb 2>/dev/null || true
  $DOCKER rm -f replicator_forward 2>/dev/null || true
  $DOCKER rm -f replicator_reverse 2>/dev/null || true
  $DOCKER network rm moltdemo 2>/dev/null || true
  rm -f index.txt* serial.txt* ./certs/* 

  echo "🧼 Removing volume and files..."
  $DOCKER volume rm pgdata 2>/dev/null || true
  rm -f ./postgresql.conf ./orders_1m.csv
  rm -f "$SCHEMA_FILE" "$CONVERTED_SCHEMA" "$FETCH_LOG" "$VERIFY_LOG"
  echo "✅ Environment fully reset."
  exit 0
fi

# ========================
# 1. Start Postgres
# ========================
echo "🚀 [1/17] Starting Postgres container..."

echo "Fetching latest docker images..."
$DOCKER pull cockroachdb/molt
$DOCKER pull cockroachdb/replicator
$DOCKER pull cockroachdb/cockroach
$DOCKER network create --driver=bridge --subnet=172.27.0.0/16 --ip-range=172.27.0.0/24 --gateway=172.27.0.1 moltdemo

$DOCKER run --rm -d --name postgres -p 5432:5432 \
  --hostname=pgsql_host \
  --ip=$PG_IP \
  --net=moltdemo \
  -e POSTGRES_USER=admin \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=sampledb \
  -v pgdata:/var/lib/postgresql/data \
  docker.io/library/postgres:15


# ========================
# 2. Configure logical replication
# ========================
echo
echo "🛠️  [2/17] Configuring PostgreSQL for logical replication..."
pause
echo "📤 Copying postgresql.conf from container..."
sleep 5
$DOCKER cp postgres:/var/lib/postgresql/data/postgresql.conf ./postgresql.conf

echo "🔧 Editing WAL settings..."
sed -i '' 's/^#*wal_level.*/wal_level = logical/' ./postgresql.conf
sed -i '' 's/^#*max_replication_slots.*/max_replication_slots = 4/' ./postgresql.conf
sed -i '' 's/^#*max_wal_senders.*/max_wal_senders = 4/' ./postgresql.conf

echo "📥 Copying updated config back and restarting container..."
$DOCKER cp ./postgresql.conf postgres:/var/lib/postgresql/data/postgresql.conf
$DOCKER restart postgres
sleep 5

# ========================
# 3. Validate replication settings
# ========================
echo 
echo "✅ [3/17] Verifying PostgreSQL replication settings..."
pause
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW wal_level;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_replication_slots;"
PGPASSWORD=secret psql -h localhost -U admin -d sampledb -c "SHOW max_wal_senders;"

# ========================
# 4. Populate sample data
# ========================
echo
echo "📦 [4/17] Inserting test orders into Postgres..."
pause
generatedata "$PG_DSN_MOLT"

# ========================
# 5. Dump schema from Postgres
# ========================
echo
echo "📄 [5/17] Dumping schema to $SCHEMA_FILE..."
pause
mkdir -p "$SCHEMA_DIR"
$DOCKER exec -i postgres pg_dump -U admin -d sampledb --schema-only -t orders -t order_fills > "$SCHEMA_FILE"

# ========================
# 6. Create CockroachDB Certificates
# ========================
echo
echo "🪵 [6/17] Creating CockroachDB certificates..."
pause
rm -f index.txt* serial.txt* ./certs/*
openssl genrsa -out ./certs/ca.key 2048
openssl req -new -x509 -config ca.cnf -key ./certs/ca.key -out ./certs/ca.crt -days 365 -batch
touch index.txt
echo '02' > serial.txt
openssl genrsa -out certs/node.key 2048
openssl req -new -config node.cnf -key ./certs/node.key -out ./certs/node.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_node_req -out ./certs/node.crt -outdir ./certs/ -in ./certs/node.csr -batch
openssl x509 -in ./certs/node.crt -text | grep "X509v3 Subject Alternative Name" -A 1
openssl genrsa -out ./certs/client.root.key 2048
openssl req -new -config client.cnf -key ./certs/client.root.key -out ./certs/client.root.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_client_req -out ./certs/client.root.crt -outdir ./certs/ -in ./certs/client.root.csr -batch
openssl x509 -in ./certs/ca.crt -out ./certs/ca.pem -outform PEM

# ========================
# 7. Start CockroachDB
# ========================
echo
echo "🪵 [7/17] Starting CockroachDB container..."
pause
$DOCKER run -d -v "./certs:/cockroach/certs" --net=moltdemo --ip=$CRDB_IP --hostname=crdb_host --env COCKROACH_DATABASE=defaultdb --env COCKROACH_USER=root --env COCKROACH_PASSWORD=password --name=crdb -p 26257:26257 -p 8080:8080 cockroachdb/cockroach start-single-node --http-addr=crdb:8080
sleep 5

until $DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SELECT 1;" &>/dev/null; do
  echo "⏳ Waiting for CockroachDB to become ready..."
  sleep 2
done
$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SET CLUSTER SETTING kv.rangefeed.enabled=true;"
$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "CREATE DATABASE staging;"

# ========================
# 8. Convert schema with molt
# ========================
echo
echo "🔁 [8/17] Converting schema for CockroachDB using molt..."
pause
$DOCKER run --rm \
  -v "$SCHEMA_DIR:/molt-data" \
  -v "./certs:/certs" \
  --net=moltdemo \
  --hostname=molt_convert \
  --ip=$MOLT_IP \
  cockroachdb/molt convert postgres \
  --schema /molt-data/postgres_schema.sql \
  --url "$CRDB_DSN_MOLT"

echo "Inspect the converted schema..."
pause
echo
grep "error" cockroach-collections-main/molt-bucket/postgres_schema.sql.1 -A 9
echo
echo "CockroachDB does not support \restrict and \unrestrict... comment those items out..."
pause
sed -i '' 's/^\\restrict/-- &/' ./cockroach-collections-main/molt-bucket/postgres_schema.sql.1
sed -i '' 's/^\\unrestrict/-- &/' ./cockroach-collections-main/molt-bucket/postgres_schema.sql.1


# ========================
# 9. Apply schema to CockroachDB
# ========================
echo
echo "📥 [9/17] Applying converted schema to CockroachDB..."
pause
$DOCKER exec -i crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ < "$CONVERTED_SCHEMA"

# ========================
# 10. Verify CockroachDB schema
# ========================
echo
echo "🔍 [10/17] Verifying CockroachDB schema..."
pause
$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "SHOW CREATE ALL TABLES;"
pause
echo "Checking counts between postgres and CRDB..."
echo "Postgres should have data in it and CRDB should not, as no transfer has occurred yet."
checkcounts

# ========================
# 11. Run molt fetch 
# ========================
echo
echo "🚚 [11/17] Running molt fetch..."
pause
$DOCKER run --rm -it \
  --name=molt_fetch \
  --net=moltdemo \
  --ip=$MOLT_IP \
  --hostname=molt_fetch \
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

# ========================
# 12. Run molt verify to compare the source data and CRDB data (any activity since the data load was done will result in false differences)... 
# ========================
echo
echo "🚚 [12/17] Running molt verify to compare the source data and CRDB data (any activity since the data load was done will result in false differences)..."
pause
$DOCKER run --rm -it \
  --name=molt_verify \
  --hostname=molt_verify \
  --ip=$MOLT_IP \
  --net=moltdemo \
  -v "$SCHEMA_DIR:/molt-bucket" \
  -v "./certs:/certs" \
  cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --source "$PG_DSN_MOLT" \
  --target "$CRDB_DSN_MOLT" \
  --allow-tls-mode-disable | tee "$VERIFY_LOG"

echo
echo "Pretty print MOLT Verify output..."
echo
cat $VERIFY_LOG | tail -n +2 | jq

echo
echo "Checking counts between postgres and CRDB..."
echo "Postgres should have data in it and CRDB should have the same count as long as no new data has been generated since the fetch."
pause
checkcounts

# ========================
# 13. Populate sample data
# ========================
echo
echo "📦 [13/17] Running workload that puts data into Postgres..."
pause
generatedata "$PG_DSN_MOLT"

echo
echo "Checking counts between postgres and CRDB..."
echo "Postgres should have more data in it than CRDB, as replication has not been started yet."
checkcounts

# ========================
# 14. Run replicator for replication... 
# ========================
echo
echo "🚚 [14/17] Running replication with replicator..."
pause
$DOCKER run \
  -d \
  --name=replicator_forward \
  --hostname=replicator \
  --ip=$REP_IP \
  --net=moltdemo \
  -v "./certs:/certs" \
  cockroachdb/replicator \
  pglogical \
  -v \
  --stagingCreateSchema \
  --targetSchema defaultdb.public \
  --sourceConn "$PG_DSN_MOLT" \
  --targetConn "$CRDB_DSN_REPLICATOR" \
  --slotName replication_slot \
  --publicationName molt_fetch

sleep 10

echo
echo "View MOLT Replicator log output..."
echo "Checking counts between postgres and CRDB..."
echo "Once replication has caught up, both Postgres and CRDB should have the same counts..."
checkcounts

echo
echo "Running molt verify to compare the source data and CRDB data (any activity since the last set of data was loaded will result in false differences)..."
pause
verify

echo
echo "Pretty print MOLT Verify output..."
pause
verifyprintpretty

# ========================
# 15. Stop app
# ========================
echo
echo "[15/17] Stop the workload generating data if it is still running."
pause
echo 'Prepare for scheduled downtime.  Here you would stop the application connecting to pgsql and let the replication from pgsql->crdb complete with any last rows.'

# ========================
# 16. Start MOLT in failback mode
# ========================
echo
echo "[16/17] Continue to start MOLT in failback mode."
pause

openssl genrsa -out ./certs/ca-rep.key 2048
openssl req -new -x509 -config ca.cnf -key ./certs/ca-rep.key -out ./certs/ca-rep.crt -days 365 -batch
openssl genrsa -out certs/node-rep.key 2048
openssl req -new -config rep.cnf -key ./certs/node-rep.key -out ./certs/node-rep.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca-rep.key -cert ./certs/ca-rep.crt -policy signing_policy -extensions signing_node_req -out ./certs/node-rep.crt -outdir ./certs/ -in ./certs/node-rep.csr -batch
openssl x509 -in ./certs/node-rep.crt -text | grep "X509v3 Subject Alternative Name" -A 1

#REP_NODE_CERT_BASE64_URL_ENCODED=$(base64 -i ./certs/node-rep.crt | jq -R -r '@uri')
#REP_NODE_KEY_BASE64_URL_ENCODED=$(base64 -i ./certs/node-rep.key | jq -R -r '@uri')
#CA_CERT_BASE64_URL_ENCODED=$(base64 -i ./certs/ca-rep.crt | jq -R -r '@uri')
#echo
#echo 'TLS/endpoint certificate base64-encoded and URL-encoded:'
#echo $REP_NODE_CERT_BASE64_URL_ENCODED
#echo 'TLS/endpoint key base64-encoded and URL-encoded:'
#echo $REP_NODE_KEY_BASE64_URL_ENCODED
#echo 'TLS/endpoint key base64-encoded and URL-encoded:'
#echo $CA_CERT_BASE64_URL_ENCODED

echo
echo "Begin of minimal downtime"
echo "Stopping Replicator forward migration"
$DOCKER stop replicator_forward
pause

echo
echo 'Start MOLT Replicator for the reverse migration'
pause

$DOCKER run \
 -d \
 --name=replicator_reverse \
 --hostname=replicator \
 --ip=$REP_IP \
 --net=moltdemo \
 -p 30004:30004 \
 -v ./certs:/certs \
 cockroachdb/replicator \
  start \
  -v \
  --stagingCreateSchema \
  --stagingSchema _replicator \
  --bindAddr :30004 \
  --metricsAddr :30005 \
  --targetConn "$PG_DSN_MOLT" \
  --stagingConn "$CRDB_DSN_STAGING" \
  --tlsCertificate /certs/node-rep.crt \
  --tlsPrivateKey /certs/node-rep.key 
  #--tlsSelfSigned

echo
echo "Replicator logs"
pause
$DOCKER logs replicator_reverse

echo
echo "Create JWT auth token"
pause
openssl ecparam -out ./certs/ec.key -genkey -name prime256v1
openssl ec -in ./certs/ec.key -pubout -out ./certs/ec.pub
ECPUB=`cat ./certs/ec.pub`

$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "truncate table _replicator.jwt_public_keys;"
$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "INSERT INTO _replicator.jwt_public_keys (public_key) VALUES (
'$ECPUB'
);"
$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "select * from _replicator.jwt_public_keys;"

$DOCKER run \
 -v ./certs:/certs \
 cockroachdb/replicator \
  make-jwt \
  -k /certs/ec.key \
  -a sampledb.public \
  -o /certs/out.jwt
JWT=`cat ./certs/out.jwt`

echo 
echo "Restarting replicator_reverse to read the new keys."
$DOCKER restart replicator_reverse
sleep 5


echo
echo 'Get the CockroachCB cluster logical timestamp for the changefeed cursor parameter'
pause

CLUSTER_LOGICAL_TIMESTAMP=$($DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ --format csv -e "SELECT cluster_logical_timestamp();" | tail -n -1)

echo
echo "Cluster logical timestamp: $CLUSTER_LOGICAL_TIMESTAMP"

openssl s_client -connect localhost:30004 \
  -servername $REP_IP -showcerts </dev/null \
  | awk '/BEGIN CERTIFICATE/{flag=1} flag; /END CERTIFICATE/{print; exit}' \
  > ./certs/replicator-leaf.pem

CA_B64=$(base64 -w0 -i ./certs/replicator-leaf.pem)

echo
echo 'Create changefeed to MOLT Replicator'
pause

# for pgsql/crdb sources, for failback, you need to include the schema as part of the URI
$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "CREATE CHANGEFEED FOR TABLE orders, order_fills
 INTO 'webhook-https://$REP_IP:30004/sampledb/public?ca_cert=$CA_B64' 
 WITH updated, 
      resolved = '250ms', 
      min_checkpoint_frequency = '250ms', 
      initial_scan = 'no', 
      cursor = '$CLUSTER_LOGICAL_TIMESTAMP', 
      webhook_sink_config = '{\"Flush\":{\"Bytes\":1048576,\"Frequency\":\"1s\"}}', \
      webhook_auth_header = 'Bearer $JWT';"

echo
echo "Display logs for replicator_reverse..."
pause
$DOCKER logs replicator_reverse

echo
echo "Check the counts between postgres and CRDB.  They should be the same."
pause
checkcounts

echo
echo "Reverse replication is set up"
echo "Then you would configure the application to connect to crdb and start it up."
echo "Perform your final go/no-go tests."
echo
echo "End of downtime."
echo
echo "Migration complete to CRDB."
pause

echo
echo 'Show reverse replication is working by inserting data into CRDB.'
pause
generatedata "$CRDB_DSN_WORKLOAD"
pause

echo "Sleep 10 seconds to let the change propagate to postgres."
sleep 10

echo "Checking counts between postgres and CRDB..."
pause
checkcounts

echo
echo 'Look at MOLT Replicator logs again.'
pause

$DOCKER logs replicator_reverse


# ========================
# 17. Done
# ========================
echo
echo "🎉 [17/17] Pipeline complete!"

