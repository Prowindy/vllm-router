// vLLM PD (Prefill-Decode) Router Implementation
// This module extends PDRouter to handle vLLM-specific two-stage processing
use super::pd_router::PDRouter;
use super::pd_types::PDRouterError;
use super::vllm_service_discovery::{ServiceRegistry, ServiceType};
use crate::core::Worker;
use crate::routers::{RouterTrait, WorkerManagement};
use async_trait::async_trait;
use axum::{
    body::Body,
    extract::Request,
    http::HeaderMap,
    response::{IntoResponse, Response},
};
use serde_json::{json, Value};
use std::sync::Arc;
use tracing::info;
use uuid::Uuid;

/// vLLM PD Router that extends PDRouter with vLLM-specific request handling
#[derive(Debug)]
pub struct VllmPDRouter {
    /// Underlying PD router for most functionality
    pd_router: PDRouter,
    /// Service discovery registry for dynamic ZMQ address resolution
    service_registry: Arc<ServiceRegistry>,
    /// HTTP client for making requests to discovered services
    http_client: reqwest::Client,
}

impl VllmPDRouter {
    /// Generate vLLM-specific request ID with prefill/decode addressing
    fn generate_vllm_request_id(prefill_addr: &str, decode_addr: &str) -> String {
        let uuid = Uuid::new_v4().to_string().replace('-', "");
        format!("___prefill_addr_{}___decode_addr_{}_{}", prefill_addr, decode_addr, uuid)
    }

    /// Get ZMQ address for a worker URL using service discovery
    fn get_zmq_address(&self, http_url: &str, service_type: ServiceType) -> String {
        // Extract just the host:port from the URL
        let http_address = http_url.replace("http://", "").replace("https://", "");

        // Try to get ZMQ address from service discovery
        if let Some(zmq_addr) = self.service_registry.get_zmq_address(&http_address, service_type.clone()) {
            info!("Using discovered ZMQ address: {} ({:?}) -> {}", http_address, service_type, zmq_addr);
            return zmq_addr;
        }

        // Fallback: use HTTP address as ZMQ address
        info!("No ZMQ discovery result for {} ({:?}), using fallback: {}", http_address, service_type, http_address);
        http_address
    }

    /// Modify request for prefill stage (set max_tokens=1)
    fn prepare_prefill_request(mut request: Value) -> Value {
        request["max_tokens"] = json!(1);
        if request.get("max_completion_tokens").is_some() {
            request["max_completion_tokens"] = json!(1);
        }
        request
    }

