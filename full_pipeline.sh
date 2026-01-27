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
TEXT_WIDTH="80"
TOTALSTAGES="24"

PG_IP="172.27.0.101"
CRDB_IP="172.27.0.102"
MOLT_IP="172.27.0.103"
REP_IP="172.27.0.104"
PG_DSN_MOLT="postgres://admin:secret@pgsql_host:5432/sampledb?sslmode=disable"
CRDB_DSN_MOLT="postgresql://root@crdb_host:26257/defaultdb?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"
CRDB_DSN_STAGING="postgresql://root@crdb_host:26257/_replicator?sslcert=%2Fcerts%2Fclient.root.crt&sslkey=%2Fcerts%2Fclient.root.key&sslmode=verify-full&sslrootcert=%2Fcerts%2Fca.crt"
CRDB_DSN_REPLICATOR="postgresql://root@$CRDB_IP:26257/defaultdb?sslcert=/certs/client.root.crt&sslkey=/certs/client.root.key&sslmode=verify-full&sslrootcert=/certs/ca.pem"
CRDB_DSN_WORKLOAD="postgresql://root@crdb_host:26257/defaultdb?sslcert=./certs/client.root.crt&sslkey=./certs/client.root.key&sslmode=verify-full&sslrootcert=./certs/ca.crt"

NOPAUSE=0
RESET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nopause|-n)
            NOPAUSE=1
            shift # Shift once to move past the current option
            ;;
        --width|-w)
            if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                TEXT_WIDTH="$2"
                shift 2 # Shift twice: once for the option, once for its argument
            else
                echo "Error: --width requires an argument." >&2
                exit 1
            fi
            ;;
        --reset|-w)
            RESET=1
            shift
            ;;
        --) # End of all options
            shift
            ARGS+=( "${@}" ) # Collect all remaining arguments as positional arguments
            break
            ;;
        -*)
            echo "Error: Unknown option $1" >&2
            exit 1
            ;;
        *) # Positional arguments
            ARGS+=( "$1" )
            shift
            ;;
    esac
done

# ========================
# --reset option
# ========================
if [[ $RESET == "1" ]]; then
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

pause() {
  echo ""
  if [[ $NOPAUSE == "1" ]]; then
      sleep 1
    else
      read -p "⏸️  Press [Enter] to continue..." 
  fi
  echo ""
}

checkcounts() {
 echo "Postgresql count..." 
 $DOCKER exec -e PGPASSWORD=secret -i postgres psql -h $PG_IP -U admin -d sampledb -c "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
 echo "Cockroach count..."
 $DOCKER exec -it crdb cockroach sql --certs-dir=./certs/ --host=$CRDB_IP --port=26257 --user=root --database=defaultdb -e "SELECT 
  (SELECT COUNT(1) FROM order_fills) AS order_fills_count,
  (SELECT COUNT(1) FROM orders) AS orders_count,
  NOW() AS current_time;"
}

