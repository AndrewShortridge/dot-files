//! HTTP server setup

use crate::middleware;
use crate::routes::create_router;
use crate::state::AppState;
use axum::middleware::from_fn;
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::info;

/// Server configuration
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub cors_enabled: bool,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 8080,
            cors_enabled: true,
        }
    }
}

/// HTTP server
pub struct Server {
    config: ServerConfig,
    state: AppState,
}

impl Server {
    /// Create a new server
    pub fn new(state: AppState, config: ServerConfig) -> Self {
        Self { config, state }
    }

    /// Create with default configuration
    pub fn with_defaults(state: AppState) -> Self {
        Self::new(state, ServerConfig::default())
    }

    /// Build the Axum app
    pub fn build_app(&self) -> axum::Router {
        let mut app = create_router(self.state.clone());

        // Add middleware
        app = app
            .layer(from_fn(middleware::logging_middleware))
            .layer(from_fn(middleware::request_id_middleware))
            .layer(TraceLayer::new_for_http());

        // Add CORS if enabled
        if self.config.cors_enabled {
            let cors = CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any);
            app = app.layer(cors);
        }

        app
    }

    /// Run the server
    pub async fn run(self) -> Result<(), std::io::Error> {
        let addr: SocketAddr = format!("{}:{}", self.config.host, self.config.port)
            .parse()
            .expect("Invalid address");

        let app = self.build_app();
        let listener = TcpListener::bind(addr).await?;

        info!(
            host = %self.config.host,
            port = %self.config.port,
            "Starting server"
        );

        axum::serve(listener, app).await
    }

    /// Get the server address
    pub fn address(&self) -> String {
        format!("{}:{}", self.config.host, self.config.port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_server_config_default() {
        let config = ServerConfig::default();
        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.port, 8080);
        assert!(config.cors_enabled);
    }

    #[test]
    fn test_server_config_custom() {
        let config = ServerConfig {
            host: "0.0.0.0".to_string(),
            port: 3000,
            cors_enabled: false,
        };
        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.port, 3000);
        assert!(!config.cors_enabled);
    }

    #[test]
    fn test_server_config_host_port_combinations() {
        let config = ServerConfig {
            host: "192.168.1.100".to_string(),
            port: 443,
            cors_enabled: true,
        };
        assert_eq!(config.host, "192.168.1.100");
        assert_eq!(config.port, 443);
    }

    #[test]
    fn test_server_config_ipv6() {
        let config = ServerConfig {
            host: "::1".to_string(),
            port: 8080,
            cors_enabled: false,
        };
        assert_eq!(config.host, "::1");
    }

    #[test]
    fn test_server_config_wildcard() {
        let config = ServerConfig {
            host: "0.0.0.0".to_string(),
            port: 80,
            cors_enabled: true,
        };
        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.port, 80);
    }
}
