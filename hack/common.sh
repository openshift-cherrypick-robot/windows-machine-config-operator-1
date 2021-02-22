#!/bin/bash

# Location of the manifests file
MANIFEST_LOC=deploy/olm-catalog/windows-machine-config-operator

error-exit() {
    echo "Error: $*" >&2
    exit 1
}

get_operator_sdk() {
  # Download the operator-sdk binary only if it is not already available
  # We do not validate the version of operator-sdk if it is available already
  if type operator-sdk >/dev/null 2>&1; then
    which operator-sdk
    return
  fi

  DOWNLOAD_DIR=/tmp/operator-sdk
  # TODO: Make this download the same version we have in go dependencies in gomod
  wget --no-verbose -O $DOWNLOAD_DIR https://github.com/operator-framework/operator-sdk/releases/download/v0.19.4/operator-sdk-v0.19.4-x86_64-linux-gnu && chmod +x /tmp/operator-sdk || return
  echo $DOWNLOAD_DIR
}

# This function runs operator-sdk run --olm/cleanup depending on the given parameters
# Parameters:
# 1: command to run [run/cleanup]
# 2: path to the operator-sdk binary to use
# 3: OPTIONAL path to the directory holding the temporary CSV with image field replaced with operator image
OSDK_WMCO_management() {
  if [ "$#" -lt 2 ]; then
    echo incorrect parameter count for OSDK_WMCO_management $#
    return 1
  fi
  if [[ "$1" != "run" && "$1" != "cleanup" ]]; then
    echo $1 does not match either run or cleanup
    return 1
  fi

  local COMMAND=$1
  local OSDK_PATH=$2

  $OSDK_PATH $COMMAND packagemanifests \
    --olm-namespace openshift-operator-lifecycle-manager \
    --operator-namespace openshift-windows-machine-config-operator \
    --operator-version 0.0.0 \
    --timeout 5m
}

build_WMCO() {
  local OSDK=$1
  
  if [ -z "$OPERATOR_IMAGE" ]; then
      error-exit "OPERATOR_IMAGE not set"
  fi

  $CONTAINER_TOOL build . -t "$OPERATOR_IMAGE" -f build/Dockerfile $noCache
  if [ $? -ne 0 ] ; then
      error-exit "failed to build operator image"
  fi

  $CONTAINER_TOOL push "$OPERATOR_IMAGE"
  if [ $? -ne 0 ] ; then
      error-exit "failed to push operator image to remote repository"
  fi
}

# Updates the manifest file with the operator image, prepares the cluster to run the operator and
# runs the operator on the cluster using OLM
# Parameters:
# 1: path to the operator-sdk binary to use
# 2 (optional): private key path. This is typically used only from olm.sh, to avoid having to manually create the key.
run_WMCO() {
  if [ "$#" -lt 1 ]; then
      echo incorrect parameter count for run_WMCO $#
      return 1
  fi

  local OSDK=$1
  local PRIVATE_KEY=""
  if [ "$#" -eq 2 ]; then
      local PRIVATE_KEY=$2
  fi

  transform_csv REPLACE_IMAGE $OPERATOR_IMAGE

  # Validate the operator bundle manifests
  $OSDK bundle validate $MANIFEST_LOC
  if [ $? -ne 0 ] ; then
      error-exit "operator bundle validation failed"
  fi

  if ! oc apply -f deploy/namespace.yaml; then
      return 1
  fi

  if [ -n "$PRIVATE_KEY" ]; then
      if ! oc get secret cloud-private-key -n openshift-windows-machine-config-operator; then
          echo "Creating private-key secret"
          if ! oc create secret generic cloud-private-key --from-file=private-key.pem="$PRIVATE_KEY" -n openshift-windows-machine-config-operator; then
              return 1
          fi
      fi
  fi

  # Run the operator in the openshift-windows-machine-config-operator namespace
  OSDK_WMCO_management run $OSDK

  # Additional guard that ensures that operator was deployed given the SDK flakes in error reporting
  if ! oc rollout status deployment windows-machine-config-operator -n openshift-windows-machine-config-operator --timeout=5s; then
    return 1
  fi
}

# Reverts the changes made in manifests file and cleans up the installation of operator from the cluster and deletes the namespace
# Parameters:
# 1: path to the operator-sdk binary to use
cleanup_WMCO() {
  local OSDK=$1

  # Cleanup the operator and revert changes made to the csv
  if ! OSDK_WMCO_management cleanup $OSDK; then
      transform_csv $OPERATOR_IMAGE REPLACE_IMAGE
      error-exit "operator cleanup failed"
  fi
  transform_csv $OPERATOR_IMAGE REPLACE_IMAGE

  # Remove the operator from openshift-windows-machine-config-operator namespace
  oc delete -f deploy/namespace.yaml
}

# returns the operator version in `Version+GitHash` format
# we are just checking the status of files that affect the building of the operator binary
# the files here are selected based on the files that we are transferring while building the
# operator binary in `build/Dockerfile`
get_version() {
  OPERATOR_VERSION=2.0.0
  GIT_COMMIT=$(git rev-parse --short HEAD)
  VERSION="${OPERATOR_VERSION}+${GIT_COMMIT}"

  if [ -n "$(git status version tools.go go.mod go.sum vendor Makefile build cmd hack pkg --porcelain)" ]; then
    VERSION="${VERSION}-dirty"
  fi

  echo $VERSION
}

# Given two parameters, replaces the value in first parameter with the second in the csv.
# Parameters:
# 1: parameter to determine value to be replaced in the csv
# 2: parameter with new value to be replaced with in the csv
transform_csv() {
  if [ "$#" -lt 2 ]; then
    echo incorrect parameter count for replace_csv_value $#
    return 1
  fi
  sed -i "s|"$1"|"$2"|g" $MANIFEST_LOC/manifests/windows-machine-config-operator.clusterserviceversion.yaml
}
