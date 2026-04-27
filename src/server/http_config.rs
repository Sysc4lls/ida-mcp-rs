//! Builds the rmcp Streamable HTTP transport configuration.

use rmcp::transport::streamable_http_server::StreamableHttpServerConfig;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone)]
pub struct HttpServerOptions {
    /// Hostnames accepted in the request `Host` header. Passed to rmcp
    /// as-is, so the caller should trim whitespace and drop empty entries.
    /// An empty list disables the rmcp DNS-rebinding host check entirely.
    pub allow_host: Vec<String>,
    /// SSE keep-alive interval in seconds; `0` disables.
    pub sse_keep_alive_secs: u64,
    /// Run in stateless mode (POST only, no sessions).
    pub stateless: bool,
    /// Return `application/json` instead of SSE in stateless mode.
    pub json_response: bool,
}

pub fn build_streamable_config(
    opts: HttpServerOptions,
    cancel: CancellationToken,
) -> StreamableHttpServerConfig {
    StreamableHttpServerConfig::default()
        .with_sse_keep_alive(if opts.sse_keep_alive_secs == 0 {
            None
        } else {
            Some(Duration::from_secs(opts.sse_keep_alive_secs))
        })
        .with_sse_retry(None)
        .with_stateful_mode(!opts.stateless)
        .with_json_response(opts.json_response && opts.stateless)
        .with_cancellation_token(cancel)
        .with_allowed_hosts(opts.allow_host)
}

#[cfg(test)]
mod tests {
    use crate::server::http_config::{build_streamable_config, HttpServerOptions};
    use tokio_util::sync::CancellationToken;

    fn opts(hosts: &[&str]) -> HttpServerOptions {
        HttpServerOptions {
            allow_host: hosts.iter().map(|s| (*s).to_string()).collect(),
            sse_keep_alive_secs: 15,
            stateless: false,
            json_response: false,
        }
    }

    #[test]
    fn allowed_hosts_are_passed_to_config() {
        let config = build_streamable_config(
            opts(&["example.com", "10.10.17.252"]),
            CancellationToken::new(),
        );
        assert_eq!(
            config.allowed_hosts,
            vec!["example.com".to_string(), "10.10.17.252".to_string()]
        );
    }

    #[test]
    fn empty_allow_host_disables_check() {
        let config = build_streamable_config(opts(&[]), CancellationToken::new());
        assert!(
            config.allowed_hosts.is_empty(),
            "rmcp treats an empty allowed_hosts list as 'allow all'"
        );
    }

    #[test]
    fn loopback_default_matches_rmcp_default() {
        let config = build_streamable_config(
            opts(&["localhost", "127.0.0.1", "::1"]),
            CancellationToken::new(),
        );
        assert_eq!(
            config.allowed_hosts,
            vec![
                "localhost".to_string(),
                "127.0.0.1".to_string(),
                "::1".to_string()
            ]
        );
    }
}