verifyprintpretty() {
 sleep 1 
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

print_text() {
  echo "$1" | fold -s -w $TEXT_WIDTH
}

print_cmd() {
  echo "$1" | cat -n
}

STAGE=1
print_title() {
  echo "🚀 [$STAGE/$TOTALSTAGES] $1..."
  echo
  ((STAGE++))
}

do_stage() {
  if [[ -n "$1" ]]; then
    print_title "$1"
  fi  
  if [[ -n "$2" ]]; then
    print_text "$2"
  fi
  echo
  if [[ -n "$3" ]]; then
    echo "My next command..."
    echo "----------------"
    echo
    print_cmd "$3"
    pause
    echo "--Running--"
    eval "$3"
    echo "--Done--"
    pause
  fi
}

# ========================
# Get images and build network
# ========================

TITLE="Fetching latest docker images and building network"
TEXT=""
CMD="
$DOCKER pull cockroachdb/molt
$DOCKER pull cockroachdb/replicator
$DOCKER pull cockroachdb/cockroach
$DOCKER network create --driver=bridge --subnet=172.27.0.0/16 --ip-range=172.27.0.0/24 --gateway=172.27.0.1 moltdemo
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Start Postgres
# ========================

TITLE="Starting postgres container"
TEXT=""
CMD="$DOCKER run --rm -d --name postgres -p 5432:5432 \
  --hostname=pgsql_host \
  --ip=$PG_IP \
  --net=moltdemo \
  -e POSTGRES_USER=admin \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=sampledb \
  -v pgdata:/var/lib/postgresql/data \
  docker.io/library/postgres:15
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Configure logical replication
# ========================

TITLE="Configuring PostgreSQL for logical replication"
TEXT="📤 Copying postgresql.conf from container and editing WAL settings..."
CMD="sleep 5
$DOCKER cp postgres:/var/lib/postgresql/data/postgresql.conf ./postgresql.conf
sed -i '' 's/^#*wal_level.*/wal_level = logical/' ./postgresql.conf
sed -i '' 's/^#*max_replication_slots.*/max_replication_slots = 4/' ./postgresql.conf
sed -i '' 's/^#*max_wal_senders.*/max_wal_senders = 4/' ./postgresql.conf
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="📥 Copying updated config back and restarting container..."
CMD="$DOCKER cp ./postgresql.conf postgres:/var/lib/postgresql/data/postgresql.conf
$DOCKER restart postgres
sleep 5
"
do_stage "$TITLE" "$TEXT" "$CMD"


# ========================
# Validate replication settings
# ========================
TITLE="Verifying PostgreSQL replication settings"
TEXT=""
CMD="$DOCKER exec -e PGPASSWORD=secret -i postgres psql -h $PG_IP -U admin -d sampledb -c \"SHOW wal_level;\"
$DOCKER exec -e PGPASSWORD=secret -i postgres psql -h $PG_IP -U admin -d sampledb -c \"SHOW max_replication_slots;\"
$DOCKER exec -e PGPASSWORD=secret -i postgres psql -h $PG_IP -U admin -d sampledb -c \"SHOW max_wal_senders;\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Populate sample data
# ========================
TITLE="Inserting test orders into Postgres"
TEXT="This sample orders application will insert a number of records into a pair of tables in the postgres DB."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
generatedata "$PG_DSN_MOLT"
pause

# ========================
# Dump schema from Postgres
# ========================
TITLE="Dumping schema to $SCHEMA_FILE"
TEXT="This action will export the schema from postgres.  In future steps we will convert the schema for CockroachDB."
CMD="mkdir -p \"$SCHEMA_DIR\"
$DOCKER exec -i postgres pg_dump -U admin -d sampledb --schema-only -t orders -t order_fills > \"$SCHEMA_FILE\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Create CockroachDB Certificates
# ========================
TITLE="Creating CockroachDB certificates"
TEXT="This will create the keys, certificates, and pem files needed to start CockroachDB."
CMD="rm -f index.txt* serial.txt* ./certs/*
openssl genrsa -out ./certs/ca.key 2048
openssl req -new -x509 -config ca.cnf -key ./certs/ca.key -out ./certs/ca.crt -days 365 -batch
touch index.txt
echo '02' > serial.txt
openssl genrsa -out certs/node.key 2048
openssl req -new -config node.cnf -key ./certs/node.key -out ./certs/node.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_node_req -out ./certs/node.crt -outdir ./certs/ -in ./certs/node.csr -batch
openssl x509 -in ./certs/node.crt -text | grep \"X509v3 Subject Alternative Name\" -A 1
openssl genrsa -out ./certs/client.root.key 2048
openssl req -new -config client.cnf -key ./certs/client.root.key -out ./certs/client.root.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca.key -cert ./certs/ca.crt -policy signing_policy -extensions signing_client_req -out ./certs/client.root.crt -outdir ./certs/ -in ./certs/client.root.csr -batch
openssl x509 -in ./certs/ca.crt -out ./certs/ca.pem -outform PEM
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Start CockroachDB
# ========================
TITLE="Starting CockroachDB container"
TEXT=""
CMD="$DOCKER run -d -v \"./certs:/cockroach/certs\" --net=moltdemo --ip=$CRDB_IP --hostname=crdb_host --env COCKROACH_DATABASE=defaultdb --env COCKROACH_USER=root --env COCKROACH_PASSWORD=password --name=crdb -p 26257:26257 -p 8080:8080 cockroachdb/cockroach start-single-node --http-addr=crdb:8080
sleep 5
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Making sure CockroachDB is ready"
CMD="until $DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"SELECT 1;\" &>/dev/null; do
  echo \"⏳ Waiting for CockroachDB to become ready...\"
  sleep 2
done
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Enabling rangefeeds and creating a staging DB"
CMD="$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"SET CLUSTER SETTING kv.rangefeed.enabled=true;\"
$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"CREATE DATABASE staging;\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Convert schema with molt
# ========================
TITLE="Converting schema for CockroachDB using molt"
TEXT="This will use MOLT to automatically convert the schema we previously exported from postgres."
CMD="$DOCKER run --rm \
  -v \"$SCHEMA_DIR:/molt-data\" \
  -v \"./certs:/certs\" \
  --net=moltdemo \
  --hostname=molt_convert \
  --ip=$MOLT_IP \
  cockroachdb/molt convert postgres \
  --schema /molt-data/postgres_schema.sql \
  --url \"$CRDB_DSN_MOLT\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Inspect the converted schema.  This will scan the output from MOLT convert for any errors."
CMD="grep \"error\" cockroach-collections-main/molt-bucket/postgres_schema.sql.1 -A 9
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="CockroachDB does not support \restrict and \unrestrict.  So we need to remove those commands before we use the schema in CockroachDB."
CMD="sed -i '' 's/^\\\\restrict/-- &/' ./cockroach-collections-main/molt-bucket/postgres_schema.sql.1
sed -i '' 's/^\\\\unrestrict/-- &/' ./cockroach-collections-main/molt-bucket/postgres_schema.sql.1
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Apply schema to CockroachDB
# ========================
TITLE="Applying converted schema to CockroachDB"
TEXT="This will create the schema within CockroachDB."
CMD="$DOCKER exec -i crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ < \"$CONVERTED_SCHEMA\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Verify CockroachDB schema
# ========================
TITLE="Verifying CockroachDB schema"
TEXT="This command will verify that the tables have been successfully created in CockroachDB."
CMD="$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"SHOW CREATE ALL TABLES;\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Checking counts between postgres and CockroachDB.  Postgres should have data in it since we previously loaded orders into it and CockroachDB should not, as no transfer has occurred yet."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
checkcounts
pause

# ========================
# Run molt fetch 
# ========================
TITLE="Running MOLT fetch"
TEXT="MOLT fetch does the initial data copy from postgres to CockroachDB.  Real time replication will come in a later step."
CMD="$DOCKER run --rm -it \
  --name=molt_fetch \
  --net=moltdemo \
  --ip=$MOLT_IP \
  --hostname=molt_fetch \
  -v \"$SCHEMA_DIR:/molt-bucket\" \
  -v \"./certs:/certs\" \
  cockroachdb/molt \
  fetch \
  --source \"$PG_DSN_MOLT\" \
  --target \"$CRDB_DSN_MOLT\" \
  --allow-tls-mode-disable \
  --table-handling truncate-if-exists \
  --direct-copy \
  --pglogical-replication-slot-name replication_slot \
  --mode data-load \
  --logging=debug --replicator-flags \"-v\" | tee \"$FETCH_LOG\"
  "
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Run molt verify to compare the source data and CRDB data (any activity since the data load was done will result in false differences)... 
# ========================
TITLE="Running MOLT verify"
TEXT="We are using MOLT verify to compare the source data and CockroachDB data.  If any activity has occured since the data load into CockroachDB was done, this will result in differences."
CMD="$DOCKER run --rm -it \
  --name=molt_verify \
  --hostname=molt_verify \
  --ip=$MOLT_IP \
  --net=moltdemo \
  -v \"$SCHEMA_DIR:/molt-bucket\" \
  -v \"./certs:/certs\" \
  cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --source \"$PG_DSN_MOLT\" \
  --target \"$CRDB_DSN_MOLT\" \
  --allow-tls-mode-disable | tee \"$VERIFY_LOG\"
  "
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Pretty print the MOLT Verify output."
CMD="cat $VERIFY_LOG | tail -n +2 | jq"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Checking counts between postgres and CockroachDB.  Postgres should have data in it and CockroachDB should have the same count as long as no new data has been generated since we ran MOLT fetch."
CMD=""
checkcounts
pause

# ========================
# Populate sample data
# ========================
TITLE="Running workload that puts additional data into postgres"
TEXT="We will now insert more data into postgres."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
generatedata "$PG_DSN_MOLT"
pause

TITLE=""
TEXT="Checking counts between postgres and CockroachDB.  Postgres should have more data in it than CockroachDB, as real time replication has not been started yet."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
checkcounts
pause

# ========================
# Run replicator for replication... 
# ========================
TITLE="Enabling replication with replicator"
TEXT="Replicator does the real time replication from postgres to CockroachDB.  This is done by using the replication slots we configured earlier to stream any postgres data changes into replicator.  Replicator then stages and applies those data mutations to CockroachDB."
CMD="$DOCKER run \
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
  --sourceConn \"$PG_DSN_MOLT\" \
  --targetConn \"$CRDB_DSN_REPLICATOR\" \
  --slotName replication_slot \
  --publicationName molt_fetch

sleep 10
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="We will view the MOLT Replicator log output; checking counts between postgres and CockroachDB.  Once replication has caught up, both Postgres and CockroachDB should have the same row counts."
CMD=""
checkcounts
pause

TITLE=""
TEXT="Running molt verify to compare the source data and CockroachDB data (any activity since the last set of data was loaded will result in false differences)."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
verify
pause

TITLE=""
TEXT="Pretty print MOLT Verify output."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
verifyprintpretty
pause

# ========================
# Stop app
# ========================
TITLE="Stop the workload generating data if it is still running."
TEXT="Here we will prepare for minimal scheduled downtime, switch our application to use CockroachDB instead of postgres, and put replicator into failback mode in case we discover a future problem."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
pause

# ========================
# Start MOLT in failback mode
# ========================
TITLE="Build certificates and keys for replicator failback"
TEXT="Replicator requires a number of certificates for secure authentication.  This will be used when CockroachDB communicates with replicator in failback mode."
CMD="openssl genrsa -out ./certs/ca-rep.key 2048
openssl req -new -x509 -config ca.cnf -key ./certs/ca-rep.key -out ./certs/ca-rep.crt -days 365 -batch
openssl genrsa -out certs/node-rep.key 2048
openssl req -new -config rep.cnf -key ./certs/node-rep.key -out ./certs/node-rep.csr -batch
openssl ca -config ca.cnf -keyfile ./certs/ca-rep.key -cert ./certs/ca-rep.crt -policy signing_policy -extensions signing_node_req -out ./certs/node-rep.crt -outdir ./certs/ -in ./certs/node-rep.csr -batch
openssl x509 -in ./certs/node-rep.crt -text | grep \"X509v3 Subject Alternative Name\" -A 1
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE="---Begin of minimal downtime---"
TEXT="Stopping Replicator forward replication from postgres to CockroachDB.  Here is where our application should be temporarily shut down."
CMD="$DOCKER stop replicator_forward
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE="Start MOLT Replicator in failback mode."
TEXT="Replicator in failback mode is needed just in case issues are discovered with the migration later on."
CMD="$DOCKER run \
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
  --targetConn \"$PG_DSN_MOLT\" \
  --stagingConn \"$CRDB_DSN_STAGING\" \
  --tlsCertificate /certs/node-rep.crt \
  --tlsPrivateKey /certs/node-rep.key 
  "
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Let's inspect the replicator logs."
CMD="$DOCKER logs replicator_reverse
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE="Create an EC key"
TEXT="We will need this key to create our JWT auth token later on."
CMD="openssl ecparam -out ./certs/ec.key -genkey -name prime256v1
openssl ec -in ./certs/ec.key -pubout -out ./certs/ec.pub
"
do_stage "$TITLE" "$TEXT" "$CMD"
ECPUB=`cat ./certs/ec.pub`

TITLE=""
TEXT="Now we clear the JWT table that replicator will use and insert our EC public key."
CMD="$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"truncate table _replicator.jwt_public_keys;\"
$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"INSERT INTO _replicator.jwt_public_keys (public_key) VALUES (
'$ECPUB'
);\"
$DOCKER exec -it crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"select * from _replicator.jwt_public_keys;\"
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Now we will use replicator to generate the JWT auth token we will use in the changefeed later on to stream data from CockroachDB to replicator.  This is the token created from our secret EC key."
CMD="$DOCKER run \
 -v ./certs:/certs \
 cockroachdb/replicator \
  make-jwt \
  -k /certs/ec.key \
  -a sampledb.public \
  -o /certs/out.jwt