    /// Process vLLM request using pure service discovery
    async fn process_vllm_request(&self, request_json: Value, path: &str) -> Response {
        info!("Processing vLLM request for path: {}", path);
        info!("Request JSON: {}", serde_json::to_string_pretty(&request_json).unwrap_or_default());

        // Get available instances from service discovery
        let prefill_instances = self.service_registry.get_prefill_instances();
        let decode_instances = self.service_registry.get_decode_instances();

        info!("Found {} prefill instances, {} decode instances from service discovery",
              prefill_instances.len(), decode_instances.len());

        if prefill_instances.is_empty() || decode_instances.is_empty() {
            return (axum::http::StatusCode::SERVICE_UNAVAILABLE,
                   format!("No workers available via service discovery: {} prefill, {} decode",
                          prefill_instances.len(), decode_instances.len())).into_response();
        }

        // Simple round-robin selection for now (can be enhanced with policies later)
        let prefill_idx = (request_json.get("request_id").and_then(|v| v.as_str()).unwrap_or("").len()) % prefill_instances.len();
        let decode_idx = (request_json.get("request_id").and_then(|v| v.as_str()).unwrap_or("").len()) % decode_instances.len();

        let (prefill_http, prefill_zmq) = &prefill_instances[prefill_idx];
        let (decode_http, decode_zmq) = &decode_instances[decode_idx];

        info!("vLLM service discovery routing: prefill={}({}), decode={}({})",
              prefill_http, prefill_zmq, decode_http, decode_zmq);

        // Process two-stage vLLM request with discovered endpoints
        match self.process_vllm_two_stage_request_discovered(
            request_json,
            prefill_http,
            prefill_zmq,
            decode_http,
            decode_zmq,
            path
        ).await {
            Ok(response) => {
                info!("Two-stage processing completed successfully");
                response
            },
            Err(e) => {
                info!("Two-stage processing failed: {}", e);
                (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Request processing failed: {}", e)).into_response()
            },
        }
    }

    /// Two-stage request processing for vLLM disaggregated mode using discovered endpoints
    async fn process_vllm_two_stage_request_discovered(
        &self,
        mut request_json: Value,
        prefill_http: &str,
        prefill_zmq: &str,
        decode_http: &str,
        decode_zmq: &str,
        path: &str,
    ) -> Result<Response, String> {
        info!("ENTERED process_vllm_two_stage_request_discovered method");
        info!("Prefill: HTTP={}, ZMQ={}, Decode: HTTP={}, ZMQ={}, Path: {}",
              prefill_http, prefill_zmq, decode_http, decode_zmq, path);

        let request_id = Self::generate_vllm_request_id(prefill_zmq, decode_zmq);
        info!("Generated vLLM request ID for P2P coordination: {}", request_id);

        // DO NOT add P2P metadata to internal request_id - let vLLM generate clean internal IDs
        // The P2P metadata will be sent in X-Request-Id header instead

        // Prepare prefill request (max_tokens=1 to force prefill-only mode)
        let mut prefill_request = request_json.clone();
        prefill_request["max_tokens"] = serde_json::Value::Number(serde_json::Number::from(1));
        if prefill_request.get("max_completion_tokens").is_some() {
            prefill_request["max_completion_tokens"] = serde_json::Value::Number(serde_json::Number::from(1));
        }

        let prefill_request_str = serde_json::to_string(&prefill_request)
            .map_err(|e| format!("Failed to serialize prefill request: {}", e))?;

        let decode_request_str = serde_json::to_string(&request_json)
            .map_err(|e| format!("Failed to serialize decode request: {}", e))?;

        // Stage 1: Send to prefill server with max_tokens=1 and P2P coordination header
        info!("Stage 1: Sending prefill-only request (max_tokens=1) to prefill server at http://{}", prefill_http);
        let prefill_response = self.http_client
            .post(&format!("http://{}{}", prefill_http, path))
            .header("Content-Type", "application/json")
            .header("X-Request-Id", &request_id)  // P2P coordination metadata in header
            .body(prefill_request_str)
            .send()
            .await
            .map_err(|e| format!("Prefill request failed: {}", e))?;

        let prefill_status = prefill_response.status();
        info!("Prefill server responded with status: {}", prefill_status);

        if !prefill_status.is_success() {
            let error_body = prefill_response.text().await.unwrap_or_default();
            return Err(format!("Prefill server error {}: {}", prefill_status, error_body));
        }

        // Stage 2: Send to decode server with original request and same P2P coordination header
        info!("Stage 2: Sending original request to decode server at http://{}", decode_http);
        let decode_response = self.http_client
            .post(&format!("http://{}{}", decode_http, path))
            .header("Content-Type", "application/json")
            .header("X-Request-Id", &request_id)  // Same P2P coordination metadata in header
            .body(decode_request_str)
            .send()
            .await
            .map_err(|e| format!("Decode request failed: {}", e))?;

        info!("Decode server responded with status: {}", decode_response.status());

        // Convert reqwest::Response to axum::Response
        let status = decode_response.status();
        let headers = decode_response.headers().clone();
        let body = decode_response.bytes().await
            .map_err(|e| format!("Failed to read decode response: {}", e))?;

        let mut response_builder = axum::http::Response::builder().status(status);

        // Copy headers
        for (name, value) in headers.iter() {
            response_builder = response_builder.header(name, value);
        }

        let response = response_builder.body(axum::body::Body::from(body))
            .map_err(|e| format!("Failed to build response: {}", e))?;

        Ok(response)
    }

    /// Two-stage request processing for vLLM disaggregated mode
    async fn process_vllm_two_stage_request(
        &self,
        original_request: Value,
        prefill_worker: Arc<dyn Worker>,
        decode_worker: Arc<dyn Worker>,
        path: &str,
    ) -> Result<Response, PDRouterError> {
        info!("ENTERED process_vllm_two_stage_request method");
        info!("Prefill worker: {}, Decode worker: {}, Path: {}", prefill_worker.url(), decode_worker.url(), path);

        let prefill_zmq_addr = self.get_zmq_address(prefill_worker.url(), ServiceType::Prefill);
        let decode_zmq_addr = self.get_zmq_address(decode_worker.url(), ServiceType::Decode);
        let request_id = Self::generate_vllm_request_id(&prefill_zmq_addr, &decode_zmq_addr);

        info!("Generated vLLM request ID: {}", request_id);
        info!("🔍 vLLM Proxy Comparison:");
        info!("  📋 vLLM Proxy Request ID format: ___prefill_addr_{{zmq_addr}}___decode_addr_{{zmq_addr}}_{{uuid}}");
        info!("  📋 Our Request ID format: ___prefill_addr_{{http_addr}}___decode_addr_{{http_addr}}_{{uuid}}");
        info!("  📋 vLLM Proxy headers: Authorization: Bearer $OPENAI_API_KEY, X-Request-Id: {{request_id}}");
        info!("  📋 Our headers: Authorization: Bearer $OPENAI_API_KEY, X-Request-Id: {{request_id}}");

        // Stage 1: Send prefill request with max_tokens=1
        let prefill_request = Self::prepare_prefill_request(original_request.clone());
        let prefill_url = format!("{}{}", prefill_worker.url(), path);

        info!("🚀 vLLM Stage 1 - Prefill: {} with request_id: {}", prefill_url, request_id);
        info!("📤 Prefill request headers: Authorization=Bearer [REDACTED], X-Request-Id={}", request_id);
        info!("📤 Prefill request payload: {}", serde_json::to_string_pretty(&prefill_request).unwrap_or_default());

        let prefill_response = self.pd_router.client
            .post(&prefill_url)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", std::env::var("OPENAI_API_KEY").unwrap_or_default()))
            .header("X-Request-Id", &request_id)
            .json(&prefill_request)
            .send()
            .await
            .map_err(|e| PDRouterError::NetworkError {
                message: format!("Prefill request failed to {}: {}", prefill_url, e),
            })?;

        info!("📥 Prefill response status: {}", prefill_response.status());
        info!("📥 Prefill response headers: {:?}", prefill_response.headers());

        // Drain prefill response (we don't need the content, just the KV cache transfer)
        let prefill_bytes = prefill_response.bytes().await.map_err(|e| PDRouterError::NetworkError {
            message: format!("Failed to read prefill response from {}: {}", prefill_url, e),
        })?;

        info!("📥 Prefill response body size: {} bytes", prefill_bytes.len());
        if prefill_bytes.len() < 1024 {
            info!("📥 Prefill response body content: {}", String::from_utf8_lossy(&prefill_bytes));
        }

        info!("✅ vLLM Stage 1 completed, starting Stage 2 - Decode");

        // Stage 2: Send original request to decode worker with same request_id
        let decode_url = format!("{}{}", decode_worker.url(), path);

        info!("🚀 vLLM Stage 2 - Decode: {} with request_id: {}", decode_url, request_id);
        info!("📤 Decode request headers: Authorization=Bearer [REDACTED], X-Request-Id={}", request_id);
        info!("📤 Decode request payload: {}", serde_json::to_string_pretty(&original_request).unwrap_or_default());

        let decode_response = self.pd_router.client
            .post(&decode_url)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", std::env::var("OPENAI_API_KEY").unwrap_or_default()))
            .header("X-Request-Id", &request_id)
            .json(&original_request)
            .send()
            .await
            .map_err(|e| PDRouterError::NetworkError {
                message: format!("Decode request failed to {}: {}", decode_url, e),
            })?;

        // Convert reqwest::Response to axum::Response
        let status = decode_response.status();
        let headers = decode_response.headers().clone();

        info!("📥 Decode response status: {}", status);
        info!("📥 Decode response headers: {:?}", headers);

        let mut response_builder = Response::builder().status(status);

        // Copy headers, skipping potentially problematic ones
        for (key, value) in headers.iter() {
            // Skip headers that might cause issues with axum
            if key != "transfer-encoding" && key != "content-length" {
                response_builder = response_builder.header(key, value);
            }
        }

        let body = Body::from_stream(decode_response.bytes_stream());
        response_builder.body(body).map_err(|e| PDRouterError::NetworkError {
            message: format!("Failed to build response from {}: {}", decode_url, e),
        })
    }

    /// Create a new vLLM PD router with pure service discovery
    pub async fn new(
        discovery_address: String,
        ctx: &Arc<crate::server::AppContext>,
    ) -> Result<Self, String> {
        info!("VllmPDRouter::new called with discovery_address: {}", discovery_address);

        // Create underlying PD router with empty worker lists (they'll be discovered dynamically)
        let pd_router = PDRouter::new(vec![], vec![], ctx).await?;

        // Initialize service discovery
        let mut service_registry = ServiceRegistry::new();

        info!("Starting vLLM service discovery on {}", discovery_address);
        service_registry.start_listener(&discovery_address).await
            .map_err(|e| format!("Failed to start service discovery: {}", e))?;

        info!("VllmPDRouter created successfully with pure service discovery");

        Ok(Self {
            pd_router,
            service_registry: Arc::new(service_registry),
            http_client: reqwest::Client::new(),
        })
    }

}

// Delegate most RouterTrait methods to the underlying PDRouter,
// but override specific ones for vLLM behavior
#[async_trait]
impl RouterTrait for VllmPDRouter {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    async fn health(&self, req: Request<Body>) -> Response {
        self.pd_router.health(req).await
    }

