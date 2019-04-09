#!/bin/sh

case "$1" in
-h | --help | help )
        cat <<EOF
$(basename $0) new CLUSTER-NAME [OPS-BRANCH-NAME] [CLUSTER-TYPE] [CLUSTER-KIND]

Sets up a new, named deployment checkout for a cluster of type CLUSTER_TYPE
for subsequent deployment.

The CLUSTER-NAME will be used both for the ops checkout directory, and
the Nixops deployment.

Available cluster types:  $(if test ! -d clusters; then cd .seed; fi && ls clusters | xargs echo)

Generals documentation: https://github.com/input-output-hk/iohk-ops/blob/goguen-ala-cardano/docs/Goguen-clusters-HOWTO.org

EOF
        exit 1;;
esac;

CLUSTER_NAME="$1";                            test -n "$1" && shift
BRANCH_NAME="${1:-${DEFAULT_OPS_BRANCH}}";    test -n "$1" && shift
CLUSTER_TYPE="${1:-${CLUSTER_TYPE}}";         test -n "$1" && shift
CLUSTER_KIND="${1:-${CLUSTER_KIND}}";         test -n "$1" && shift

set -u
while test -d "${CLUSTER_NAME}" -o -z "${CLUSTER_NAME}" || nixops info -d "${CLUSTER_NAME}" >/dev/null 2>/dev/null
do read -ei "${CLUSTER_NAME}" -p "Cluster '${CLUSTER_NAME}' already exists, please choose another name: " CLUSTER_NAME
done

git clone "${OPS_REPO}" "${CLUSTER_NAME}"
cd "${CLUSTER_NAME}"
git checkout "${BRANCH_NAME}"
cat > .config.sh <<EOF
CLUSTER_KIND=${CLUSTER_KIND}
CLUSTER_TYPE=${CLUSTER_TYPE}
CLUSTER_NAME=${CLUSTER_NAME}
CONFIG=default
EOF
$GAC_CENTRAL list-cluster-components
if test "${CLUSTER_TYPE}" = "mantis"
then log "generating node keys.."
     $GAC_CENTRAL generate-node-keys
fi
log "creating the Nixops deployment.."
nixops       create   -d "${CLUSTER_NAME}" "clusters/${CLUSTER_TYPE}"/*.nix
$GAC_CENTRAL configure-nixops-deployment-arguments
log "cluster has been set up, but not deployed;  Next steps:"
log "  1. cd ${CLUSTER_NAME}"
log "  2. gac deploy"