"
do_stage "$TITLE" "$TEXT" "$CMD"
JWT=`cat ./certs/out.jwt`

TITLE=""
TEXT="Restarting replicator_reverse to read the new keys.  If we were to wait instead of restarting replicator, it would reread the keys each minute."
CMD="$DOCKER restart replicator_reverse
sleep 5
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Now we will get the CockroachCB cluster logical timestamp for the changefeed cursor parameter.  This will allow the changefeed to begin from the moment our forward migration was stopped.

My next command...

$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ --format csv -e \"SELECT cluster_logical_timestamp();\" | tail -n -1
"
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
CLUSTER_LOGICAL_TIMESTAMP=$($DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ --format csv -e "SELECT cluster_logical_timestamp();" | tail -n -1)
echo $CLUSTER_LOGICAL_TIMESTAMP
echo
pause

TITLE=""
TEXT="Now we will connect to replicator and get the leaf key and base64 encode it for use in the changefeed."
CMD="openssl s_client -connect localhost:30004 \
  -servername $REP_IP -showcerts </dev/null \
  | awk '/BEGIN CERTIFICATE/{flag=1} flag; /END CERTIFICATE/{print; exit}' \
  > ./certs/replicator-leaf.pem
"
do_stage "$TITLE" "$TEXT" "$CMD"
CA_B64=$(base64 -w0 -i ./certs/replicator-leaf.pem)

