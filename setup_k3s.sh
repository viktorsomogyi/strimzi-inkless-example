#!/bin/bash

# Setup Kubeconfig environment variable
K3S_CONFIG="/etc/rancher/k3s/k3s.yaml"
if [[ "$KUBECONFIG" != "$K3S_CONFIG" ]]; then
    echo "Setting up KUBECONFIG environment variable..."
    export KUBECONFIG=$K3S_CONFIG
    if ! grep -q "export KUBECONFIG=$K3S_CONFIG" ~/.bashrc; then
        echo "export KUBECONFIG=$K3S_CONFIG" >> ~/.bashrc
    fi
fi

# Check/Install Helm
if command -v helm &> /dev/null; then
    echo "Helm is already installed: $(helm version --short)"
else
    echo "Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
fi

# Final verification of Traefik (K3s default)
echo "Waiting for Traefik to be ready..."
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=traefik \
  --timeout=90s

echo "Setup complete!"