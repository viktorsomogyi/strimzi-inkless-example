# Strimzi Inkless Example

A complete demonstration of **Aiven's Inkless** (a KIP-1150 implementation) running on a **Strimzi Kafka cluster** with CPU-based elastic autoscaling. This project showcases how to deploy a diskless Kafka cluster that uses S3-compatible storage (MinIO) instead of local disk, enabling true stateless Kafka brokers that can scale horizontally based on CPU utilization.

## Overview

This example demonstrates:

- **Diskless Kafka Storage**: Kafka brokers that store data in S3 (via MinIO) instead of local disk, enabling stateless broker deployments
- **CPU-Based Autoscaling**: Horizontal Pod Autoscaler (HPA) that automatically scales Kafka brokers based on CPU utilization
- **KRaft Mode**: Kafka cluster running in KRaft mode (no Zookeeper dependency)
- **Node Pools**: Separate controller and broker node pools for better resource management
- **Monitoring**: Full Prometheus and Grafana stack for metrics and observability
- **Cruise Control Integration**: Automated partition rebalancing when brokers are added or removed

## Architecture

The deployment consists of:

- **Kafka Cluster** (`inkless-cluster`): 
  - 3 controller nodes (KRaft controllers)
  - 3-9 broker nodes (scales automatically based on CPU)
  - Controllers and brokers use **ephemeral** Kubernetes storage (no local disks on brokers)
  - Configured with Inkless storage backend pointing to MinIO S3
  
- **Storage Backend**:
  - **MinIO**: S3-compatible object storage for Kafka data
  - **PostgreSQL**: Control plane database for Inkless metadata
  
- **Monitoring Stack**:
  - **Prometheus**: Metrics collection
  - **Grafana**: Visualization dashboards
  - **Kafka Exporter**: Kafka-specific metrics
  
- **Autoscaling**:
  - **HPA**: Scales broker pool from 3 to 9 replicas based on CPU utilization (target: 30%)
  - **Cruise Control**: Automatically rebalances partitions when brokers scale up/down

## Prerequisites

Before running the setup scripts, ensure you have:

- **kubectl**: Required by all Kubernetes apply/wait steps
- **Helm**: Required for installing Strimzi/MinIO/monitoring/PostgreSQL charts
- **Docker**: Installed and running (the daemon must be accessible)
- **Java 21**: Required for building Strimzi
- **Git**: For cloning repositories
- **curl**: Required by `setup_k3s.sh` (downloads K3s and Helm install script)
- **Build tools for the Strimzi build**: `make` + `maven` + `wget` (on Debian/Ubuntu, `setup_inkless.sh` installs these via `apt-get`)
- **jq**: Required by `setup_inkless.sh` (used to detect Helm release status)
- **sudo**: `setup_inkless.sh` uses `sudo` (K3s image import and installing build tools on Debian/Ubuntu)
- **Kubernetes cluster**: This repo is optimized for K3s on Linux (Debian/Ubuntu). You can adapt it to other clusters, but the scripts assume `systemctl`, `apt-get`, and `sudo`.

### Important assumptions (current script behavior)

- **Run from the repo root**: `setup_inkless.sh` expects to be executed with the current directory set to this repo (it uses `$(pwd)` as its working directory).
- **Single-node local PV for MinIO**: MinIO persistence is configured via a **local** `PersistentVolume` with `nodeAffinity` pinned to the node hostname (see `minio-pvc-template.yaml`). On multi-node clusters you must adapt PV/PVC/storage accordingly.
- **Kafka image is built locally**: The Kafka image used by the cluster and load tests is `strimzi/kafka:build-kafka-4.0.0` (see `kafka.yaml` and `kafka-clients.yaml`).
  - On **K3s**, `setup_inkless.sh` will import this image into the K3s container runtime if `k3s` is present.
  - On **non-K3s** clusters, you must ensure your nodes can pull the image (e.g., push it to a registry and update `kafka.yaml`).

### Quick Setup (Debian/Ubuntu)

For Google Cloud Debian Bookworm systems, use the provided setup script:

