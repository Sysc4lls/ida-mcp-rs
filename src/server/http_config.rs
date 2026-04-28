//! Builds the rmcp Streamable HTTP transport configuration.

use rmcp::transport::streamable_http_server::StreamableHttpServerConfig;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone)]
pub struct HttpServerOptions {
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
        // Host validation is handled by HttpAccessService so the CLI can apply
        // bind-aware LAN rules and return actionable 403 messages.
        .with_allowed_hosts(Vec::<String>::new())
}

#[cfg(test)]
mod tests {
    use crate::server::http_config::{build_streamable_config, HttpServerOptions};
    use tokio_util::sync::CancellationToken;

    fn opts() -> HttpServerOptions {
        HttpServerOptions {
            sse_keep_alive_secs: 15,
            stateless: false,
            json_response: false,
        }
    }

    #[test]
    fn rmcp_host_check_is_disabled_for_outer_access_policy() {
        let config = build_streamable_config(opts(), CancellationToken::new());
        assert!(
            config.allowed_hosts.is_empty(),
            "HttpAccessService owns Host validation so rmcp's duplicate check stays disabled"
        );
    }

    #[test]
    fn json_response_only_enabled_in_stateless_mode() {
        let mut opts = opts();
        opts.json_response = true;

        let stateful = build_streamable_config(opts.clone(), CancellationToken::new());
        assert!(!stateful.json_response);

        opts.stateless = true;
        let stateless = build_streamable_config(opts, CancellationToken::new());
        assert!(stateless.json_response);
    }
}
