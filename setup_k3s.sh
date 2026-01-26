#!/bin/bash

# Install k3s
if systemctl is-active --quiet k3s; then
    echo "K3s is already running."
else
    echo "Installing K3s..."
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi

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
sleep 5
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=traefik \
  --timeout=90s

echo "Setup complete!"
echo "Please run 'source ~/.bashrc' or 'export KUBECONFIG=$K3S_CONFIG' to update your current shell."