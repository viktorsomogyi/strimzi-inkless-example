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

Before running the build script, ensure you have:

- **Docker**: Installed and running (the daemon must be accessible)
- **Java 21**: Required for building Strimzi
- **Git**: For cloning repositories
- **Maven**: For building Strimzi
- **Kubernetes cluster**: The script installs K3s if not present, but you can use any Kubernetes cluster

### Quick Setup (Debian/Ubuntu)

For Debian Bookworm systems, use the provided setup script:

```bash
./setup_debian_bookworm.sh
```

This script installs:
- Java 21 (via SDKMAN)
- Docker CE
- Maven, Git, and other build tools

## Installation

### Basic Installation

Run the build script to set up the entire stack:

```bash
./build.sh
```

This will:
1. Install and configure K3s (if not already present)
2. Install Helm and required repositories
3. Deploy MinIO for S3 storage
4. Deploy PostgreSQL for Inkless control plane
5. Deploy Prometheus and Grafana monitoring stack
6. Build Strimzi with Inkless Kafka integration
7. Deploy the Kafka cluster with autoscaling

### Installation with HTTPS Access (Google Cloud)

If you're running on Google Cloud and want HTTPS access to Grafana:

```bash
./build.sh <YOUR_IP_ADDRESS> <YOUR_EMAIL_ADDRESS>
```

This will:
- Set up cert-manager for TLS certificates
- Configure Let's Encrypt for automatic certificate provisioning
- Create an ingress for Grafana at `https://grafana.<IP_ADDRESS>.nip.io`

## Project Structure

```
.
├── build.sh                      # Main installation script
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

## Load Testing

To start load testing and observe autoscaling in action:

```bash
kubectl apply -f load-test-topic.yaml -n kafka
kubectl apply -f kafka-clients.yaml -n kafka
```

This creates:
- A test topic (`load-test`) with 100 partitions configured for diskless storage
- Multiple producer and consumer jobs that generate significant load

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
Then open `http://localhost:3000` (default credentials: `admin` / `prom-operator`)

**HTTPS Access** (if configured):
Open `https://grafana.<YOUR_IP>.nip.io` in your browser

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

# Remove Helm releases
helm uninstall strimzi-operator -n strimzi
helm uninstall minio -n minio
helm uninstall prometheus-stack -n monitoring
helm uninstall inkless-postgres -n kafka

# Remove namespaces
kubectl delete namespace kafka strimzi minio monitoring
```

## References

- [Strimzi Kafka Operator](https://strimzi.io/)
- [Aiven Inkless](https://github.com/aiven/inkless)
- [KIP-1150: Diskless Storage](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1150)
- [Cruise Control](https://github.com/linkedin/cruise-control)

## License

See [LICENSE](LICENSE) file for details.
