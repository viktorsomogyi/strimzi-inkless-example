#!/bin/bash
#
# Completely uninstalls what setup_inkless.sh installed:
# - Optional load-test topic and kafka-clients (if present)
# - Optional HTTPS: Grafana Ingress, ClusterIssuer, cert-manager (if present)
# - Kafka resources (Kafka CR, node pools, HPA, PodMonitor, KafkaRebalance, ConfigMap)
# - Strimzi operator
# - PostgreSQL (inkless-postgres in kafka namespace)
# - Monitoring stack (Prometheus, Grafana) and dashboard config
# - MinIO (helm release, PVC, PV, StorageClass, namespace)
# - Namespaces: minio, monitoring, kafka, strimzi, cert-manager (if present)
#
# Optional: set DATA_DIR environment variable (e.g. /tmp/inkless-data) to remove MinIO data on the host.
# Optional: --remove-https to also remove cert-manager and Grafana Ingress.
# Optional: --remove-load-test to also remove load-test topic and kafka-clients.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE_HTTPS=false
REMOVE_LOAD_TEST=false

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-https)
      REMOVE_HTTPS=true
      shift
      ;;
    --remove-load-test)
      REMOVE_LOAD_TEST=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function require_cmd() {
  if ! have_cmd "$1"; then
    echo "Error: '$1' is not installed or not on PATH."
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
    exit 1
  fi
}

if [ -z "$KUBECONFIG" ]; then
  echo "Error: KUBECONFIG environment variable is not set."
  exit 1
fi
if [ ! -r "$KUBECONFIG" ]; then
  echo "Error: KUBECONFIG points to a missing/unreadable file: $KUBECONFIG"
  exit 1
fi

require_cmd kubectl
require_cmd helm
require_cmd mktemp
require_cmd sed
require_kube_access

echo "Uninstalling Inkless stack (KUBECONFIG=$KUBECONFIG)..."

cd "$SCRIPT_DIR"

# --- Optional: load-test topic and kafka-clients ---
if [ "$REMOVE_LOAD_TEST" = true ]; then
  echo "Removing load-test topic and kafka-clients (if present)..."
  kubectl delete -f load-test-topic.yaml -n kafka --ignore-not-found --timeout=60s 2>/dev/null || true
  TEMP_CLIENTS_FILE=$(mktemp)
  sed 's|__KAFKA_IMAGE__|unused|g' kafka-clients.yaml > "$TEMP_CLIENTS_FILE"
  kubectl delete -f "$TEMP_CLIENTS_FILE" -n kafka --ignore-not-found --timeout=60s 2>/dev/null || true
  rm -f "$TEMP_CLIENTS_FILE"
  sed 's|__KAFKA_IMAGE__|unused|g' kafka-producer-ramp.yaml > "$TEMP_CLIENTS_FILE"
  kubectl delete -f "$TEMP_CLIENTS_FILE" -n kafka --ignore-not-found --timeout=60s 2>/dev/null || true
  rm -f "$TEMP_CLIENTS_FILE"
fi

# --- Optional: HTTPS (Grafana Ingress, ClusterIssuer, cert-manager) ---
if [ "$REMOVE_HTTPS" = true ]; then
  echo "Removing Grafana Ingress and cert-manager resources..."
  kubectl delete ingress grafana-ingress -n monitoring --ignore-not-found --timeout=30s 2>/dev/null || true
  kubectl delete clusterissuer letsencrypt-prod --ignore-not-found --timeout=30s 2>/dev/null || true
  kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml --ignore-not-found --timeout=120s 2>/dev/null || true
fi

# --- Kafka resources (must be removed before Strimzi so the operator can tear down) ---
echo "Stopping KafkaRebalance resources..."
kubectl get kafkarebalance -n kafka -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read -r rb; do
  if [ -n "$rb" ]; then
    echo "Processing: $rb"
    kubectl annotate kafkarebalance "$rb" strimzi.io/rebalance=stop --overwrite -n kafka
    kubectl delete kafkarebalance "$rb" -n kafka --ignore-not-found --timeout=30s 2>/dev/null || true
  fi
