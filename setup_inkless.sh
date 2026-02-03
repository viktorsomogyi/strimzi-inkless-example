#!/bin/bash

SCRIPT_DIR=$(pwd)

function have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

function require_cmd() {
    CMD="$1"
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Error: '$CMD' is not installed or not on PATH."
        exit 1
    fi
}

function require_kube_access() {
    if ! kubectl config current-context >/dev/null 2>&1; then
        echo "Error: kubectl has no current context (KUBECONFIG='$KUBECONFIG')."
        exit 1
    fi
    if ! kubectl --request-timeout=10s get namespace >/dev/null 2>&1; then
        echo "Error: kubectl cannot reach the cluster (KUBECONFIG='$KUBECONFIG')."
        echo "Try: kubectl --kubeconfig \"$KUBECONFIG\" cluster-info"
        exit 1
    fi
}

if [ -z "$1" ]; then
    echo "No IP address provided, won't set up nip.io access."
else
    echo "Provided IP address is: $1, will set up nip.io access on https://grafana.$1.nip.io if email address is also provided."
    echo "This only works on Google Cloud and only if HTTP and HTTPS have been enabled."
    IP_ADDRESS=$1
fi

if [ -z "$2" ]; then
    echo "No email address provided, won't set up nip.io access."
else
    echo "Provided email address is: $2, will set up nip.io access on https://grafana.$1.nip.io"
    echo "This only works on Google Cloud and only if HTTP and HTTPS have been enabled."
    EMAIL_ADDRESS=$2
fi

if [ -z "$3" ]; then
    echo "No data directory provided, using the default /tmp/inkless-data"
    DATA_DIR="/tmp/inkless-data"
else
    echo "Provided data directory is: $3, using it for MinIO and Kafka data."
    DATA_DIR=$3
fi

