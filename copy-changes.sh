#!/bin/bash

# Quick script to copy local changes without full rebuild
set -e

echo "📁 Copying local changes to vllm-router pod..."

if ! kubectl get pod vllm-router >/dev/null 2>&1; then
    echo "❌ vllm-router pod not found. Run: kubectl apply -f vllm-router-local.yaml"
    exit 1
fi

# Copy files
kubectl cp . vllm-router:/workspace/vllm-router --no-preserve=true

echo "✅ Files copied! Now you can:"
echo "   - Quick rebuild: kubectl exec vllm-router -- bash -c 'cd /workspace/vllm-router && source ~/.cargo/env && cargo build --release'"
echo "   - Full deploy: ./deploy-local-changes.sh"
echo "   - Check logs: kubectl exec vllm-router -- tail -f /tmp/vllm-router.log"