    async fn health_generate(&self, req: Request<Body>) -> Response {
        self.pd_router.health_generate(req).await
    }

    async fn get_server_info(&self, req: Request<Body>) -> Response {
        self.pd_router.get_server_info(req).await
    }

    async fn get_models(&self, req: Request<Body>) -> Response {
        self.pd_router.get_models(req).await
    }

    async fn get_model_info(&self, req: Request<Body>) -> Response {
        self.pd_router.get_model_info(req).await
    }

    async fn route_generate(
        &self,
        headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::GenerateRequest,
        model_id: Option<&str>,
    ) -> Response {
        self.pd_router.route_generate(headers, body, model_id).await
    }

    // Override OpenAI-compatible routes for vLLM two-stage processing
    async fn route_chat(
        &self,
        _headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::ChatCompletionRequest,
        _model_id: Option<&str>,
    ) -> Response {
        info!("vLLM route_chat called");

        // Convert to generic request and use vLLM processing
        let request_json = match serde_json::to_value(body) {
            Ok(json) => {
                info!("Serialized chat request: {}", serde_json::to_string_pretty(&json).unwrap_or_default());
                json
            },
            Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Serialization error: {}", e)).into_response(),
        };

        // Process vLLM two-stage request directly (no need for manual body parsing)
        self.process_vllm_request(request_json, "/v1/chat/completions").await
    }