```bash
./setup_debian_bookworm.sh
```

This script installs:
- Java 21 (via SDKMAN)
- Docker CE
- Maven, Git, and other build tools
- `jq`

If you used this script, you may need to run `source "~/.sdkman/bin/sdkman-init.sh"` to initialize sdk-man in you current shell as otherwise Java 21 might not be available.

## Installation

The installation process is split into two steps:

### Step 1: Setup K3s and Helm

First, set up your Kubernetes cluster (K3s) and Helm:

```bash
./setup_k3s.sh
```

This script will:
1. Install K3s (if not already running)
2. Configure KUBECONFIG environment variable (sets it to `/etc/rancher/k3s/k3s.yaml`)
3. Install Helm (if not already installed)
4. Wait for Traefik (K3s default ingress controller) to be ready

**Note**: 
- If K3s is already installed and running, this script will skip installation and only configure Helm and KUBECONFIG
- The KUBECONFIG export is appended to `~/.bashrc` for persistence across sessions (if you use `zsh`, copy it to `~/.zshrc` instead)
- You may need to run `source ~/.bashrc` (or start a new terminal session) after running this script

### Step 2: Deploy Inkless + Strimzi + dependencies

Once K3s and Helm are set up, run the main deployment script:

```bash
./setup_inkless.sh
```

This will:
1. Verify prerequisites (including `kubectl`, `helm`, `docker`, `java`, `git`, `jq`, and cluster access)
2. Require `KUBECONFIG` to be set (for K3s this is typically `/etc/rancher/k3s/k3s.yaml`)
3. Add required Helm repositories (Strimzi, MinIO, Prometheus, Bitnami)
4. Deploy MinIO for S3 storage
5. Deploy PostgreSQL for Inkless control plane
6. Deploy Prometheus and Grafana monitoring stack
7. Clone and build a Strimzi fork/branch (`viktorsomogyi/strimzi-kafka-operator`, branch `inkless-compat`) to produce a local Kafka image (`strimzi/kafka:build-kafka-4.0.0`)
8. Import that Kafka image into K3s (when available) so the cluster can start without pulling from a registry
9. Deploy the Kafka cluster, HPA, PodMonitor, and Cruise Control auto-rebalance template

#### Script arguments

`setup_inkless.sh` supports optional arguments in this order:

- **arg1**: Public IP address (used only for optional Grafana HTTPS via `nip.io`)
- **arg2**: Email address (used for Let’s Encrypt / cert-manager)
- **arg3**: Host data directory for the **MinIO local PV** (default: `/tmp/inkless-data`)

Examples:

```bash
# Default (uses /tmp/inkless-data)
./setup_inkless.sh

# Custom data directory only
./setup_inkless.sh "" "" /var/lib/inkless-data

# Enable HTTPS for Grafana (Google Cloud + HTTP/HTTPS enabled)
./setup_inkless.sh <YOUR_IP_ADDRESS> <YOUR_EMAIL_ADDRESS>
```

## Default credentials (and how to extract them)

This repo uses **static defaults** in the scripts/values files (meant for demos). After installing, you can also **read them from Kubernetes Secrets**.

### MinIO (S3 backend)

- **Namespace / release**: `minio` / `minio`
- **Default**: user `admin`, password `password123` (see `minio-helm.yaml`)

Extract from Kubernetes:

```bash
kubectl get secret -n minio minio -o jsonpath='{.data.rootUser}' | base64 -d; echo
kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d; echo
```

### PostgreSQL (Inkless control plane)

- **Namespace / release**: `kafka` / `inkless-postgres`
- **Default Inkless DB user**: `inkless-username`
- **Default Inkless DB password**: `mysecretpassword` (set in `setup_inkless.sh`)
- **Default `postgres` (admin) password**: `admin-password` (set in `setup_inkless.sh`)

Extract from Kubernetes:

```bash
# Password for auth.username (inkless-username)
kubectl get secret -n kafka inkless-postgres-postgresql -o jsonpath='{.data.password}' | base64 -d; echo

# Password for the postgres superuser
kubectl get secret -n kafka inkless-postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d; echo
```

