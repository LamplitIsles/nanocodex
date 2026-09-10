use std::{future::Future, pin::Pin, sync::Arc};

use crate::{
    ModelConfig, OpenAiAuthSnapshot, ResponsesError,
    socket::{ConnectionMetadata, ResponsesSocket},
    tower::{ResponsesServiceError, ResponsesServiceResponse},
    transport::host::HostTransport,
};

use crate::EncodedRequest;
use crate::transport::host::http::{HttpMetadata, ResponsesHttpStream};

pub(crate) type ServiceFuture =
    Pin<Box<dyn Future<Output = Result<ResponsesServiceResponse, ResponsesServiceError>>>>;

#[derive(Clone)]
pub(crate) struct ServicePlatform {
    host: Option<Arc<dyn HostTransport>>,
}

impl ServicePlatform {
    pub(crate) fn new(config: &ModelConfig) -> Self {
        Self {
            host: config.host_transport.clone(),
        }
    }

    pub(crate) fn host(&self) -> Result<&dyn HostTransport, ResponsesError> {
        self.host.as_deref().ok_or(ResponsesError::HostUnavailable)
    }

    pub(crate) async fn send_http(
        &self,
        config: &ModelConfig,
        auth: &OpenAiAuthSnapshot,
        session_id: &str,
        thread_id: &str,
        turn_state: Option<&str>,
        request: &EncodedRequest,
    ) -> Result<(ResponsesHttpStream, HttpMetadata), ResponsesError> {
        ResponsesHttpStream::send(
            self.host()?,
            &config.api_base_url,
            auth,
            session_id,
            thread_id,
            turn_state,
            request,
        )
        .await
    }
}

pub(crate) async fn connect_socket(
    platform: &ServicePlatform,
    config: &ModelConfig,
    auth: &OpenAiAuthSnapshot,
    session_id: &str,
    thread_id: &str,
    turn_state: Option<&str>,
) -> Result<(ResponsesSocket, ConnectionMetadata), ResponsesError> {
    let host = platform.host()?;
    ResponsesSocket::connect(
        host,
        &config.websocket_url,
        auth,
        session_id,
        thread_id,
        turn_state,
    )
    .await
}
