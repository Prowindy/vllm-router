#!/bin/bash

# Development workflow script for vllm-router
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy    - Initial deployment of vllm-router"
    echo "  copy      - Copy local changes to running pod"
    echo "  rebuild   - Rebuild and restart router in pod"
    echo "  logs      - Show router logs"
    echo "  status    - Check deployment status"
    echo "  test      - Test router functionality"
    echo "  clean     - Clean up deployment"
    echo ""
}

get_pod_name() {
    kubectl get pods -l app=vllm-router -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

wait_for_pod() {
    echo -e "${BLUE}⏳ Waiting for pod to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app=vllm-router --timeout=600s
    echo -e "${GREEN}✅ Pod is ready${NC}"
}

case "${1:-help}" in
    "deploy")
        echo -e "${BLUE}🚀 Deploying vllm-router...${NC}"

        # Clean up any existing deployment
        kubectl delete -f vllm-router-declarative.yaml --ignore-not-found=true
        sleep 5

        # Deploy new version
        kubectl apply -f vllm-router-declarative.yaml

        # Wait for pod to be ready
        wait_for_pod

        # Copy local source code
        POD_NAME=$(get_pod_name)
        if [ -n "$POD_NAME" ]; then
            echo -e "${BLUE}📁 Copying local source code...${NC}"
            kubectl cp . "$POD_NAME":/workspace/vllm-router --no-preserve=true

            echo -e "${GREEN}✅ Deployment completed successfully!${NC}"
            echo -e "${YELLOW}📝 The router is building in the background. Check logs with: $0 logs${NC}"
        else
            echo -e "${RED}❌ Could not find pod${NC}"
            exit 1
        fi
        ;;

    "copy")
        POD_NAME=$(get_pod_name)
        if [ -z "$POD_NAME" ]; then
            echo -e "${RED}❌ No vllm-router pod found. Run: $0 deploy${NC}"
            exit 1
        fi

        echo -e "${BLUE}📁 Copying local changes to $POD_NAME...${NC}"
        kubectl cp . "$POD_NAME":/workspace/vllm-router --no-preserve=true
        echo -e "${GREEN}✅ Files copied${NC}"
        echo -e "${YELLOW}💡 Run '$0 rebuild' to rebuild and restart${NC}"
        ;;

    "rebuild")
        POD_NAME=$(get_pod_name)
        if [ -z "$POD_NAME" ]; then
            echo -e "${RED}❌ No vllm-router pod found${NC}"
            exit 1
        fi

        echo -e "${BLUE}🔨 Rebuilding vllm-router...${NC}"
        kubectl exec "$POD_NAME" -- bash -c '
            cd /workspace/vllm-router
            source ~/.cargo/env
            echo "Building..."
            cargo build --release
            echo "Stopping existing router..."
            pkill vllm-router || true
            sleep 2
            echo "Starting new router..."
            nohup ./target/release/vllm-router \
                --host 0.0.0.0 \
                --port 8080 \
                --worker-urls http://vllm-service.default.svc.cluster.local:8000 \
                --prometheus-host 0.0.0.0 \
                --prometheus-port 29000 \
                --log-level info \
                > /tmp/router.log 2>&1 &
            echo "Router restarted!"
        '
        echo -e "${GREEN}✅ Rebuild completed${NC}"
        ;;

    "logs")
        POD_NAME=$(get_pod_name)
        if [ -z "$POD_NAME" ]; then
            echo -e "${RED}❌ No vllm-router pod found${NC}"
            exit 1
        fi

        echo -e "${BLUE}📖 Showing logs for $POD_NAME...${NC}"
        kubectl logs "$POD_NAME" -f
        ;;

    "status")
        echo -e "${BLUE}📊 Checking vllm-router status...${NC}"

        # Check pods
        kubectl get pods -l app=vllm-router

        # Check services
        echo ""
        kubectl get svc vllm-router-service

        # Test health endpoint
        POD_NAME=$(get_pod_name)
        if [ -n "$POD_NAME" ]; then
            echo ""
            echo -e "${BLUE}🏥 Testing health endpoint...${NC}"
            if kubectl exec "$POD_NAME" -- curl -s http://localhost:8080/health >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Router is healthy${NC}"
            else
                echo -e "${RED}❌ Router health check failed${NC}"
            fi
        fi
        ;;

    "test")
        echo -e "${BLUE}🧪 Testing vllm-router functionality...${NC}"

        # Test health endpoint externally
        echo "Testing external health endpoint..."
        if curl -s http://35.93.104.231:30081/health >/dev/null 2>&1; then
            echo -e "${GREEN}✅ External health check passed${NC}"
        else
            echo -e "${RED}❌ External health check failed${NC}"
        fi

        # Test completion endpoint through router
        echo "Testing completion through router..."
        RESPONSE=$(curl -s -X POST http://35.93.104.231:30081/v1/completions \
            -H "Content-Type: application/json" \
            -d '{"model": "facebook/opt-350m", "prompt": "Hello", "max_tokens": 5}' 2>/dev/null || echo "")

        if echo "$RESPONSE" | grep -q "choices"; then
            echo -e "${GREEN}✅ Router completion test passed${NC}"
            echo "Response: $RESPONSE"
        else
            echo -e "${RED}❌ Router completion test failed${NC}"
            echo "Response: $RESPONSE"
        fi
        ;;

    "clean")
        echo -e "${BLUE}🧹 Cleaning up vllm-router deployment...${NC}"
        kubectl delete -f vllm-router-declarative.yaml --ignore-not-found=true
        echo -e "${GREEN}✅ Cleanup completed${NC}"
        ;;

    "help"|*)
        print_usage
        ;;
esac
