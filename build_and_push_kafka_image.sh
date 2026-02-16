#!/bin/bash
# Build the Inkless-enabled Strimzi Kafka image and push it to GHCR.
# For end-users, the pre-built image is used by setup_inkless.sh (see README).
# Run this script only when you need to rebuild and publish the image (e.g. maintainers, CI).

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

function require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' is not installed or not on PATH."
    exit 1
  fi
}

KAFKA_VERSION="${KAFKA_VERSION:-4.1.1}"
INKLESS_VERSION="${INKLESS_VERSION:-0.34}"

DOCKER_REPO="${DOCKER_REPO:-ghcr.io/viktorsomogyi}"
# clone strimzi if not the default value
clone_strimzi=$([ -z "$STRIMZI_DIR" ] && echo "true" || echo "false")
STRIMZI_DIR="${STRIMZI_DIR:-$(mktemp -d)}"
# Build for both platforms and create a multi-arch manifest (override to build a single arch only)
ARCHITECTURES="${ARCHITECTURES:-arm64 amd64}"

# Multi-arch tag (no arch suffix); users pull this and get the right image for their platform
MULTI_ARCH_IMAGE="${DOCKER_REPO}/strimzi-inkless:${KAFKA_VERSION}-${INKLESS_VERSION}"

PUSH_IMAGES=${PUSH_IMAGES:-"true"}

echo "--------------------------------"
echo "Environment variables:"
echo "KAFKA_VERSION: $KAFKA_VERSION"
echo "INKLESS_VERSION: $INKLESS_VERSION"
echo "DOCKER_REPO: $DOCKER_REPO"
echo "STRIMZI_DIR: $STRIMZI_DIR"
echo "ARCHITECTURES: $ARCHITECTURES"
echo "MULTI_ARCH_IMAGE: $MULTI_ARCH_IMAGE"
echo "PUSH_IMAGES: $PUSH_IMAGES"
echo "--------------------------------"

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

echo "Building Strimzi Kafka images for $ARCHITECTURES and creating multi-arch manifest $MULTI_ARCH_IMAGE"

echo "Cleaning up old images..."
docker image rm strimzi/base:latest || true
for ARCHITECTURE in $ARCHITECTURES; do
  docker image rm strimzi/base:latest-${ARCHITECTURE} || true
  docker image rm strimzi/kafka:build-kafka-${KAFKA_VERSION}-${ARCHITECTURE} || true
done

# clone if strimzi isn't the default value
if [ "$clone_strimzi" = "true" ]; then
  echo "Cloning Strimzi Kafka Operator into $STRIMZI_DIR ..."
  git clone https://github.com/viktorsomogyi/strimzi-kafka-operator.git "$STRIMZI_DIR"
  cd "$STRIMZI_DIR"
  git fetch origin
  git checkout inkless-compat
else
  echo "Using existing Strimzi Kafka Operator in $STRIMZI_DIR ..."
  cd "$STRIMZI_DIR"
fi


