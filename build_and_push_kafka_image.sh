#!/bin/bash
# Build the Inkless-enabled Strimzi Kafka image and push it to GHCR.
# For end-users, the pre-built image is used by setup_inkless.sh (see README).
# Run this script only when you need to rebuild and publish the image (e.g. maintainers, CI).

set -x

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

function require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' is not installed or not on PATH."
    exit 1
  fi
}

KAFKA_VERSION="${KAFKA_VERSION:-4.1.1}"
INKLESS_VERSION="${INKLESS_VERSION:-0.34}"

# https://github.com/aiven/inkless/releases/download/inkless-release-0.34/kafka_2.13-4.1.1-inkless.tgz
KAFKA_IMAGE="${KAFKA_IMAGE:-ghcr.io/viktorsomogyi/strimzi-inkless:${KAFKA_VERSION}-${INKLESS_VERSION}}"
STRIMZI_DIR="${STRIMZI_DIR:-$(mktemp -d)}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"

# Strimzi docker build tags non-amd64 images with an architecture suffix (e.g. build-kafka-4.1.1-arm64).
if [ "$ARCHITECTURE" = "amd64" ]; then
  LOCAL_KAFKA_IMAGE="strimzi/kafka:build-kafka-${KAFKA_VERSION}"
else
  LOCAL_KAFKA_IMAGE="strimzi/kafka:build-kafka-${KAFKA_VERSION}-${ARCHITECTURE}"
fi

require_cmd docker
require_cmd git
require_cmd java
require_cmd make
require_cmd mvn

JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
if [ "$JAVA_VER" != "21" ]; then
  echo "Error: Java 21 required, found: $JAVA_VER"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon is not running or you lack permissions."
  exit 1
fi

echo "Building Strimzi Kafka image and pushing to $KAFKA_IMAGE"
echo "Strimzi clone: $STRIMZI_DIR"

echo "Cloning Strimzi Kafka Operator into $STRIMZI_DIR ..."
git clone https://github.com/viktorsomogyi/strimzi-kafka-operator.git "$STRIMZI_DIR"
cd "$STRIMZI_DIR"

git fetch origin
git checkout inkless-compat

echo "Building Strimzi Kafka Operator and image..."
DOCKER_ARCHITECTURE=${ARCHITECTURE} make -C kafka-agent MVN_ARGS='-DskipTests' java_build
DOCKER_ARCHITECTURE=${ARCHITECTURE} make -C tracing-agent MVN_ARGS='-DskipTests' java_build
DOCKER_ARCHITECTURE=${ARCHITECTURE} make -C docker-images/artifacts MVN_ARGS='-DskipTests' java_build
DOCKER_ARCHITECTURE=${ARCHITECTURE} make -C docker-images/base MVN_ARGS='-DskipTests' docker_build
DOCKER_ARCHITECTURE=${ARCHITECTURE} make -C docker-images/kafka-based MVN_ARGS='-DskipTests' docker_build

if ! docker image inspect "$LOCAL_KAFKA_IMAGE" >/dev/null 2>&1; then
  echo "Error: Docker image '$LOCAL_KAFKA_IMAGE' not found after build."
  exit 1
fi

echo "Tagging and pushing to $KAFKA_IMAGE ..."
docker tag "$LOCAL_KAFKA_IMAGE" "$KAFKA_IMAGE"
if ! docker push "$KAFKA_IMAGE"; then
  echo "Error: Failed to push. Log in with: docker login ghcr.io"
  echo "Use a GitHub PAT with read:packages and write:packages."
  exit 1
fi

echo "Pushed $KAFKA_IMAGE successfully."
echo "Users can run setup_inkless.sh (with KAFKA_IMAGE=$KAFKA_IMAGE if different from default) to deploy."
