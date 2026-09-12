use nanocodex_oai_api::responses::ResponseItem;

#[cfg(feature = "openai")]
use crate::session::CommittedSession;

/// Read-only model context exposed to session adapters.
///
/// The history is complete and unredacted and can contain reasoning and tool
/// inputs or outputs. Applications must protect it like a session snapshot.
#[derive(Clone, Debug)]
pub struct AgentSessionContext {
    workspace: String,
    history: Vec<ResponseItem>,
    context_window_tokens: u64,
    active_context_tokens: u64,
}

impl AgentSessionContext {
    #[cfg(feature = "openai")]
    pub(super) fn new(
        checkpoint: Option<&CommittedSession>,
        workspace: String,
        context_window_tokens: u64,
    ) -> Self {
        let (history, active_context_tokens) = checkpoint.map_or_else(
            || (Vec::new(), 0),
            |checkpoint| {
                (
                    checkpoint.model().snapshot_history(),
                    checkpoint.model().active_context_tokens(),
                )
            },
        );
        Self {
            workspace,
            history,
            context_window_tokens,
            active_context_tokens,
        }
    }

    /// Constructs a context snapshot observed by an external lifecycle backend.
    #[doc(hidden)]
    #[must_use]
    pub const fn from_backend(
        workspace: String,
        history: Vec<ResponseItem>,
        context_window_tokens: u64,
        active_context_tokens: u64,
    ) -> Self {
        Self {
            workspace,
            history,
            context_window_tokens,
            active_context_tokens,
        }
    }

    /// Returns the absolute workspace owned by the agent session.
    #[must_use]
    pub fn workspace(&self) -> &str {
        &self.workspace
    }

    /// Returns complete model-visible history at the latest safe boundary.
    #[must_use]
    pub fn history(&self) -> &[ResponseItem] {
        &self.history
    }

    /// Returns the configured model context capacity in tokens.
    #[must_use]
    pub const fn context_window_tokens(&self) -> u64 {
        self.context_window_tokens
    }

    /// Returns the engine's current active-context estimate in tokens.
    #[must_use]
    pub const fn active_context_tokens(&self) -> u64 {
        self.active_context_tokens
    }
}
