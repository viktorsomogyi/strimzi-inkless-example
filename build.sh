#!/bin/bash

SCRIPT_DIR=`pwd`

JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)

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

if [ -z "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG environment variable is not set."
    exit 1
fi

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

if ! command -v "git" >/dev/null 2>&1; then
    echo "Error: git is not installed."
    return 1
else
    echo "git is installed."
fi

# Install k3s
if systemctl is-active --quiet k3s; then
    echo "K3s is already running."
else
    echo "Installing K3s..."
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi

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
  VALUES_FILE="$4"
  STATUS=$(helm status $RELEASE_NAME -n $NAMESPACE --output json 2>/dev/null | jq -r '.info.status')

  if [ -z "$STATUS" ]; then
    echo "$RELEASE_NAME not found. Installing fresh..."
    helm install $RELEASE_NAME $CHART_NAME \
      --namespace $NAMESPACE \
      --create-namespace \
      -f $VALUES_FILE

  elif [ "$STATUS" == "failed" ]; then
    echo "$RELEASE_NAME installation is in a FAILED state. Uninstalling and reinstalling..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE

    # Wait a moment for resources to clear
    sleep 5

    helm install $RELEASE_NAME $CHART_NAME \
        --namespace $NAMESPACE \
        -f $VALUES_FILE

  else
    echo "$RELEASE_NAME is currently '$STATUS'. Performing an upgrade to apply changes..."
    helm upgrade $RELEASE_NAME $CHART_NAME \
        --namespace $NAMESPACE \
        -f $VALUES_FILE
  fi
}

function install_minio() {

  cd $SCRIPT_DIR

  mkdir -p inkless-data/minio
  mkdir -p inkless-data/kafka

  # Read the template and replace placeholders
  TEMP_PVC_FILE=$(mktemp)
  sed "s|__SCRIPT_DIR__|$SCRIPT_DIR|g; s|__HOSTNAME__|$(hostname)|g" minio-pvc-template.yaml > "$TEMP_PVC_FILE"

  kubectl create namespace minio

  kubectl apply -f minio-sc.yaml -n "minio"
  kubectl apply -f "$TEMP_PVC_FILE" -n "minio"
  
  rm -f "$TEMP_PVC_FILE"

  install_helm_package "minio" "minio" "minio/minio" "minio-helm.yaml"

  kubectl exec -n minio deploy/minio -- /bin/sh -c "mc alias set local http://localhost:9000 admin password123 && \
 mc mb local/inkless-bucket"

  echo "Installed MinIO"
}

function install_monitoring() {
  cd $SCRIPT_DIR

  install_helm_package "monitoring" "prometheus-stack" "prometheus-community/kube-prometheus-stack" monitoring-helm.yaml
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
  helm install inkless-postgres bitnami/postgresql \
    --set global.postgresql.auth.password=mysecretpassword \
    --set primary.persistence.size=10Gi \
    --set auth.username=inkless-username \
    --set auth.database=inkless-db \
    --set auth.postgresPassword=admin-password \
    --namespace kafka

  echo "Installed Postgres"
}

# Install Strimzi, then build it to compile the Inkless Kafka image
function install_strimzi() {
  helm install strimzi-operator strimzi/strimzi-kafka-operator \
    --namespace strimzi \
    --set "watchNamespaces={strimzi,kafka}"

  sudo apt-get install -y make wget maven shellcheck
  sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq

  STRIMZI_DIR="/tmp/strimzi-kafka-operator"

  if [ ! -d "$STRIMZI_DIR" ]; then
    echo "Cloning Strimzi Kafka Operator into $STRIMZI_DIR ..."
    git clone https://github.com/strimzi/strimzi-kafka-operator.git "$STRIMZI_DIR"
  fi

  cd "$STRIMZI_DIR"
  git checkout inkless-compat

  cat << EOF > kafka-versions.yaml
 - version: 4.0.0
   metadata: 4.0
   url: https://github.com/aiven/inkless/releases/download/inkless-4.0.0-rc32/kafka_2.13-4.0.0-inkless.tgz
   checksum: 855b902678e60fa218805f49d809395d5c5c5ea5dcd7bab4440e05405d5a5931a397e65ea587e2a2389a0fde40fa16d33d3d8ea2abfc42b56ee093558868d1b0
   third-party-libs: 4.0.x
   supported: true
   default: false
EOF

  echo "Building Strimzi Kafka Operator..."
  make MVN_ARGS='-DskipTests' all
  cd docker-images/artifacts
  echo "Building Strimzi Kafka image..."
  ./build.sh
  echo "Importing Strimzi Kafka image into K3s..."
  cd ../../
  make docker_build

  docker save strimzi/kafka:build-kafka-4.0.0 | sudo k3s ctr images import -

  echo "Installed Strimzi"
  cd $SCRIPT_DIR
}

function install_kafka() {
  cd $SCRIPT_DIR

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