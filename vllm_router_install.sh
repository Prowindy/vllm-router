#!/bin/bash

# vLLM Deployment Script
# This script can clone vLLM, build Docker image, upload to ECR, and deploy to remote hosts

set -e

# Configuration
VLLM_REPO="https://github.com/vllm-project/vllm.git"
VLLM_COMMIT="9fac6aa30b669de75d8718164cd99676d3530e7d"
ECR_REPO="584868043064.dkr.ecr.us-west-2.amazonaws.com/dev-vllm-repo"
ECR_REGION="us-west-2"
DOCKER_TAG="vllm/vllm-openai"
# Function to get or generate ECR tag
get_ecr_tag() {
    local tag_file="/tmp/vllm_ecr_tag"
    if [ -f "$tag_file" ] && [ -s "$tag_file" ]; then
        cat "$tag_file"
    else
        echo "$(whoami)_$(date +%Y%m%d_%H%M%S)"
    fi
}

# Function to save ECR tag
save_ecr_tag() {
    local tag_file="/tmp/vllm_ecr_tag"
    echo "$1" > "$tag_file"
}

ECR_TAG=${ECR_TAG:-$(get_ecr_tag)}

# vLLM Configuration
HF_TOKEN="YOUR_HUGGING_FACE_TOKEN_HERE"
GPU_ID="0,1,2,3,4,5,6,7"
MODEL="deepseek-ai/DeepSeek-V3-0324"
DECODE_PORT="20005"
KV_PORT="22001"
PREFILL_PORT="20003"
PREFILL_KV_PORT="21001"
TP_SIZE="8"

# Remote hosts configuration (space-separated)
# AWS EC2 instances for deployment
# Prefill hosts (nodes 1 and 2)
PREFILL_REMOTE_HOSTS="congc@ec2-35-87-224-19.us-west-2.compute.amazonaws.com congc@ec2-44-249-71-122.us-west-2.compute.amazonaws.com"
# Decode hosts (nodes 3 and 4)
DECODE_REMOTE_HOSTS="congc@ec2-35-80-5-118.us-west-2.compute.amazonaws.com congc@ec2-44-252-57-95.us-west-2.compute.amazonaws.com"
# Backward compatibility - all hosts combined
REMOTE_HOSTS="$PREFILL_REMOTE_HOSTS $DECODE_REMOTE_HOSTS"

# SSH host aliases (for reference):
# aws-ec2-node1: ec2-35-87-224-19.us-west-2.compute.amazonaws.com
# aws-ec2-node2: ec2-44-249-71-122.us-west-2.compute.amazonaws.com
# aws-ec2-node3: ec2-35-80-5-118.us-west-2.compute.amazonaws.com
# aws-ec2-node4: ec2-44-252-57-95.us-west-2.compute.amazonaws.com
# User: congc
# SSH Key: ~/.ssh/ec2_instance_private_key.pem

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Commands:
    clone               Clone vLLM repository
    build               Build Docker image
    upload              Upload image to ECR
    deploy_local        Deploy and run vLLM locally
    deploy_remote_decode Deploy decode instances to decode hosts
    deploy_remote_prefill Deploy prefill instances to prefill hosts
    deploy_router       Deploy vLLM router to remote hosts
    deploy_router_local Deploy vLLM router locally (ports 10001, 30001)
    deploy_prefill_local Deploy vLLM prefill server locally
    deploy_decode_local Deploy vLLM decode server locally
    benchmark           Run vLLM benchmark against the router
    setup_ssh           Setup SSH key for remote deployment
    all                 Run all steps: clone, build, upload, deploy_router, deploy_remote_prefill, deploy_remote_decode

Options:
    -h, --help              Show this help message
    -c, --commit COMMIT     Use specific commit (default: $VLLM_COMMIT)
    -t, --tag TAG           ECR tag (default: auto-generated)
    -r, --hosts "host1 host2"  Remote hosts (default: from script)
    --no-precompiled        Build from source instead of using precompiled
    --dry-run               Show what would be done without executing

Benchmark Environment Variables:
    BENCHMARK_NUM_PROMPTS      Number of prompts (default: 10000)
    BENCHMARK_INPUT_LEN        Input token length (default: 2000)
    BENCHMARK_OUTPUT_LEN       Output token length (default: 2000)
    BENCHMARK_MAX_CONCURRENCY  Max concurrent requests (default: 32)
    BENCHMARK_ROUTER_HOST      Router host (default: host.docker.internal)
    BENCHMARK_ROUTER_PORT      Router port (default: 10001)