if [ -z "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG environment variable is not set."
    exit 1
fi
if [ ! -r "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG points to a missing/unreadable file: $KUBECONFIG"
    exit 1
fi

require_cmd awk
require_cmd cut
require_cmd docker
require_cmd git
require_cmd helm
require_cmd java
require_cmd jq
require_cmd kubectl
require_cmd mktemp
require_cmd sed
require_cmd sudo
require_cmd hostname

K3S_AVAILABLE=false
if have_cmd k3s; then
    K3S_AVAILABLE=true
    echo "Found k3s; K3s image import will be available."
else
    echo "k3s not found; will skip K3s image import (make sure your cluster can pull the Kafka image)."
fi

JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)

if [ "$JAVA_VER" = "21" ]; then
    echo "Found Java 21"
else
    echo "Java 21 required, but found version: $JAVA_VER"
    exit 1
fi

if docker info >/dev/null 2>&1; then
    echo "Docker is running and accessible."
else
    echo "Docker is installed but the daemon is not running or you lack permissions."
    exit 1
fi

require_kube_access

echo "Required tools are installed (git/jq/helm/kubectl/docker/java) and cluster is reachable."

# Add required Helm repos
helm repo add strimzi https://strimzi.io/charts/
helm repo add minio https://charts.min.io/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

function k3s_has_image() {
  IMAGE_REF="$1"
  if [ "$K3S_AVAILABLE" != "true" ]; then
    return 1
  fi

  if sudo k3s ctr images list -q >/dev/null 2>&1; then
    sudo k3s ctr images list -q | awk -v img="$IMAGE_REF" '$0==img {found=1} END {exit !found}'
    return $?
  fi

  # Backward compatibility with ctr versions that use `ls`
  if sudo k3s ctr images ls -q >/dev/null 2>&1; then
    sudo k3s ctr images ls -q | awk -v img="$IMAGE_REF" '$0==img {found=1} END {exit !found}'
    return $?
  fi

  return 1
}

function ensure_kafka_image_available() {
  KAFKA_IMAGE="strimzi/kafka:build-kafka-4.0.0"

  if ! docker image inspect "$KAFKA_IMAGE" >/dev/null 2>&1; then
    echo "Error: Docker image '$KAFKA_IMAGE' not found locally."
    echo "The Strimzi build step may have failed."
    exit 1
  fi

  if [ "$K3S_AVAILABLE" != "true" ]; then
    echo "k3s not found; skipping import of '$KAFKA_IMAGE'."
    return 0
  fi

  if k3s_has_image "$KAFKA_IMAGE"; then
    echo "K3s already has '$KAFKA_IMAGE'; skipping image import."
    return 0
  fi

  echo "Importing '$KAFKA_IMAGE' into K3s..."
  docker save "$KAFKA_IMAGE" | sudo k3s ctr images import -
}

function install_helm_package() {
  NAMESPACE="$1"
  RELEASE_NAME="$2"
  CHART_NAME="$3"
  # Pass values files and other flags via extra args, e.g.:
  # install_helm_package ns rel chart -f values.yaml --set foo=bar
  shift 3
  EXTRA_HELM_ARGS=("$@")
  STATUS=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" --output json 2>/dev/null | jq -r '.info.status')
  # Wait for the chart's resources to become ready before returning.
  # Can be overridden via HELM_WAIT_TIMEOUT (e.g. "5m", "15m", "600s").
  HELM_WAIT_TIMEOUT="${HELM_WAIT_TIMEOUT:-10m}"
  HELM_WAIT_ARGS=(--wait --timeout "${HELM_WAIT_TIMEOUT}" --wait-for-jobs)

  if [ -z "$STATUS" ]; then
    echo "$RELEASE_NAME not found. Installing fresh..."
    helm install "$RELEASE_NAME" "$CHART_NAME" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      "${HELM_WAIT_ARGS[@]}" \
      "${EXTRA_HELM_ARGS[@]}"

  elif [ "$STATUS" == "failed" ]; then
    echo "$RELEASE_NAME installation is in a FAILED state. Uninstalling and reinstalling..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" \
      --wait \
      --timeout "${HELM_WAIT_TIMEOUT}"

    helm install "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        "${HELM_WAIT_ARGS[@]}" \
        "${EXTRA_HELM_ARGS[@]}"

  else
    echo "$RELEASE_NAME is currently '$STATUS'. Performing an upgrade to apply changes..."
    helm upgrade "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        "${HELM_WAIT_ARGS[@]}" \
        "${EXTRA_HELM_ARGS[@]}"
  fi
}

function install_minio() {

  cd $SCRIPT_DIR

  mkdir -p $DATA_DIR/minio

  # Read the template and replace placeholders
  TEMP_PVC_FILE=$(mktemp)
  sed "s|__DATA_DIR__|$DATA_DIR|g; s|__HOSTNAME__|$(hostname)|g" minio-pvc-template.yaml > "$TEMP_PVC_FILE"

  kubectl create namespace minio

  kubectl apply -f minio-sc.yaml -n "minio"
  kubectl apply -f "$TEMP_PVC_FILE" -n "minio"
  
  rm -f "$TEMP_PVC_FILE"

  install_helm_package "minio" "minio" "minio/minio" -f "minio-helm.yaml"

  kubectl exec -n minio deploy/minio -- /bin/sh -c "mc alias set local http://localhost:9000 admin password123 && \
 mc mb local/inkless-bucket"

  echo "Installed MinIO"
}

function install_monitoring() {
  cd $SCRIPT_DIR

  install_helm_package "monitoring" "prometheus-stack" "prometheus-community/kube-prometheus-stack" -f monitoring-helm.yaml
  kubectl apply -f grafana-dashboard-config.yaml -n monitoring
  echo "Installed Prometheus and Grafana"
}

function install_https() {
  cd $SCRIPT_DIR

  TEMP_LETSENCRYPT_FILE=$(mktemp)

  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
  echo "Waiting for cert-manager to be ready..."
  kubectl wait --namespace cert-manager \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/instance=cert-manager \
    --timeout=120s
  
  sed "s|__EMAIL_ADDRESS__|$EMAIL_ADDRESS|g" lets-encrypt.yaml > "$TEMP_LETSENCRYPT_FILE"
  kubectl apply -f "$TEMP_LETSENCRYPT_FILE"
  rm -f "$TEMP_LETSENCRYPT_FILE"

  TEMP_GRAFANA_INGRESS_FILE=$(mktemp)
  sed "s|__IP_ADDRESS__|$IP_ADDRESS|g" grafana-ingress-template.yaml > "$TEMP_GRAFANA_INGRESS_FILE"
  kubectl apply -f "$TEMP_GRAFANA_INGRESS_FILE" -n monitoring
  rm -f "$TEMP_LETSENCRYPT_FILE"
}

function install_postgres() {
  install_helm_package "kafka" "inkless-postgres" "bitnami/postgresql" \
    -f postgres-helm.yaml

  echo "Installed Postgres"
}

# Install Strimzi, then build it to compile the Inkless Kafka image
function install_strimzi() {
  kubectl create namespace strimzi
  kubectl create namespace kafka

  sudo apt-get install -y make wget maven shellcheck
  sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq

  STRIMZI_DIR="/tmp/strimzi-kafka-operator"

  if [ ! -d "$STRIMZI_DIR" ]; then
    echo "Cloning Strimzi Kafka Operator into $STRIMZI_DIR ..."
    git clone https://github.com/viktorsomogyi/strimzi-kafka-operator.git "$STRIMZI_DIR"
  fi

  cd "$STRIMZI_DIR"
  git checkout inkless-compat

  echo "Building Strimzi Kafka Operator and image..."
  make -C kafka-agent MVN_ARGS='-DskipTests' java_build
  make -C tracing-agent MVN_ARGS='-DskipTests' java_build
  make -C docker-images/artifacts MVN_ARGS='-DskipTests' java_build
  make -C docker-images/base MVN_ARGS='-DskipTests' docker_build
  make -C docker-images/kafka-based MVN_ARGS='-DskipTests' docker_build
  
  # Make sure the Kafka 4.0.0 image is available before installing Strimzi/Kafka.
  ensure_kafka_image_available

  install_helm_package "strimzi" "strimzi-operator" "strimzi/strimzi-kafka-operator" \
    --set "watchNamespaces={strimzi,kafka}"

  echo "Installed Strimzi"
  cd $SCRIPT_DIR
}

function install_kafka() {
  cd $SCRIPT_DIR

  # Ensure the Kafka image is present before creating Kafka resources.
  ensure_kafka_image_available

  kubectl apply -f kafka.yaml -n kafka
  kubectl apply -f hpa.yaml -n kafka
  kubectl apply -f pod-monitor.yaml -n kafka
  kubectl apply -f cc-rebalance.yaml -n kafka

  echo "Installed Kafka"
}

function start_load_testing() {
  cd $SCRIPT_DIR
  kubectl apply -f load-test-topic.yaml -n kafka
  kubectl apply -f kafka-clients.yaml -n kafka
}

install_minio
install_monitoring
install_postgres
install_strimzi
install_kafka

if [[ -n "$IP_ADDRESS" && -n "$EMAIL_ADDRESS" ]]; then
  install_https $IP_ADDRESS $EMAIL_ADDRESS
fi