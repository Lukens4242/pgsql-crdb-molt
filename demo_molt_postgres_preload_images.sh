# Preload images for the migration demo pgsql-crdb-molt/full_pipeline.sh
#
# This will avoid delays when running the demo script
# This will also avoid network congestion when a large number of people
# run the demo script at the same time on the same network

DOCKER="${DOCKER:-docker}"

echo 'Before:'
$DOCKER image ls

echo

if $DOCKER image ls --format table | grep -q 'order-app'; then
 echo 'The order-app image already exists so we are skipping building it'
else
 $DOCKER build -t order-app:latest .
fi

echo

$DOCKER pull cockroachdb/cockroach:v24.3.25
echo

$DOCKER pull cockroachdb/molt:1.3.5
echo

$DOCKER pull cockroachdb/replicator:v1.3.0
echo

$DOCKER pull postgres:15
echo

echo 'After:'
$DOCKER image ls