# Build, tag and push each architecture
for ARCHITECTURE in $ARCHITECTURES; do
  LOCAL_KAFKA_IMAGE="strimzi/kafka:build-kafka-${KAFKA_VERSION}-${ARCHITECTURE}"
  ARCH_IMAGE="${MULTI_ARCH_IMAGE}-${ARCHITECTURE}"
  BUILD_ARGS="--provenance=false --sbom=false"

  echo "===== Building for $ARCHITECTURE ====="
  DOCKER_ARCHITECTURE=${ARCHITECTURE} DOCKER_BUILDX=buildx DOCKER_BUILD_ARGS="${BUILD_ARGS}" make -C kafka-agent MVN_ARGS='-DskipTests' java_build
  DOCKER_ARCHITECTURE=${ARCHITECTURE} DOCKER_BUILDX=buildx DOCKER_BUILD_ARGS="${BUILD_ARGS}" make -C tracing-agent MVN_ARGS='-DskipTests' java_build
  DOCKER_ARCHITECTURE=${ARCHITECTURE} DOCKER_BUILDX=buildx DOCKER_BUILD_ARGS="${BUILD_ARGS}" make -C docker-images/artifacts MVN_ARGS='-DskipTests' java_build
  DOCKER_ARCHITECTURE=${ARCHITECTURE} DOCKER_BUILDX=buildx DOCKER_BUILD_ARGS="${BUILD_ARGS}" make -C docker-images/base MVN_ARGS='-DskipTests' docker_build
  DOCKER_ARCHITECTURE=${ARCHITECTURE} DOCKER_BUILDX=buildx DOCKER_BUILD_ARGS="${BUILD_ARGS}" make -C docker-images/kafka-based MVN_ARGS='-DskipTests' docker_build

  # verify base image architecture is the expected one
  BASE_IMAGE="strimzi/base:latest-${ARCHITECTURE}"
  ACTUAL_ARCHITECTURE=$(docker image inspect ${BASE_IMAGE} --format '{{.Architecture}}')
  if [ "$ACTUAL_ARCHITECTURE" != "$ARCHITECTURE" ]; then
    echo "Error: Image ${BASE_IMAGE} architecture is not the expected one. Expected: ${ARCHITECTURE}, got: ${ACTUAL_ARCHITECTURE}"
    exit 1
  fi

  # verify the image architecture is the expected one
  ACTUAL_ARCHITECTURE=$(docker image inspect ${LOCAL_KAFKA_IMAGE} --format '{{.Architecture}}')
  if [ "$ACTUAL_ARCHITECTURE" != "$ARCHITECTURE" ]; then
    echo "Error: Image ${LOCAL_KAFKA_IMAGE} architecture is not the expected one. Expected: ${ARCHITECTURE}, got: ${ACTUAL_ARCHITECTURE}"
    exit 1
  fi

  if ! docker image inspect "$LOCAL_KAFKA_IMAGE" >/dev/null 2>&1; then
    echo "Error: Docker image '$LOCAL_KAFKA_IMAGE' not found after build."
    exit 1
  fi

  echo "Tagging and pushing $ARCH_IMAGE ..."
  docker tag "$LOCAL_KAFKA_IMAGE" "$ARCH_IMAGE"
  if [ "$PUSH_IMAGES" = "true" ] && ! docker push "$ARCH_IMAGE"; then
    echo "Error: Failed to push. Log in with: docker login ghcr.io"
    echo "Use a GitHub PAT with read:packages and write:packages."
    exit 1
  fi
  if [ "$PUSH_IMAGES" = "true" ]; then
    echo "Pushed $ARCH_IMAGE successfully."
  fi
done

# Create and push multi-arch manifest so one tag resolves to the correct arch
echo "===== Creating multi-arch manifest $MULTI_ARCH_IMAGE ====="
export DOCKER_CLI_EXPERIMENTAL=enabled
MANIFEST_IMAGES=""
for ARCHITECTURE in $ARCHITECTURES; do
  MANIFEST_IMAGES="${MANIFEST_IMAGES} ${MULTI_ARCH_IMAGE}-${ARCHITECTURE}"
done
docker manifest rm "$MULTI_ARCH_IMAGE" 2>/dev/null || true
docker manifest create "$MULTI_ARCH_IMAGE" $MANIFEST_IMAGES
if [ "$PUSH_IMAGES" = "true" ] && ! docker manifest push "$MULTI_ARCH_IMAGE"; then
  echo "Error: Failed to push manifest. Ensure Docker manifest is enabled (DOCKER_CLI_EXPERIMENTAL=enabled)."
  exit 1
fi
if [ "$PUSH_IMAGES" = "true" ]; then
  echo "Multi-arch image pushed: $MULTI_ARCH_IMAGE"
fi
echo "Users can run setup_inkless.sh (with KAFKA_IMAGE=$MULTI_ARCH_IMAGE if different from default) to deploy."