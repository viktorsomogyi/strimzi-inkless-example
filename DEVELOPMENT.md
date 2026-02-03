# Building and Publishing the Kafka Image

This document is for **developers and maintainers** who need to build the Inkless-enabled Strimzi Kafka image and publish it to GitHub Container Registry (GHCR). **End-users** do not run these steps; they use the pre-built image when running [setup_inkless.sh](README.md#step-2-deploy-inkless--strimzi--dependencies).

## Overview

- The Kafka image is built from a Strimzi fork/branch that includes Inkless support.
- After building, the image is tagged and pushed to GHCR so that `setup_inkless.sh` (and clusters) can pull it.
- Users run `setup_inkless.sh` only; they never run the build or push.

## Prerequisites

- **Docker**: Installed and running
- **Java 21**: Required for the Strimzi build
- **Git**: To clone the Strimzi repo
- **make**: Build driver
- **Maven** (`mvn`): Strimzi is built with Maven

On Debian/Ubuntu you can install build tools and run the script:

```bash
# Optional: one-time environment setup (Java 21, Docker, Maven, jq, etc.)
./setup_debian_bookworm.sh
# If using SDKMAN for Java: source ~/.sdkman/bin/sdkman-init.sh
```

## Build and Push

1. **Log in to GHCR** (required to push):

   ```bash
   docker login ghcr.io
   ```
   Use your GitHub username and a Personal Access Token with `read:packages` and `write:packages`.

2. **Run the build-and-push script** from the repo root:

   ```bash
   ./build_and_push_kafka_image.sh
   ```

   This script will:
   - Clone (or update) the Strimzi Kafka Operator fork at `$STRIMZI_DIR` (default: `/tmp/strimzi-kafka-operator`)
   - Check out the `inkless-compat` branch
   - Build the Kafka image with Make (kafka-agent, tracing-agent, docker-images/artifacts, base, kafka-based)
   - Tag the local image as `$KAFKA_IMAGE` and push it to GHCR

3. **Override image or clone location** (optional):

   ```bash
   KAFKA_IMAGE=ghcr.io/your-org/strimzi-kafka:inkless-4.0.0 ./build_and_push_kafka_image.sh
   STRIMZI_DIR=/path/to/strimzi ./build_and_push_kafka_image.sh
   ```

After a successful push, anyone can deploy using that image:

```bash
# Same as default; only needed if you used a custom KAFKA_IMAGE
KAFKA_IMAGE=ghcr.io/viktorsomogyi/strimzi-inkless:inkless-4.0.0 ./setup_inkless.sh
```

## Default Image

The default image reference used by both scripts is:

- **KAFKA_IMAGE**: `ghcr.io/viktorsomogyi/strimzi-inkless:inkless-4.0.0`

So after you run `build_and_push_kafka_image.sh` with the default, users can run `setup_inkless.sh` with no extra configuration and the cluster will pull that image from GHCR.

## Strimzi Source

- Repository: [viktorsomogyi/strimzi-kafka-operator](https://github.com/viktorsomogyi/strimzi-kafka-operator)
- Branch: `inkless-compat`

The build produces the image `strimzi/kafka:build-kafka-4.0.0` locally; the script then tags it as `$KAFKA_IMAGE` and pushes that tag to GHCR.
