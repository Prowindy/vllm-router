//! gRPC client module for communicating with vLLM scheduler
//!
//! This module provides a gRPC client implementation for the vLLM router.

pub mod client;

// Re-export the client
pub use client::{proto, VllmSchedulerClient};
