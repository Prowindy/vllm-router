#!/bin/bash

# Script to deploy local vllm-router changes to Kubernetes pod
set -e

echo "🔄 Deploying local vllm-router changes to Kubernetes..."

# Check if pod exists and is running
if ! kubectl get pod vllm-router >/dev/null 2>&1; then
    echo "❌ vllm-router pod not found. Please run: kubectl apply -f vllm-router-local.yaml"
    exit 1
fi

# Check if pod is ready
if ! kubectl wait --for=condition=ready pod/vllm-router --timeout=10s >/dev/null 2>&1; then
    echo "❌ vllm-router pod is not ready. Please check pod status."
    exit 1
fi

echo "📁 Copying local source files to pod..."
kubectl cp . vllm-router:/workspace/vllm-router --no-preserve=true

echo "🏗️ Building and starting vllm-router in pod..."
kubectl exec vllm-router -- bash -c '
set -e
cd /workspace/vllm-router

# Kill any existing vllm-router process
pkill -f vllm-router || true

echo "Installing system dependencies..."
apt-get update -qq && apt-get install -y -qq \
    curl \
    git \
    build-essential \
    gcc \
    libc6-dev \
    pkg-config \
    libssl-dev

echo "Installing Rust..."
if [ ! -d "$HOME/.cargo" ]; then
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source $HOME/.cargo/env

echo "Building vllm-router..."
cargo build --release

echo "Starting vllm-router..."
nohup ./target/release/vllm-router \
    --host 0.0.0.0 \
    --port 8080 \
    --worker-urls http://10.100.31.179:8000 \
    --prometheus-host 0.0.0.0 \
    --prometheus-port 29000 \
    --log-level info \
    > /tmp/vllm-router.log 2>&1 &

echo "vllm-router started with PID $!"
sleep 2
if pgrep -f vllm-router > /dev/null; then
    echo "✅ vllm-router is running successfully"
else
    echo "❌ vllm-router failed to start. Check logs:"
    tail -20 /tmp/vllm-router.log
    exit 1
fi
'

echo "✅ Local changes deployed successfully!"
echo "🔍 Check status with: kubectl logs vllm-router"
echo "🌐 Access router at: http://35.93.104.231:30081"
echo "📊 Metrics at: http://35.93.104.231:30082"
