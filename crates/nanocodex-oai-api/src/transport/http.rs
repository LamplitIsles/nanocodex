use std::time::Duration;

use crate::{OpenAiAuthSnapshot, monotonic_now_ns};
use http::header;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Utf8Bytes;

use crate::{EncodedRequest, ResponsesError, socket::ReceivedText, transport::sse::SseDecoder};

const EVENT_IDLE_TIMEOUT: Duration = if cfg!(test) {
    Duration::from_millis(100)
} else {
    Duration::from_mins(5)
};
const RESPONSES_LITE_HEADER: &str = "x-openai-internal-codex-responses-lite";
const TURN_STATE_HEADER: &str = "x-codex-turn-state";

#[derive(Clone)]
pub(crate) struct ResponsesHttp {
    client: reqwest::Client,
}

pub(crate) struct ResponsesHttpStream {
    response: reqwest::Response,
    decoder: SseDecoder,
    ended: bool,
}

pub(crate) struct HttpMetadata {
    pub(crate) reasoning_included: bool,
    pub(crate) turn_state: Option<String>,
}

impl ResponsesHttp {
    pub(crate) const fn new(client: reqwest::Client) -> Self {
        Self { client }
    }

    pub(crate) async fn send(
        &self,
        api_base_url: &str,
        auth: &OpenAiAuthSnapshot,
        session_id: &str,
        thread_id: &str,
        turn_state: Option<&str>,
        request: &EncodedRequest,
    ) -> Result<(ResponsesHttpStream, HttpMetadata), ResponsesError> {
        let endpoint = format!("{}/responses", api_base_url.trim_end_matches('/'));
        let mut builder = self
            .client
            .post(endpoint)
            .bearer_auth(auth.bearer())
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::ACCEPT, "text/event-stream")
            .header(RESPONSES_LITE_HEADER, "true")
            .header("session-id", session_id)
            .header("thread-id", thread_id)
            .header("x-client-request-id", thread_id)
            .header(
                header::USER_AGENT,
                concat!("nanocodex/", env!("CARGO_PKG_VERSION")),
            )
            .body(request.raw().get().to_owned());
        if let Some(account_id) = auth.account_id() {
            builder = builder.header("ChatGPT-Account-ID", account_id);
        }
        if auth.is_fedramp() {
            builder = builder.header("X-OpenAI-Fedramp", "true");
        }
        if let Some(turn_state) =
            turn_state.and_then(|value| header::HeaderValue::from_bytes(value.as_bytes()).ok())
        {
            builder = builder.header(TURN_STATE_HEADER, turn_state);
        }
        let response = builder.send().await.map_err(map_http_error)?;
        let status = response.status();
        if !status.is_success() {
            let retry_after = retry_after(response.headers());
            let body = response.text().await.unwrap_or_default();
            return Err(ResponsesError::HttpRejected {
                status: status.as_u16(),
                body,
                retry_after,
            });
        }
        let metadata = HttpMetadata {
            reasoning_included: response.headers().contains_key("x-reasoning-included"),
            turn_state: response
                .headers()
                .get(TURN_STATE_HEADER)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned),
        };
        Ok((
            ResponsesHttpStream {
                response,
                decoder: SseDecoder::default(),
                ended: false,
            },
            metadata,
        ))
    }
}

impl ResponsesHttpStream {
    pub(crate) async fn next_text_or_idle_timeout(
        &mut self,
    ) -> Result<ReceivedText, ResponsesError> {
        timeout(EVENT_IDLE_TIMEOUT, self.next_text())
            .await
            .map_err(|_| ResponsesError::IdleTimeout {
                seconds: EVENT_IDLE_TIMEOUT.as_secs(),
            })?
    }

    async fn next_text(&mut self) -> Result<ReceivedText, ResponsesError> {
        loop {
            if let Some(text) = self.decoder.next()? {
                return Ok(ReceivedText {
                    text: Utf8Bytes::from(text),
                    received_ns: monotonic_now_ns(),
                });
            }
            if self.ended {
                return Err(ResponsesError::UnexpectedEnd);
            }
            if let Some(chunk) = self.response.chunk().await.map_err(map_http_error)? {
                self.decoder.push(&chunk);
            } else {
                self.ended = true;
                self.decoder.finish();
            }
        }
    }
}

fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    headers
        .get(header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .map(Duration::from_secs)
}

fn map_http_error(error: reqwest::Error) -> ResponsesError {
    ResponsesError::HttpRequest {
        retryable: error.is_connect() || error.is_body(),
        timeout: error.is_timeout(),
        detail: error.to_string(),
    }
}