Examples:
    $0 all                              # Full deployment
    $0 build upload                     # Just build and upload
    $0 deploy -r "user@host1.com"       # Deploy to specific host
    $0 benchmark                        # Run benchmark against router
    BENCHMARK_NUM_PROMPTS=1000 $0 benchmark  # Run shorter benchmark
    $0 --dry-run all                    # Preview all steps
EOF
}

# Function to clone vLLM
clone_vllm() {
    log "Cloning vLLM repository..."

    if [ -d "vllm" ]; then
        log "vLLM directory exists, updating..."
        cd vllm
        git fetch origin
        git checkout $VLLM_COMMIT
        cd ..
    else
        git clone $VLLM_REPO
        cd vllm
        git checkout $VLLM_COMMIT
        cd ..
    fi

    success "vLLM cloned and checked out to commit $VLLM_COMMIT"
}

# Function to build Docker image
build_docker() {
    log "Building Docker image..."

    if [ ! -d "vllm" ]; then
        error "vLLM directory not found. Run 'clone' first."
        exit 1
    fi

    # Check if image already exists
    if docker images | grep -q "$DOCKER_TAG"; then
        log "Docker image $DOCKER_TAG already exists, skipping build..."
        success "Docker image already built: $DOCKER_TAG"
        return 0
    fi

    cd vllm

    BUILD_ARGS="--target vllm-openai --tag $DOCKER_TAG --build-arg torch_cuda_arch_list=\"\" --file docker/Dockerfile"

    if [ "$USE_PRECOMPILED" = "true" ]; then
        BUILD_ARGS="$BUILD_ARGS --build-arg VLLM_USE_PRECOMPILED=1"
        log "Building with precompiled binaries..."
    else
        BUILD_ARGS="$BUILD_ARGS --build-arg max_jobs=$(($(nproc) * 2)) --build-arg nvcc_threads=3 --build-arg VLLM_MAX_SIZE_MB=2000"
        log "Building from source (this will take a long time)..."
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run: DOCKER_BUILDKIT=1 docker build . $BUILD_ARGS"
    else
        DOCKER_BUILDKIT=1 docker build . $BUILD_ARGS
        success "Docker image built successfully: $DOCKER_TAG"
    fi

    cd ..
}

# Function to get local IP address
get_local_ip() {
    # Try to get the primary interface IP (not localhost)
    local ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [[ -z "$ip" ]]; then
        # Fallback to hostname -I
        ip=$(hostname -I | awk '{print $1}')
    fi
    if [[ -z "$ip" ]]; then
        # Last resort fallback
        ip="127.0.0.1"
    fi
    echo "$ip"
}

# Function to get router container IP address for local deployments
get_router_container_ip() {
    # Try to get the router container IP from docker inspect
    local router_ip=$(docker inspect vllm-router-local 2>/dev/null | grep '"IPAddress":' | head -1 | grep -o '[0-9.]*[0-9]')
    if [[ -n "$router_ip" && "$router_ip" != "" ]]; then
        echo "$router_ip"
    else
        # Fallback to host IP for remote deployments
        get_local_ip
    fi
}