done

echo "Removing Kafka resources in kafka namespace..."
TEMP_KAFKA_FILE=$(mktemp)
sed 's|__KAFKA_IMAGE__|unused|g' kafka.yaml > "$TEMP_KAFKA_FILE"
kubectl delete -f "$TEMP_KAFKA_FILE" -n kafka --ignore-not-found --timeout=120s 2>/dev/null || true
rm -f "$TEMP_KAFKA_FILE"

kubectl delete -f hpa.yaml -n kafka --ignore-not-found --timeout=30s 2>/dev/null || true
kubectl delete -f pod-monitor.yaml -n kafka --ignore-not-found --timeout=30s 2>/dev/null || true
kubectl delete -f cc-rebalance.yaml -n kafka --ignore-not-found --timeout=30s 2>/dev/null || true

# Wait for Kafka cluster to be torn down before removing the operator
echo "Waiting for Kafka cluster to be removed..."
for i in $(seq 1 30); do
  if ! kubectl get kafka inkless-cluster -n kafka 2>/dev/null; then
    break
  fi
  echo "  waiting for Kafka CR to be deleted... ($i/30)"
  sleep 10
done

# --- Strimzi operator ---
echo "Uninstalling Strimzi operator..."
helm uninstall strimzi-operator -n strimzi --wait --timeout=5m 2>/dev/null || true

# --- PostgreSQL ---
echo "Uninstalling PostgreSQL (inkless-postgres)..."
helm uninstall inkless-postgres -n kafka --wait --timeout=5m 2>/dev/null || true
kubectl delete -f postgres-pod-monitor.yaml -n kafka --ignore-not-found --timeout=30s 2>/dev/null || true

# --- Monitoring stack ---
echo "Removing Grafana dashboard config and Prometheus stack..."
kubectl delete -f grafana-dashboard-config.yaml -n monitoring --ignore-not-found --timeout=30s 2>/dev/null || true
helm uninstall prometheus-stack -n monitoring --wait --timeout=5m 2>/dev/null || true

# --- MinIO ---
echo "Uninstalling MinIO..."
helm uninstall minio -n minio --wait --timeout=5m 2>/dev/null || true

# Remove PVCs in minio namespace (chart may leave them)
kubectl delete pvc -n minio --all --ignore-not-found --timeout=60s 2>/dev/null || true

# Remove PV created by minio-pvc-template (cluster-scoped)
kubectl delete pv minio-local-pv --ignore-not-found --timeout=30s 2>/dev/null || true

# StorageClass is cluster-scoped (may have been applied with -n minio but still cluster-scoped)
kubectl delete storageclass minio-local-storage --ignore-not-found --timeout=30s 2>/dev/null || true

# --- Namespaces ---
echo "Removing namespaces..."
for ns in minio monitoring kafka strimzi; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  deleting namespace $ns..."
    kubectl delete namespace "$ns" --timeout=120s --ignore-not-found 2>/dev/null || true
  fi
done

if [ "$REMOVE_HTTPS" = true ]; then
  if kubectl get namespace cert-manager >/dev/null 2>&1; then
    echo "  deleting namespace cert-manager..."
    kubectl delete namespace cert-manager --timeout=120s --ignore-not-found 2>/dev/null || true
  fi
fi

# --- Optional: remove host data directory ---
if [ -n "$DATA_DIR" ]; then
  MINIO_DATA="${DATA_DIR}/minio"
  if [ -d "$MINIO_DATA" ]; then
    echo "Removing host data directory: $MINIO_DATA"
    rm -rf "$MINIO_DATA"
  fi
else
  echo "No data directory provided, not removing MinIO data on the host."
fi

echo "Uninstall complete."
echo "Note: Helm repos (strimzi, minio, prometheus-community, bitnami) were not removed."
echo "      Remove them with: helm repo remove strimzi minio prometheus-community bitnami"
