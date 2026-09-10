use std::time::Duration;

use super::socket::ReceivedText;
use crate::{
    EncodedRequest, OpenAiAuthSnapshot, ResponsesError,
    transport::{
        host::{HostConnection, HostError, HostHttpRequest, HostMessage, HostTransport},
        sse::SseDecoder,
    },
};

const EVENT_IDLE_TIMEOUT: Duration = if cfg!(test) {
    Duration::from_millis(100)
} else {
    Duration::from_mins(5)
};

/// Streaming HTTPS Responses connection owned by an embedding host.
pub(crate) struct ResponsesHttpStream {
    connection: Box<dyn HostConnection>,
    decoder: SseDecoder,
    ended: bool,
}

/// Metadata returned when a host-owned HTTPS request receives its headers.
pub(crate) struct HttpMetadata {
    pub(crate) reasoning_included: bool,
    pub(crate) turn_state: Option<String>,
}

impl ResponsesHttpStream {
    pub(crate) async fn send(
        host: &dyn HostTransport,
        api_base_url: &str,
        auth: &OpenAiAuthSnapshot,
        session_id: &str,
        thread_id: &str,
        turn_state: Option<&str>,
        request: &EncodedRequest,
    ) -> Result<(Self, HttpMetadata), ResponsesError> {
        let endpoint = format!("{}/responses", api_base_url.trim_end_matches('/'));
        let request = HostHttpRequest::new(
            &endpoint,
            auth.bearer(),
            auth.account_id(),
            auth.is_fedramp(),
            session_id,
            thread_id,
            turn_state,
            request.raw().get(),
        );
        let (connection, metadata) = host
            .http(request)
            .await
            .map_err(map_host_error)?
            .into_parts();
        if !(200..300).contains(&metadata.status) {
            return Err(ResponsesError::HttpRejected {
                status: metadata.status,
                body: "host returned a non-success HTTPS status without a rejection body"
                    .to_owned(),
                retry_after: None,
            });
        }
        Ok((
            Self {
                connection,
                decoder: SseDecoder::default(),
                ended: false,
            },
            HttpMetadata {
                reasoning_included: metadata.reasoning_included,
                turn_state: metadata.turn_state,
            },
        ))
    }

    pub(crate) async fn next_text_or_idle_timeout(
        &mut self,
    ) -> Result<ReceivedText, ResponsesError> {
        self.next_text().await
    }

    async fn next_text(&mut self) -> Result<ReceivedText, ResponsesError> {
        loop {
            if let Some(text) = self.decoder.next()? {
                return Ok(ReceivedText {
                    text,
                    received_ns: crate::monotonic_now_ns(),
                });
            }
            if self.ended {
                return Err(ResponsesError::UnexpectedEnd);
            }
            match self
                .connection
                .next(EVENT_IDLE_TIMEOUT)
                .await
                .map_err(map_host_error)?
            {
                HostMessage::Chunk { text } => self.decoder.push(text.as_bytes())?,
                HostMessage::Eof => {
                    self.ended = true;
                    self.decoder.finish()?
                }
                HostMessage::Text(_) => {
                    return Err(ResponsesError::HttpRequest {
                        detail: "host returned a WebSocket text frame for an HTTPS response"
                            .to_owned(),
                        retryable: false,
                        timeout: false,
                    });
                }
                HostMessage::Closed { detail } => {
                    return Err(ResponsesError::HttpRequest {
                        detail: format!("HTTPS Responses stream closed {detail}"),
                        retryable: true,
                        timeout: false,
                    });
                }
                HostMessage::Timeout => {
                    return Err(ResponsesError::IdleTimeout {
                        seconds: EVENT_IDLE_TIMEOUT.as_secs(),
                    });
                }
                HostMessage::Binary => return Err(ResponsesError::UnexpectedBinary),
            }
        }
    }
}

impl Drop for ResponsesHttpStream {
    fn drop(&mut self) {
        self.connection.close();
    }
}

fn map_host_error(error: HostError) -> ResponsesError {
    match error {
        HostError::HttpRejected {
            status,
            body,
            retry_after,
        }
        | HostError::HandshakeRejected {
            status,
            body,
            retry_after,
        } => ResponsesError::HttpRejected {
            status,
            body,
            retry_after,
        },
        HostError::Transport {
            detail,
            reconnectable,
        } => ResponsesError::HttpRequest {
            detail,
            retryable: reconnectable,
            timeout: false,
        },
    }
}