# Shared function to generate vLLM run script
generate_vllm_run_script() {
    local ROUTER_IP=${1:-$(get_local_ip)}
    local EXTERNAL_IP=${2:-$(get_local_ip)}
    cat << EOF
#!/bin/bash

# Stop any existing containers
docker stop vllm-deepseek 2>/dev/null || true
sleep 2  # Give container time to stop properly
docker rm vllm-deepseek 2>/dev/null || true

# Login to ECR
aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO

# Pull latest image
docker pull $ECR_REPO:$ECR_TAG

# Create huggingface cache directory if it doesn't exist
sudo mkdir -p /opt/dlami/nvme/huggingface_cache
sudo chown -R \$(id -u):\$(id -g) /opt/dlami/nvme/huggingface_cache

# Run vLLM container
docker run --runtime nvidia --gpus all \
    -v /opt/dlami/nvme/huggingface_cache:/root/.cache/huggingface \
    -v /tmp:/dev/shm \
    --env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN" \
    --env "VLLM_MOE_DP_CHUNK_SIZE=512" \
    --env "TRITON_LIBCUDA_PATH=/usr/lib64" \
    --env "HF_HUB_DISABLE_XET=1" \
    --env "VLLM_SKIP_P2P_CHECK=1" \
    --env "VLLM_RANDOMIZE_DP_DUMMY_INPUTS=1" \
    --env "VLLM_USE_DEEP_GEMM=1" \
    --env "VLLM_ALL2ALL_BACKEND=deepep_low_latency" \
    --env "NVIDIA_GDRCOPY=enabled" \
    --env "NVSHMEM_DEBUG=INFO" \
    --env "NVSHMEM_REMOTE_TRANSPORT=ibgda" \
    --env "NVSHMEM_IB_ENABLE_IBGDA=true" \
    --env "GLOO_SOCKET_IFNAME=" \
    --env "NCCL_SOCKET_IFNAME=" \
    --env "NCCL_IB_HCA=ibp" \
    --env "VLLM_LOGGING_LEVEL=DEBUG" \
    --env "VLLM_TRACE_FUNCTION=1" \
    --env "VLLM_LOG_REQUESTS=1" \
    --env "VLLM_RPC_TIMEOUT=300" \
    --env "VLLM_WORKER_RPC_TIMEOUT=300" \
    --env "HF_HUB_CACHE=/root/.cache/huggingface/hub" \
    --env "CUDA_VISIBLE_DEVICES=$GPU_ID" \
    --network host \
    --name vllm-deepseek \
    $ECR_REPO:$ECR_TAG \
    --model $MODEL \
    --enforce-eager \
    --port $DECODE_PORT \
    --disable-log-requests \
    --disable-uvicorn-access-log \
    --enable-expert-parallel \
    --tensor-parallel-size $TP_SIZE \
    --trust-remote-code \
    --kv-transfer-config "{\"kv_connector\":\"P2pNcclConnector\",\"kv_role\":\"kv_consumer\",\"kv_buffer_size\":\"8e9\",\"kv_port\":\"22001\",\"kv_connector_extra_config\":{\"proxy_ip\":\"$ROUTER_IP\",\"proxy_port\":\"30001\",\"http_port\":\"$DECODE_PORT\",\"external_ip\":\"$EXTERNAL_IP\",\"send_type\":\"PUT_ASYNC\",\"nccl_num_channels\":\"16\"}}" \
    > decode.log 2>&1 &

echo "vLLM started in background. Check logs with: docker logs -f vllm-deepseek"
echo "API available at: http://localhost:$DECODE_PORT"
EOF
}

# Shared function to generate vLLM prefill run script
generate_vllm_prefill_run_script() {
    local ROUTER_IP=${1:-$(get_local_ip)}
    local EXTERNAL_IP=${2:-$(get_local_ip)}
    cat << EOF
#!/bin/bash

# Stop any existing prefill containers
docker stop vllm-deepseek-prefill 2>/dev/null || true
sleep 2  # Give container time to stop properly
docker rm vllm-deepseek-prefill 2>/dev/null || true

# Login to ECR
aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO

# Pull latest image
docker pull $ECR_REPO:$ECR_TAG

# Create huggingface cache directory if it doesn't exist
sudo mkdir -p /opt/dlami/nvme/huggingface_cache
sudo chown -R \$(id -u):\$(id -g) /opt/dlami/nvme/huggingface_cache

# Run vLLM prefill container
docker run --runtime nvidia --gpus all \\
    -v /opt/dlami/nvme/huggingface_cache:/root/.cache/huggingface \\
    -v /tmp:/dev/shm \\
    --env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN" \
    --env "VLLM_MOE_DP_CHUNK_SIZE=512" \
    --env "TRITON_LIBCUDA_PATH=/usr/lib64" \
    --env "HF_HUB_DISABLE_XET=1" \
    --env "VLLM_SKIP_P2P_CHECK=1" \
    --env "VLLM_RANDOMIZE_DP_DUMMY_INPUTS=1" \
    --env "VLLM_USE_DEEP_GEMM=1" \
    --env "VLLM_ALL2ALL_BACKEND=deepep_low_latency" \
    --env "NVIDIA_GDRCOPY=enabled" \
    --env "NVSHMEM_DEBUG=INFO" \
    --env "NVSHMEM_REMOTE_TRANSPORT=ibgda" \
    --env "NVSHMEM_IB_ENABLE_IBGDA=true" \
    --env "GLOO_SOCKET_IFNAME=" \
    --env "NCCL_SOCKET_IFNAME=" \
    --env "NCCL_IB_HCA=ibp" \
    --env "VLLM_LOGGING_LEVEL=DEBUG" \
    --env "VLLM_TRACE_FUNCTION=1" \
    --env "VLLM_LOG_REQUESTS=1" \
    --env "VLLM_RPC_TIMEOUT=300" \
    --env "VLLM_WORKER_RPC_TIMEOUT=300" \
    --env "HF_HUB_CACHE=/root/.cache/huggingface/hub" \
    --env "CUDA_VISIBLE_DEVICES=$GPU_ID" \
    --network host \\
    --name vllm-deepseek-prefill \\
    $ECR_REPO:$ECR_TAG \\
    --model $MODEL \\
    --enforce-eager \\
\
    --host 0.0.0.0 \\
    --port $PREFILL_PORT \\
    --tensor-parallel-size $TP_SIZE \\
    --enable-expert-parallel \\
    --trust-remote-code \\
    --gpu-memory-utilization 0.9 \\
    --enable-prefix-caching \\
    --disable-log-stats \\
    --kv_transfer_config "{\"kv_connector\":\"P2pNcclConnector\",\"kv_role\":\"kv_producer\",\"kv_buffer_size\":\"1e1\",\"kv_port\":\"$PREFILL_KV_PORT\",\"kv_connector_extra_config\":{\"proxy_ip\":\"$ROUTER_IP\",\"proxy_port\":\"30001\",\"http_port\":\"$PREFILL_PORT\",\"external_ip\":\"$EXTERNAL_IP\",\"send_type\":\"PUT_ASYNC\",\"nccl_num_channels\":\"16\"}}" \\
    > prefill.log 2>&1 &

echo "vLLM prefill started in background. Check logs with: docker logs -f vllm-deepseek-prefill"
echo "Prefill API available at: http://localhost:$PREFILL_PORT"
EOF
}

# Function to upload to ECR
upload_ecr() {
    log "Uploading image to ECR..."

    # Check if image already exists in ECR (skip if no permissions)
    ECR_REPO_NAME=$(echo $ECR_REPO | cut -d'/' -f2)
    if aws ecr describe-images --repository-name $ECR_REPO_NAME --image-ids imageTag=$ECR_TAG --region $ECR_REGION >/dev/null 2>&1; then
        log "Image $ECR_REPO:$ECR_TAG already exists in ECR, skipping upload..."
        success "Image already uploaded to ECR: $ECR_REPO:$ECR_TAG"
        return 0
    else
        # If describe-images fails (likely due to permissions), continue with upload
        # The push will be fast if layers already exist
        log "Cannot check if image exists in ECR (may lack describe permissions), proceeding with upload..."
    fi

    # Login to ECR
    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run: aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO"
        echo "Would run: docker tag $DOCKER_TAG $ECR_REPO:$ECR_TAG"
        echo "Would run: docker push $ECR_REPO:$ECR_TAG"
    else
        log "Logging into ECR..."
        aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO

        log "Tagging image for ECR..."
        docker tag $DOCKER_TAG $ECR_REPO:$ECR_TAG

        log "Pushing to ECR..."
        docker push $ECR_REPO:$ECR_TAG

        # Save the ECR tag for future use
        save_ecr_tag "$ECR_TAG"
        success "Image uploaded to ECR: $ECR_REPO:$ECR_TAG"
    fi
}

# Function to deploy locally
deploy_local() {
    log "Deploying vLLM locally..."

    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run vLLM container with:"
        echo "  Image: $ECR_REPO:$ECR_TAG"
        echo "  Model: $MODEL"
        echo "  Port: $DECODE_PORT"
        echo "  Tensor Parallel Size: $TP_SIZE"
    else
        # Generate and execute the vLLM run script locally
        generate_vllm_run_script $(get_local_ip) | bash

        sleep 3
        if docker ps | grep -q vllm-deepseek; then
            success "vLLM started successfully"
            log "Check logs with: docker logs vllm-deepseek"
            log "API available at: http://localhost:$DECODE_PORT"
        else
            error "Failed to start vLLM container"
            log "Check logs with: docker logs vllm-deepseek"
            exit 1
        fi
    fi
}

# Function to deploy decode instances to remote hosts
deploy_remote_decode() {
    log "Deploying decode instances to remote hosts..."

    # Check if SSH key exists
    if [ ! -f "$HOME/.ssh/ec2_instance_private_key.pem" ]; then
        error "SSH private key not found at $HOME/.ssh/ec2_instance_private_key.pem"
        log "Please run: $0 setup_ssh"
        log "Or set the PRIVATE_KEY environment variable and run setup_ssh"
        exit 1
    fi

    # Deploy to each host with its specific external IP
    ROUTER_IP=$(get_local_ip)

    for host in $DECODE_REMOTE_HOSTS; do
        log "Deploying decode to $host..."

        if [ "$DRY_RUN" = "true" ]; then
            echo "Would deploy decode script to $host with external IP detection"
        else
            # Get the internal IP of the remote host for AWS VPC communication
            EXTERNAL_IP=$(ssh -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no $host "curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || ip route get 8.8.8.8 | grep -oP 'src \K\S+'")
            log "Internal IP for $host: $EXTERNAL_IP"

            # Generate script with host-specific external IP
            generate_vllm_run_script $ROUTER_IP $EXTERNAL_IP > /tmp/vllm_run_remote_${EXTERNAL_IP}.sh
            chmod +x /tmp/vllm_run_remote_${EXTERNAL_IP}.sh

            # Copy script to remote host
            scp -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no /tmp/vllm_run_remote_${EXTERNAL_IP}.sh $host:/tmp/vllm_run_remote.sh

            # Execute on remote host
            ssh -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no $host "bash /tmp/vllm_run_remote.sh"

            # Clean up host-specific temp file
            rm -f /tmp/vllm_run_remote_${EXTERNAL_IP}.sh

            success "Decode deployed to $host (Internal IP: $EXTERNAL_IP)"
        fi
    done
}

# Function to deploy prefill to remote hosts
deploy_remote_prefill() {
    log "Deploying vLLM prefill to remote hosts..."

    # Check if SSH key exists
    if [ ! -f "$HOME/.ssh/ec2_instance_private_key.pem" ]; then
        error "SSH private key not found at $HOME/.ssh/ec2_instance_private_key.pem"
        log "Please run: $0 setup_ssh"
        log "Or set the PRIVATE_KEY environment variable and run setup_ssh"
        exit 1
    fi

    # Deploy to each host with its specific external IP
    ROUTER_IP=$(get_local_ip)

    for host in $PREFILL_REMOTE_HOSTS; do
        log "Deploying prefill to $host..."

        if [ "$DRY_RUN" = "true" ]; then
            echo "Would deploy prefill script to $host with external IP detection"
        else
            # Get the internal IP of the remote host for AWS VPC communication
            EXTERNAL_IP=$(ssh -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no $host "curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || ip route get 8.8.8.8 | grep -oP 'src \K\S+'")
            log "Internal IP for $host: $EXTERNAL_IP"

            # Generate script with host-specific external IP
            generate_vllm_prefill_run_script $ROUTER_IP $EXTERNAL_IP > /tmp/vllm_run_remote_prefill_${EXTERNAL_IP}.sh
            chmod +x /tmp/vllm_run_remote_prefill_${EXTERNAL_IP}.sh

            # Copy script to remote host
            scp -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no /tmp/vllm_run_remote_prefill_${EXTERNAL_IP}.sh $host:/tmp/vllm_run_remote_prefill.sh

            # Execute on remote host
            ssh -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no $host "bash /tmp/vllm_run_remote_prefill.sh"

            # Clean up host-specific temp file
            rm -f /tmp/vllm_run_remote_prefill_${EXTERNAL_IP}.sh

            success "Prefill deployed to $host (Internal IP: $EXTERNAL_IP)"
        fi
    done
}

# Function to deploy router (clone, build, upload, deploy)
deploy_router() {
    log "Deploying vLLM router..."

    # Check if SSH key exists for remote deployment
    if [ ! -f "$HOME/.ssh/ec2_instance_private_key.pem" ]; then
        error "SSH private key not found at $HOME/.ssh/ec2_instance_private_key.pem"
        log "Please run: $0 setup_ssh"
        exit 1
    fi

    # Step 1: Clone and install router repository locally
    log "Checking for router repository..."
    if [ -d "vllm-router" ]; then
        log "Router directory exists, skipping clone and proceeding with build..."
    else
        log "Cloning vLLM router repository locally..."
        if ! git clone https://github.com/Prowindy/vllm-router; then
            error "Failed to clone router repository from https://github.com/Prowindy/vllm-router"
            log "Please check your network connection and try again"
            exit 1
        fi

        log "Installing router dependencies..."
        cd vllm-router
        if [ -f "./scripts/install.sh" ]; then
            ./scripts/install.sh
        else
            warn "Install script not found, skipping installation step"
        fi
        cd ..
    fi

    # Step 2: Build router Docker image
    log "Building router Docker image..."
    cd vllm-router

    if [ ! -f "Dockerfile" ] && [ ! -f "Dockerfile.router" ]; then
        error "Dockerfile or Dockerfile.router not found in vllm-router directory"
        exit 1
    fi

    # Use the correct Dockerfile name
    DOCKERFILE_NAME="Dockerfile"
    if [ -f "Dockerfile.router" ]; then
        DOCKERFILE_NAME="Dockerfile.router"
    fi

    ROUTER_DOCKER_TAG="vllm-router-service"
    ROUTER_ECR_TAG="router_$(whoami)_$(date +%Y%m%d_%H%M%S)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run: docker build -f $DOCKERFILE_NAME -t $ROUTER_DOCKER_TAG ."
    else
        docker build -f $DOCKERFILE_NAME -t $ROUTER_DOCKER_TAG .
        success "Router Docker image built: $ROUTER_DOCKER_TAG"
    fi

    cd ..

    # Step 3: Upload router image to ECR
    log "Uploading router image to ECR..."
    if [ "$DRY_RUN" = "true" ]; then
        echo "Would tag and push router image to ECR"
    else
        # Login to ECR
        aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO

        # Tag for ECR
        docker tag $ROUTER_DOCKER_TAG $ECR_REPO:$ROUTER_ECR_TAG

        # Push to ECR
        docker push $ECR_REPO:$ROUTER_ECR_TAG
        success "Router image uploaded to ECR: $ECR_REPO:$ROUTER_ECR_TAG"
    fi

    # Step 4: Deploy router to remote hosts
    log "Deploying router to remote hosts..."

    # Create router deployment script
    cat > /tmp/router_deploy.sh << EOF
#!/bin/bash

# Stop any existing router containers
docker stop vllm-router 2>/dev/null || true
docker rm vllm-router 2>/dev/null || true

# Login to ECR
aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR_REPO

# Pull router image
docker pull $ECR_REPO:$ROUTER_ECR_TAG

# Run router container with correct ports for P/D disaggregation
docker run -d \\
    --name vllm-router \\
    -p 10001:10001 \\
    -p 30001:30001 \\
    --restart unless-stopped \\
    $ECR_REPO:$ROUTER_ECR_TAG \\
    vllm-router --vllm-pd-disaggregation --vllm-discovery-address 0.0.0.0:30001 --host 0.0.0.0 --port 10001

echo "Router started. Check logs with: docker logs vllm-router"
echo "Router HTTP available at: http://localhost:10001"
echo "Router Discovery available at: localhost:30001"
EOF

    chmod +x /tmp/router_deploy.sh

    for host in $REMOTE_HOSTS; do
        log "Deploying router to $host..."

        if [ "$DRY_RUN" = "true" ]; then
            echo "Would copy router deployment script to $host and execute"
        else
            # Copy script to remote host
            scp -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no /tmp/router_deploy.sh $host:/tmp/

            # Execute on remote host
            ssh -i "$HOME/.ssh/ec2_instance_private_key.pem" -o StrictHostKeyChecking=no $host "bash /tmp/router_deploy.sh"

            success "Router deployed to $host"
        fi
    done

    # Clean up temp file
    rm -f /tmp/router_deploy.sh

    success "Router deployment completed successfully!"
}

# Function to deploy router locally with correct ports
deploy_router_local() {
    log "Deploying vLLM router locally..."

    # Step 1: Check if router directory exists or clone it
    log "Checking for router repository..."
    if [ ! -d "vllm-router" ]; then
        log "Cloning vLLM router repository locally..."
        if ! git clone https://github.com/Prowindy/vllm-router; then
            error "Failed to clone router repository from https://github.com/Prowindy/vllm-router"
            log "Please check your network connection and try again"
            exit 1
        fi

        log "Installing router dependencies..."
        cd vllm-router
        if [ -f "./scripts/install.sh" ]; then
            ./scripts/install.sh
        else
            warn "Install script not found, skipping installation step"
        fi
        cd ..
    fi

    # Step 2: Build router Docker image
    log "Building router Docker image..."
    cd vllm-router

    if [ ! -f "Dockerfile" ] && [ ! -f "Dockerfile.router" ]; then
        error "Dockerfile or Dockerfile.router not found in vllm-router directory"
        exit 1
    fi

    # Use the correct Dockerfile name
    DOCKERFILE_NAME="Dockerfile"
    if [ -f "Dockerfile.router" ]; then
        DOCKERFILE_NAME="Dockerfile.router"
    fi

    ROUTER_DOCKER_TAG="vllm-router-service"

    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run: docker build -f $DOCKERFILE_NAME -t $ROUTER_DOCKER_TAG ."
    else
        docker build -f $DOCKERFILE_NAME -t $ROUTER_DOCKER_TAG .
        success "Router Docker image built: $ROUTER_DOCKER_TAG"
    fi

    cd ..

    # Step 3: Stop any existing router container
    log "Stopping any existing router container..."
    docker stop vllm-router-local 2>/dev/null || true
    docker rm vllm-router-local 2>/dev/null || true

    # Step 4: Run router container locally with correct ports
    log "Starting router container locally..."
    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run router container with ports 10001:10001 and 30001:30001"
    else
        docker run -d \
            --name vllm-router-local \
            -p 10001:10001 \
            -p 30001:30001 \
            --restart unless-stopped \
            $ROUTER_DOCKER_TAG \
            vllm-router --vllm-pd-disaggregation --vllm-discovery-address 0.0.0.0:30001 --host 0.0.0.0 --port 10001

        # Wait a moment and check if container started successfully
        sleep 2
        if docker ps | grep -q vllm-router-local; then
            success "Router started locally successfully!"
            log "Router HTTP available at: http://localhost:10001"
            log "Router Discovery available at: localhost:30001"
            log "Check logs with: docker logs vllm-router-local"
        else
            error "Failed to start router container"
            log "Check logs with: docker logs vllm-router-local"
            exit 1
        fi
    fi
}

# Function to deploy prefill server locally
deploy_prefill_local() {
    log "Deploying vLLM prefill server locally..."

    # Get router container IP for local deployment
    local ROUTER_IP=$(get_router_container_ip)
    log "Using router IP: $ROUTER_IP"

    # Generate and execute the prefill run script locally
    if [ "$DRY_RUN" = "true" ]; then
        echo "Would deploy prefill server with router IP: $ROUTER_IP"
        generate_vllm_prefill_run_script $ROUTER_IP
    else
        generate_vllm_prefill_run_script $ROUTER_IP | bash

        sleep 3
        if docker ps | grep -q vllm-deepseek-prefill; then
            success "vLLM prefill server started successfully"
            log "Check logs with: docker logs vllm-deepseek-prefill"
            log "Prefill API available at: http://localhost:$PREFILL_PORT"
        else
            error "Failed to start vLLM prefill container"
            log "Check logs with: docker logs vllm-deepseek-prefill"
            exit 1
        fi
    fi
}

# Function to deploy decode server locally
deploy_decode_local() {
    log "Deploying vLLM decode server locally..."

    # Get router container IP for local deployment
    local ROUTER_IP=$(get_router_container_ip)
    log "Using router IP: $ROUTER_IP"

    # Generate and execute the decode run script locally
    if [ "$DRY_RUN" = "true" ]; then
        echo "Would deploy decode server with router IP: $ROUTER_IP"
        generate_vllm_run_script $ROUTER_IP
    else
        generate_vllm_run_script $ROUTER_IP | bash

        sleep 3
        if docker ps | grep -q vllm-deepseek; then
            success "vLLM decode server started successfully"
            log "Check logs with: docker logs vllm-deepseek"
            log "Decode API available at: http://localhost:$DECODE_PORT"
        else
            error "Failed to start vLLM decode container"
            log "Check logs with: docker logs vllm-deepseek"
            exit 1
        fi
    fi
}

# Function to run benchmark against the router
benchmark() {
    log "Running vLLM benchmark against the router..."

    # Check if there's a vLLM container to run the benchmark from
    local BENCHMARK_CONTAINER=""
    if docker ps | grep -q vllm-deepseek-prefill; then
        BENCHMARK_CONTAINER="vllm-deepseek-prefill"
    elif docker ps | grep -q vllm-deepseek; then
        BENCHMARK_CONTAINER="vllm-deepseek"
    else
        error "No vLLM container found to run benchmark from"
        log "Please deploy a vLLM service first with: $0 deploy_prefill_local or $0 deploy_decode_local"
        exit 1
    fi

    log "Using container: $BENCHMARK_CONTAINER"

    # Default benchmark parameters
    local NUM_PROMPTS="${BENCHMARK_NUM_PROMPTS:-10000}"
    local INPUT_LEN="${BENCHMARK_INPUT_LEN:-2000}"
    local OUTPUT_LEN="${BENCHMARK_OUTPUT_LEN:-2000}"
    local MAX_CONCURRENCY="${BENCHMARK_MAX_CONCURRENCY:-32}"
    local ROUTER_HOST="${BENCHMARK_ROUTER_HOST:-host.docker.internal}"
    local ROUTER_PORT="${BENCHMARK_ROUTER_PORT:-10001}"

    log "Benchmark configuration:"
    echo "  Container: $BENCHMARK_CONTAINER"
    echo "  Model: $MODEL"
    echo "  Router: $ROUTER_HOST:$ROUTER_PORT"
    echo "  Prompts: $NUM_PROMPTS"
    echo "  Input Length: $INPUT_LEN tokens"
    echo "  Output Length: $OUTPUT_LEN tokens"
    echo "  Max Concurrency: $MAX_CONCURRENCY"
    echo ""

    if [ "$DRY_RUN" = "true" ]; then
        echo "Would run benchmark command in container $BENCHMARK_CONTAINER"
    else
        # Run the benchmark
        log "Starting benchmark (this may take a while)..."
        docker exec $BENCHMARK_CONTAINER vllm bench serve \
            --dataset-name random \
            --num-prompts $NUM_PROMPTS \
            --model "$MODEL" \
            --random-input-len $INPUT_LEN \
            --random-output-len $OUTPUT_LEN \
            --endpoint /v1/completions \
            --max-concurrency $MAX_CONCURRENCY \
            --save-result \
            --ignore-eos \
            --served-model-name "$MODEL" \
            --host $ROUTER_HOST \
            --port $ROUTER_PORT

        if [ $? -eq 0 ]; then
            success "Benchmark completed successfully!"
            log "Results saved to benchmark output file"
        else
            error "Benchmark failed or was interrupted"
            exit 1
        fi
    fi
}

# Function to setup SSH key for remote deployment
setup_ssh() {
    log "Setting up SSH key for remote deployment..."

    # Check if SSH directory exists
    if [ ! -d ~/.ssh ]; then
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
    fi

    SSH_KEY_FILE="$HOME/.ssh/ec2_instance_private_key.pem"

    if [ -f "$SSH_KEY_FILE" ]; then
        warn "SSH key already exists at $SSH_KEY_FILE"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "SSH key setup cancelled"
            return 0
        fi
    fi

    log "Please provide your EC2 private key content."
    log "You can either:"
    log "1. Set the PRIVATE_KEY environment variable with your key content"
    log "2. Enter the key content when prompted"
    echo

    if [ -n "$PRIVATE_KEY" ]; then
        log "Using PRIVATE_KEY environment variable..."
        echo -e "$PRIVATE_KEY" > "$SSH_KEY_FILE"
    else
        log "Please paste your private key content (press Ctrl+D when done):"
        cat > "$SSH_KEY_FILE"
    fi

    # Set proper permissions
    chmod 600 "$SSH_KEY_FILE"

    # Add all EC2 hosts to known_hosts
    log "Adding EC2 hosts to known_hosts..."
    for host in ec2-35-87-224-19.us-west-2.compute.amazonaws.com ec2-44-249-71-122.us-west-2.compute.amazonaws.com ec2-35-80-5-118.us-west-2.compute.amazonaws.com ec2-44-252-57-95.us-west-2.compute.amazonaws.com; do
        ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null
    done

    # Test SSH connection to the first host
    log "Testing SSH connection..."
    if ssh -i "$SSH_KEY_FILE" -o ConnectTimeout=10 -o StrictHostKeyChecking=no congc@ec2-35-87-224-19.us-west-2.compute.amazonaws.com "echo 'SSH connection successful'" 2>/dev/null; then
        success "SSH key setup completed successfully!"
        log "You can now use deploy_remote and deploy_remote_prefill commands"
    else
        error "SSH connection test failed. Please check your private key"
        log "Make sure the key corresponds to the EC2 instances and the 'congc' user has access"
    fi
}

# Parse command line arguments
USE_PRECOMPILED="true"
DRY_RUN="false"
COMMANDS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--commit)
            VLLM_COMMIT="$2"
            shift 2
            ;;
        -t|--tag)
            ECR_TAG="$2"
            shift 2
            ;;
        -r|--hosts)
            REMOTE_HOSTS="$2"
            shift 2
            ;;
        --no-precompiled)
            USE_PRECOMPILED="false"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        clone|build|upload|deploy_local|deploy_remote_decode|deploy_remote_prefill|deploy_router|deploy_router_local|deploy_prefill_local|deploy_decode_local|benchmark|setup_ssh|all)
            COMMANDS+=("$1")
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# If no commands specified, show usage
if [ ${#COMMANDS[@]} -eq 0 ]; then
    usage
    exit 1
fi

# Show configuration
log "Configuration:"
echo "  vLLM Commit: $VLLM_COMMIT"
echo "  Docker Tag: $DOCKER_TAG"
echo "  ECR Tag: $ECR_TAG"
echo "  Use Precompiled: $USE_PRECOMPILED"
echo "  Prefill Hosts: $PREFILL_REMOTE_HOSTS"
echo "  Decode Hosts: $DECODE_REMOTE_HOSTS"
echo "  All Remote Hosts: $REMOTE_HOSTS"
echo "  Model: $MODEL"
echo "  Dry Run: $DRY_RUN"
echo ""

# Execute commands
for cmd in "${COMMANDS[@]}"; do
    case $cmd in
        clone)
            clone_vllm
            ;;
        build)
            build_docker
            ;;
        upload)
            upload_ecr
            ;;
        deploy_local)
            deploy_local
            ;;
        deploy_remote_decode)
            deploy_remote_decode
            ;;
        deploy_remote_prefill)
            deploy_remote_prefill
            ;;
        deploy_router)
            deploy_router
            ;;
        deploy_router_local)
            deploy_router_local
            ;;
        deploy_prefill_local)
            deploy_prefill_local
            ;;
        deploy_decode_local)
            deploy_decode_local
            ;;
        benchmark)
            benchmark
            ;;
        setup_ssh)
            setup_ssh
            ;;
        all)
            clone_vllm
            build_docker
            upload_ecr
            deploy_router
            deploy_remote_prefill
            deploy_remote_decode
            ;;
    esac
done

success "All operations completed successfully!"




