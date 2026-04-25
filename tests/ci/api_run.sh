#!/bin/bash
set -x

#source gskey.sh

sudo aws --version

harbor_logs_bucket="harbor-ci-logs"

DIR="$(cd "$(dirname "$0")" && pwd)"
E2E_IMAGE="goharbor/harbor-e2e-engine:latest-api"

# GS util
function uploader {
   sudo aws s3 cp $1 s3://$2/$1
}

set +e

docker ps
# run db auth api cases
if [ "$1" = 'DB' ]; then
    EXCLUDE_FLAGS="--exclude proxy_cache_from_harbor --exclude proxy_cache_from_dockerhub --exclude proxy_cache_from_jfrog"
    if [ -z "${DOCKER_USER}" ] || [ -z "${DOCKER_PWD}" ]; then
        echo "DOCKER_USER/DOCKER_PWD not set, excluding replic_dockerhub test"
        EXCLUDE_FLAGS="${EXCLUDE_FLAGS} --exclude replic_dockerhub"
    fi
    docker run -i --privileged \
        -v $DIR/../../:/drone -v $DIR/../:/ca -w /drone $E2E_IMAGE \
        robot ${EXCLUDE_FLAGS} \
        -v DOCKER_USER:"${DOCKER_USER}" -v DOCKER_PWD:${DOCKER_PWD} -v ip:$2 -v ip1: \
        -v http_get_ca:false -v HARBOR_PASSWORD:${HARBOR_ADMIN_PASSWD} -v HARBOR_ADMIN:${HARBOR_ADMIN} \
        /drone/tests/robot-cases/Group1-Nightly/Setup.robot \
        /drone/tests/robot-cases/Group0-BAT/API_DB.robot
    rc=$?
elif [ "$1" = 'PROXY_CACHE' ]; then

    PROXY_CACHE_TESTCASE_TAG="proxy_cache_from_harbor"
    docker run -i --privileged \
        -v $DIR/../../:/drone -v $DIR/../:/ca -w /drone $E2E_IMAGE \
        robot --include setup --include "${PROXY_CACHE_TESTCASE_TAG}" \
        -v DOCKER_USER:"${DOCKER_USER}" -v DOCKER_PWD:${DOCKER_PWD} -v ip:$2 -v ip1: \
        -v http_get_ca:false -v HARBOR_PASSWORD:${HARBOR_ADMIN_PASSWD} -v HARBOR_ADMIN:${HARBOR_ADMIN} \
        /drone/tests/robot-cases/Group1-Nightly/Setup.robot \
        /drone/tests/robot-cases/Group0-BAT/API_DB.robot
    rc=$?
elif [ "$1" = 'LDAP' ]; then
    # Configure Harbor for LDAP auth - retry up to 5 times in case Harbor needs extra time
    ldap_config_ok=false
    for attempt in 1 2 3 4 5; do
        if python $DIR/../../tests/configharbor.py \
            -H $IP -u $HARBOR_ADMIN -p $HARBOR_ADMIN_PASSWD \
            -c auth_mode=ldap_auth \
            ldap_url=ldap://$IP \
            ldap_search_dn=cn=admin,dc=example,dc=com \
            ldap_search_password=admin \
            ldap_base_dn=dc=example,dc=com \
            ldap_uid=cn; then
            echo "LDAP configured successfully on attempt ${attempt}"
            ldap_config_ok=true
            break
        fi
        echo "LDAP config attempt ${attempt} failed, retrying in 15 seconds..."
        sleep 15
    done
    if [ "$ldap_config_ok" = false ]; then
        echo "ERROR: Failed to configure Harbor LDAP after 5 attempts - aborting"
        rc=1
    else
        docker run -i --privileged \
            -v $DIR/../../:/drone -v $DIR/../:/ca -w /drone $E2E_IMAGE \
            robot \
            -v DOCKER_USER:"${DOCKER_USER}" -v DOCKER_PWD:${DOCKER_PWD} -v ip:$2 -v ip1: \
            -v http_get_ca:false -v HARBOR_PASSWORD:${HARBOR_ADMIN_PASSWD} -v HARBOR_ADMIN:${HARBOR_ADMIN} \
            /drone/tests/robot-cases/Group1-Nightly/Setup.robot \
            /drone/tests/robot-cases/Group0-BAT/API_LDAP.robot
        rc=$?
    fi
else
    rc=999
fi
## --------------------------------------------- Package Harbor CI Logs -------------------------------------------
outfile="integration_logs.tar.gz"
sudo tar -zcvf $outfile output.xml log.html /var/log/harbor/*
pwd
ls -lh $outfile
exit $rc