### Grafana

- **Namespace / release**: `monitoring` / `prometheus-stack`

Extract from Kubernetes:

```bash
kubectl get secret -n monitoring prometheus-stack-grafana -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret -n monitoring prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

If any of the secret keys differ in your cluster (chart version changes), print all keys:

```bash
kubectl get secret -n minio minio -o jsonpath='{.data}'; echo
kubectl get secret -n kafka inkless-postgres-postgresql -o jsonpath='{.data}'; echo
kubectl get secret -n monitoring prometheus-stack-grafana -o jsonpath='{.data}'; echo
```

### Installation with HTTPS Access (Google Cloud)

If you're running on Google Cloud and want HTTPS access to Grafana:

```bash
# Step 1: Setup K3s and Helm
./setup_k3s.sh

# Step 2: Deploy with HTTPS
./setup_inkless.sh <YOUR_IP_ADDRESS> <YOUR_EMAIL_ADDRESS>
```

This will:
- Set up cert-manager for TLS certificates
- Configure Let's Encrypt for automatic certificate provisioning
- Create an ingress for Grafana at `https://grafana.<IP_ADDRESS>.nip.io`

## Project Structure

```
.
├── setup_k3s.sh                  # K3s and Helm setup script
├── setup_inkless.sh              # Deploy Inkless + dependencies + Kafka
├── setup_debian_bookworm.sh      # Debian/Ubuntu prerequisites setup
├── kafka.yaml                    # Kafka cluster configuration
├── hpa.yaml                      # Horizontal Pod Autoscaler configuration
├── kafka-clients.yaml            # Load testing producer/consumer jobs
├── load-test-topic.yaml          # Test topic with diskless configuration
├── cc-rebalance.yaml             # Cruise Control rebalancing templates
├── pod-monitor.yaml              # Prometheus PodMonitor for Kafka metrics
├── minio-helm.yaml               # MinIO Helm chart values
├── minio-pvc-template.yaml       # MinIO persistent volume claim template
├── minio-sc.yaml                 # MinIO storage class
├── monitoring-helm.yaml          # Prometheus/Grafana Helm chart values
├── grafana-dashboard-config.yaml # Kafka dashboard ConfigMap for Grafana sidecar (installed by setup_inkless.sh)
├── grafana-ingress-template.yaml # Grafana ingress template (for HTTPS)
└── lets-encrypt.yaml             # cert-manager ClusterIssuer template
```

## Key Configuration Details

### Kafka Configuration

The Kafka cluster is configured with:

- **Version**: 4.0.0 (with Inkless)
- **Storage**: Diskless mode enabled with S3 backend
- **Listeners**: 
  - Internal listener on port 9092 (cluster-internal)
  - External NodePort listener on port 32094 (for external clients)
- **KRaft**: Enabled with metadata version 4.0-IV0
- **Node Pools**: Separate pools for controllers and brokers

### Autoscaling Configuration

- **Min Replicas**: 3 brokers
- **Max Replicas**: 9 brokers
- **Target CPU Utilization**: 30%
- **Scale Up/Down**: 1 pod per 60 seconds

### Storage Configuration

- **Backend**: MinIO S3-compatible storage
- **Bucket**: `inkless-bucket`
- **Control Plane**: PostgreSQL database for metadata
- **MinIO persistence**: A local PersistentVolume at `<DATA_DIR>/minio` on the Kubernetes node (default: `/tmp/inkless-data/minio`). Override `<DATA_DIR>` via the 3rd argument to `setup_inkless.sh`.

## Load Testing

To start load testing and observe autoscaling in action:

```bash
kubectl apply -f load-test-topic.yaml -n kafka
kubectl apply -f kafka-clients.yaml -n kafka
```

This creates:
- A test topic (`load-test`) with 100 partitions configured for diskless storage
- Multiple producer and consumer **Jobs** that generate significant load (they run until completion or failure)

If you want to re-run the jobs, delete them first:

