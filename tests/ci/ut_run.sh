#!/bin/bash
set -x

set -e

export POSTGRESQL_HOST=$1
export REGISTRY_URL=http://$1:5000
export CHROME_BIN=chromium-browser
#export DISPLAY=:99.0
#sh -e /etc/init.d/xvfb start

# The harbor-db image runs postgres as uid 999 and inits its data dir under the
# bind-mounted /data/database. Without `make prepare` (which the API jobs run),
# that host dir is root-owned, so initdb fails and the container crash-loops.
# Pre-create it owned by the postgres uid so postgres can initialize the cluster.
sudo mkdir -p /data/database && sudo chown -R 999:999 /data/database
sudo docker-compose -f ./make/docker-compose.test.yml up -d
sleep 10
# Diagnostics: the postgres (harbor-db) container has been crash-looping in this
# job. Dump its status and logs so the actual initdb/startup error is visible.
echo "=== docker ps -a ==="; sudo docker ps -a || true
PG_CID=$(sudo docker ps -aq --filter "ancestor=goharbor/harbor-db:dev" | head -1)
echo "=== harbor-db container logs ($PG_CID) ==="; [ -n "$PG_CID" ] && sudo docker logs "$PG_CID" 2>&1 | tail -120 || true
echo "=== /data/database listing ==="; sudo ls -lan /data/database || true
./tests/pushimage.sh
docker ps

DIR="$(cd "$(dirname "$0")" && pwd)"
sudo -E env "PATH=$PATH" "POSTGRES_MIGRATION_SCRIPTS_PATH=$DIR/../../make/migrations/postgresql/" ./tests/coverage4gotest.sh
#goveralls -coverprofile=profile.cov -service=github || true