TITLE="Create changefeed to MOLT Replicator"
# for pgsql/crdb sources, for failback, you need to include the schema as part of the URI
TEXT="We will use the various certificates, JWTs, and base64 encodings to create the changefeed that will allow for reverse replication from CockroachDB to replicator.  The ca_cert is the base64 encoded version of the replicator-leaf.pem we captured previously.  The bearer token is the output from replicator's make-jwt command earlier.  

My next command...

$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e \"CREATE CHANGEFEED FOR TABLE orders, order_fills
 INTO 'webhook-https://$REP_IP:30004/sampledb/public?ca_cert=$CA_B64' 
 WITH updated, 
      resolved = '250ms', 
      min_checkpoint_frequency = '250ms', 
      initial_scan = 'no', 
      cursor = '$CLUSTER_LOGICAL_TIMESTAMP', 
      webhook_sink_config = '{\\"Flush\\":{\\"Bytes\\":1048576,\\"Frequency\\":\\"1s\\"}}', \
      webhook_auth_header = 'Bearer $JWT';\"
"
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
$DOCKER exec crdb cockroach sql --host=$CRDB_IP --port=26257 --user=root --database=defaultdb --certs-dir=./certs/ -e "CREATE CHANGEFEED FOR TABLE orders, order_fills
 INTO 'webhook-https://$REP_IP:30004/sampledb/public?ca_cert=$CA_B64' 
 WITH updated, 
      resolved = '250ms', 
      min_checkpoint_frequency = '250ms', 
      initial_scan = 'no', 
      cursor = '$CLUSTER_LOGICAL_TIMESTAMP', 
      webhook_sink_config = '{\"Flush\":{\"Bytes\":1048576,\"Frequency\":\"1s\"}}', \
      webhook_auth_header = 'Bearer $JWT';"

TITLE=""
TEXT="Display logs for replicator_reverse."
CMD="$DOCKER logs replicator_reverse
"
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE=""
TEXT="Check the counts between postgres and CockroachDB.  They should be the same."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
checkcounts
pause

TITLE="---End of downtime---"
TEXT="Reverse replication is set up.  Then this is where you would configure the application to connect to CockroacDB and restart the workload.  Perform your final go/no-go tests.
---Migration complete to CockroachDB with failback running---"
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"

TITLE="Show reverse replication is working by inserting data into CockroachDB and letting it replicate into postgres."
TEXT=""
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
generatedata "$CRDB_DSN_WORKLOAD"
echo "Sleep 10 seconds to let the change propagate to postgres."
sleep 10
pause

TITLE=""
TEXT="Checking counts between postgres and CockroachDB."
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"
checkcounts
pause

TITLE=""
TEXT="Inspect the MOLT Replicator logs again."
CMD="$DOCKER logs replicator_reverse"
do_stage "$TITLE" "$TEXT" "$CMD"

# ========================
# Done
# ========================
TITLE="Pipeline complete!"
TEXT=""
CMD=""
do_stage "$TITLE" "$TEXT" "$CMD"

