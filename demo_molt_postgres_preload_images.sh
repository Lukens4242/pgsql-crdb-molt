# Preload images for the migration demo pgsql-crdb-molt/full_pipeline.sh
#
# This will avoid delays when running the demo script
# This will also avoid network congestion when a large number of people
# run the demo script at the same time on the same network

echo 'Before:'
docker image ls

echo

if docker image ls --format table | grep -q 'order-app'; then
 echo 'The order-app image already exists so we are skipping building it'
else
 docker build -t order-app:latest .
fi

echo

docker pull cockroachdb/cockroach:v24.3.25
echo

docker pull cockroachdb/molt:1.3.5
echo

docker pull cockroachdb/replicator:v1.3.0
echo

docker pull postgres:15
echo

echo 'After:'
docker image ls