```bash
kubectl delete job -n kafka kafka-producer kafka-consumer kafka-consumer2
kubectl apply -f kafka-clients.yaml -n kafka
```

Watch the broker pool scale up as CPU utilization increases:

```bash
kubectl get hpa kafka-hpa -n kafka -w
kubectl get pods -n kafka -l strimzi.io/cluster=inkless-cluster
```

## Monitoring

### Accessing Grafana

**Local Access**:
```bash
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
```
Then open `http://localhost:3000`.

For Grafana username/password, see **Default credentials (and how to extract them)** above.

**HTTPS Access** (if configured):
Open `https://grafana.<YOUR_IP>.nip.io` in your browser

### Kafka dashboard

`setup_inkless.sh` applies `grafana-dashboard-config.yaml` automatically. If you want to re-apply it (or apply updates), run:

```bash
kubectl apply -f grafana-dashboard-config.yaml
```

### Key Metrics

The monitoring stack collects:
- Kafka broker metrics (CPU, memory, network)
- Topic and partition metrics
- Consumer lag
- Cruise Control metrics
- Kubernetes pod metrics

## How It Works

1. **Inkless Storage**: Kafka brokers use the Inkless storage backend to read/write data directly to S3 (MinIO) instead of local disk. This makes brokers truly stateless.

2. **Autoscaling**: 
   - HPA monitors CPU utilization of broker pods
   - When CPU exceeds 30%, HPA scales up the broker pool
   - Cruise Control detects new brokers and rebalances partitions
   - When CPU drops, HPA scales down and Cruise Control moves partitions off removed brokers

3. **Rebalancing**: Cruise Control is configured with auto-rebalance templates that handle both scale-up (add-brokers) and scale-down (remove-brokers) scenarios automatically.

## Troubleshooting

### KUBECONFIG Not Set

If you encounter `kubectl` or `helm` commands failing with connection errors, ensure KUBECONFIG is set:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

Or run `setup_k3s.sh` which will configure this automatically.

### Check Kafka Cluster Status
```bash
kubectl get kafka inkless-cluster -n kafka
kubectl get pods -n kafka
```

### Check HPA Status
```bash
kubectl describe hpa kafka-hpa -n kafka
```

### View Kafka Logs
```bash
kubectl logs -n kafka -l strimzi.io/cluster=inkless-cluster --tail=100
```

### Check MinIO Connection
```bash
kubectl exec -n minio deploy/minio -- mc ls local/inkless-bucket
```

### Verify PostgreSQL Connection
```bash
kubectl exec -n kafka -it $(kubectl get pod -n kafka -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- psql -U inkless-username -d inkless-db
```

## Cleanup

To remove all components:

```bash
# Remove Kafka resources
kubectl delete -f kafka-clients.yaml -n kafka
kubectl delete -f load-test-topic.yaml -n kafka
kubectl delete -f kafka.yaml -n kafka
kubectl delete -f hpa.yaml -n kafka
kubectl delete -f pod-monitor.yaml -n kafka
kubectl delete -f cc-rebalance.yaml -n kafka

# Remove Grafana dashboard ConfigMap (optional)
kubectl delete -f grafana-dashboard-config.yaml

# Remove Helm releases
helm uninstall strimzi-operator -n strimzi
helm uninstall minio -n minio
helm uninstall prometheus-stack -n monitoring
helm uninstall inkless-postgres -n kafka

# Remove namespaces
kubectl delete namespace kafka strimzi minio monitoring
```

If you enabled HTTPS via `setup_inkless.sh <IP> <EMAIL>`, you may also want to remove cert-manager and the ClusterIssuer:

```bash
kubectl delete ingress -n monitoring grafana-ingress
kubectl delete clusterissuer letsencrypt-prod
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

## References

- [Strimzi Kafka Operator](https://strimzi.io/)
- [Aiven Inkless](https://github.com/aiven/inkless)
- [KIP-1150: Diskless Storage](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1150)
- [Cruise Control](https://github.com/linkedin/cruise-control)

## License

See [LICENSE](LICENSE) file for details.
