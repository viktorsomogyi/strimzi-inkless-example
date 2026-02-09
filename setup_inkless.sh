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

if [ -z "$IP_ADDRESS" ]; then
    echo "No IP address provided, won't set up nip.io access."
else
    echo "Provided IP address is: $IP_ADDRESS, will set up nip.io access on https://grafana.$IP_ADDRESS.nip.io if email address is also provided."
    echo "This only works on Google Cloud and only if HTTP and HTTPS have been enabled."
fi

if [ -z "$EMAIL_ADDRESS" ]; then
    echo "No email address provided, won't set up nip.io access."
else
    echo "Provided email address is: $EMAIL_ADDRESS, will set up nip.io access on https://grafana.$IP_ADDRESS.nip.io"
    echo "This only works on Google Cloud and only if HTTP and HTTPS have been enabled."
fi

if [ -z "$DATA_DIR" ]; then
    echo "No data directory provided, using the default /tmp/inkless-data"
    DATA_DIR="/tmp/inkless-data"
else
    echo "Provided data directory is: $DATA_DIR, using it for MinIO and Kafka data."
fi

# Kernel machine type: x86_64, aarch64, arm64, armv7l, etc.
if [ -z "$ARCHITECTURE" ]; then
  case "$(uname -m)" in
    x86_64|amd64)   ARCHITECTURE=amd64 ;;
    aarch64|arm64)  ARCHITECTURE=arm64 ;;
    *)              echo "Error: Unsupported architecture: $(uname -m)" && exit 1 ;;
  esac
fi

# Kafka image: multi-arch tag so the right image is pulled for amd64/arm64 (see DEVELOPMENT.md to build and push your own).
KAFKA_IMAGE="${KAFKA_IMAGE:-ghcr.io/viktorsomogyi/strimzi-inkless:4.1.1-0.34}"

if [ -z "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG environment variable is not set."
    exit 1
fi
if [ ! -r "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG points to a missing/unreadable file: $KUBECONFIG"
    exit 1
fi

require_cmd helm
require_cmd jq
require_cmd kubectl
require_cmd mktemp
require_cmd sed
require_cmd hostname

require_kube_access

echo "Required tools are installed (helm/kubectl/jq) and cluster is reachable."

# Add required Helm repos
helm repo add strimzi https://strimzi.io/charts/
helm repo add minio https://charts.min.io/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

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
  NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  sed "s|__DATA_DIR__|$DATA_DIR|g; s|__HOSTNAME__|$NODE_NAME|g" minio-pvc-template.yaml > "$TEMP_PVC_FILE"

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
  kubectl apply -f postgres-pod-monitor.yaml -n kafka

  echo "Installed Postgres"
}

# Install Strimzi Kafka Operator (Kafka image is pulled from GHCR; see DEVELOPMENT.md to build/push).
function install_strimzi() {
  kubectl create namespace strimzi
  kubectl create namespace kafka

  install_helm_package "strimzi" "strimzi-operator" "strimzi/strimzi-kafka-operator" \
    --set "watchNamespaces={strimzi,kafka}"

  echo "Installed Strimzi"
}

function install_kafka() {
  cd $SCRIPT_DIR

  TEMP_KAFKA_FILE=$(mktemp)
  sed "s|__KAFKA_IMAGE__|$KAFKA_IMAGE|g" kafka.yaml > "$TEMP_KAFKA_FILE"
  kubectl apply -f "$TEMP_KAFKA_FILE" -n kafka
  rm -f "$TEMP_KAFKA_FILE"
  kubectl apply -f hpa.yaml -n kafka
  kubectl apply -f pod-monitor.yaml -n kafka
  kubectl apply -f cc-rebalance.yaml -n kafka

  echo "Installed Kafka"
}

function start_load_testing() {
  cd $SCRIPT_DIR
  kubectl apply -f load-test-topic.yaml -n kafka
  TEMP_CLIENTS_FILE=$(mktemp)
  sed "s|__KAFKA_IMAGE__|$KAFKA_IMAGE|g" kafka-clients.yaml > "$TEMP_CLIENTS_FILE"
  kubectl apply -f "$TEMP_CLIENTS_FILE" -n kafka
  rm -f "$TEMP_CLIENTS_FILE"
}

install_minio
install_monitoring
install_postgres
install_strimzi
install_kafka

if [[ -n "$IP_ADDRESS" && -n "$EMAIL_ADDRESS" ]]; then
  install_https $IP_ADDRESS $EMAIL_ADDRESS
  echo "Inkless setup complete. Access Grafana at https://grafana.$IP_ADDRESS.nip.io"
fi

echo "--------------------------------"
echo "Grafana username: admin"
echo "Grafana password: $(kubectl get secret -n monitoring prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo)"
echo "Port-forward Grafana to localhost:3000: kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80"
echo "Port-forward Prometheus to localhost:9090: kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090"
echo "--------------------------------"
echo "MinIO username: admin"
echo "MinIO password: $(kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d; echo)"
echo "Port-forward MinIO console to localhost:9001: kubectl port-forward -n minio svc/minio 9001:9001"
echo "--------------------------------"
echo "Postgres username: inkless-username"
echo "Postgres password: $(kubectl get secret -n kafka inkless-postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d; echo)"
echo "Port-forward Postgres to localhost:5432: kubectl port-forward -n kafka svc/inkless-postgres-postgresql 5432:5432"
echo "--------------------------------"