    async fn route_completion(
        &self,
        _headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::CompletionRequest,
        _model_id: Option<&str>,
    ) -> Response {
        info!("vLLM route_completion called");

        // Convert to generic request and use vLLM processing
        let request_json = match serde_json::to_value(body) {
            Ok(json) => {
                info!("Serialized completion request: {}", serde_json::to_string_pretty(&json).unwrap_or_default());
                json
            },
            Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Serialization error: {}", e)).into_response(),
        };

        // Process vLLM two-stage request directly (no need for manual body parsing)
        self.process_vllm_request(request_json, "/v1/completions").await
    }

    async fn route_responses(
        &self,
        headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::ResponsesRequest,
        model_id: Option<&str>,
    ) -> Response {
        self.pd_router.route_responses(headers, body, model_id).await
    }

    async fn get_response(&self, headers: Option<&HeaderMap>, response_id: &str) -> Response {
        self.pd_router.get_response(headers, response_id).await
    }

    async fn cancel_response(&self, headers: Option<&HeaderMap>, response_id: &str) -> Response {
        self.pd_router.cancel_response(headers, response_id).await
    }

    async fn route_embeddings(
        &self,
        headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::EmbeddingRequest,
        model_id: Option<&str>,
    ) -> Response {
        self.pd_router.route_embeddings(headers, body, model_id).await
    }

    async fn route_rerank(
        &self,
        headers: Option<&HeaderMap>,
        body: &crate::protocols::spec::RerankRequest,
        model_id: Option<&str>,
    ) -> Response {
        self.pd_router.route_rerank(headers, body, model_id).await
    }

    async fn flush_cache(&self) -> Response {
        self.pd_router.flush_cache().await
    }

    async fn get_worker_loads(&self) -> Response {
        self.pd_router.get_worker_loads().await
    }

    fn router_type(&self) -> &'static str {
        "vllm_pd"
    }

    fn readiness(&self) -> Response {
        self.pd_router.readiness()
    }
}

// Delegate WorkerManagement to the underlying PDRouter
#[async_trait]
impl WorkerManagement for VllmPDRouter {
    async fn add_worker(&self, worker_url: &str) -> Result<String, String> {
        self.pd_router.add_worker(worker_url).await
    }

    fn remove_worker(&self, worker_url: &str) {
        self.pd_router.remove_worker(worker_url);
    }

    fn get_worker_urls(&self) -> Vec<String> {
        self.pd_router.get_worker_urls()
    }
}