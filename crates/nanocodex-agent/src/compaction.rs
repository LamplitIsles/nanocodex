//! Host-owned context replacement and engine-owned compaction accounting.

use std::{collections::HashSet, future::Future, pin::Pin, sync::Arc};

use serde::{Deserialize, Serialize};

use nanocodex_oai_api::{
    __private::compaction::CompactionInstallation,
    responses::{ContentItem, MessageRole, ResponseItem},
};

use crate::{AgentSessionContext, NanocodexError, Result};

/// The lifecycle boundary at which a compaction was requested.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionPhase {
    /// Compaction before a new user turn is sent.
    PreTurn,
    /// Compaction while continuing a model turn or after tool execution.
    MidTurn,
}

/// The reason the current compaction operation was started.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionTrigger {
    /// An explicit maintenance request from the embedding host.
    Manual,
    /// Automatic pressure or provider-overflow recovery.
    Automatic,
}

/// Operation metadata supplied to the host before summary generation.
#[derive(Clone, Debug, Serialize)]
pub struct CompactionInstructionContext {
    /// Model-call boundary at which the operation was admitted.
    pub after_model_call_index: u32,
    /// Whether the operation is before a turn or inside a continuation.
    pub phase: CompactionPhase,
    /// Whether the operation was explicit or automatic.
    pub trigger: CompactionTrigger,
    /// Estimated active context before summary generation.
    pub active_context_tokens: u64,
    /// Automatic threshold that admitted the operation.
    pub auto_compact_token_limit: u64,
}

#[cfg(not(target_family = "wasm"))]
/// Boxed asynchronous result returned by a pre-summary instruction resolver.
pub type CompactionInstructionFuture =
    Pin<Box<dyn Future<Output = Result<String>> + Send + 'static>>;

#[cfg(target_family = "wasm")]
/// Boxed asynchronous result returned by a pre-summary instruction resolver.
pub type CompactionInstructionFuture = Pin<Box<dyn Future<Output = Result<String>> + 'static>>;

/// Embedding-owned asynchronous selector for the summary instruction.
pub trait CompactionInstructionResolver: 'static {
    /// Resolves the instruction before Nanocodex dispatches summary generation.
    /// An error, cancellation, or empty result aborts compaction without a
    /// generic-summary fallback.
    fn resolve(&self, context: CompactionInstructionContext) -> CompactionInstructionFuture;
}

#[cfg(not(target_family = "wasm"))]
impl<T> CompactionInstructionResolver for Arc<T>
where
    T: CompactionInstructionResolver + Send + Sync,
{
    fn resolve(&self, context: CompactionInstructionContext) -> CompactionInstructionFuture {
        (**self).resolve(context)
    }
}

pub(crate) fn validate_instruction(instruction: String) -> Result<Arc<str>> {
    if instruction.trim().is_empty() {
        return Err(NanocodexError::InvalidRequest(
            "compaction instruction resolver returned an empty instruction".to_owned(),
        ));
    }
    Ok(Arc::from(instruction))
}

/// Stable identity for one item in the immutable pre-replacement history.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CompactionItemIdentity {
    /// The item's pre-replacement history index.
    pub index: usize,
    /// The stable Responses item kind.
    pub kind: String,
    /// The provider or client item ID when the item has one.
    pub id: Option<String>,
    /// The tool call ID when the item is a tool call or output.
    pub call_id: Option<String>,
}

impl CompactionItemIdentity {
    /// Returns the item's pre-replacement history index.
    #[must_use]
    pub const fn index(&self) -> usize {
        self.index
    }

    /// Returns the stable Responses item kind.
    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }

    /// Returns the provider or client item ID when the item has one.
    #[must_use]
    pub fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }

    /// Returns the tool call ID when the item is a tool call or output.
    #[must_use]
    pub fn call_id(&self) -> Option<&str> {
        self.call_id.as_deref()
    }
}

/// One immutable history item supplied to the host replacement resolver.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CompactionHistoryItem {
    /// Truthful identity of the item in the history supplied to the resolver.
    pub origin: CompactionItemIdentity,
    /// Exact typed item observed at the safe compaction boundary.
    pub item: ResponseItem,
}

/// One item selected for the replacement history.
///
/// Original items must carry the identity received in [`CompactionContext`].
/// New items are validated by the engine before installation. Summary entries
/// are wrapped as private developer context by Nanocodex, so hosts do not need
/// to reproduce the engine's summary marker.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CompactionReplacementItem {
    /// Retain one exact item from the supplied immutable history.
    Original {
        /// Identity copied from the operation snapshot.
        origin: CompactionItemIdentity,
    },
    /// Insert a host-created typed history item.
    Item {
        /// Typed item to validate and install.
        item: ResponseItem,
    },
    /// Insert host-selected summary text at this position.
    Summary {
        /// Summary text to wrap as private developer context.
        text: String,
    },
}

/// Host decision for one compaction operation.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CompactionDecision {
    /// Opaque operation identity copied from [`CompactionContext::operation_id`].
    pub operation_id: String,
    /// Complete replacement history in provider order.
    pub history: Vec<CompactionReplacementItem>,
}

#[cfg(not(target_family = "wasm"))]
/// Boxed asynchronous result returned by a host replacement resolver.
pub type CompactionFuture =
    Pin<Box<dyn Future<Output = Result<CompactionDecision>> + Send + 'static>>;

#[cfg(target_family = "wasm")]
/// Boxed asynchronous result returned by a host replacement resolver.
pub type CompactionFuture = Pin<Box<dyn Future<Output = Result<CompactionDecision>> + 'static>>;

/// Embedding-owned asynchronous selector for one complete replacement history.
pub trait CompactionResolver: 'static {
    /// Selects the exact history to install after Nanocodex generated its
    /// private summary. Returning an error or a stale/invalid decision leaves
    /// the active history untouched.
    fn resolve(&self, context: CompactionContext) -> CompactionFuture;
}

#[cfg(not(target_family = "wasm"))]
impl<T> CompactionResolver for Arc<T>
where
    T: CompactionResolver + Send + Sync,
{
    fn resolve(&self, context: CompactionContext) -> CompactionFuture {
        (**self).resolve(context)
    }
}

/// Immutable operation snapshot supplied to a host replacement resolver.
#[derive(Clone, Debug, Serialize)]
pub struct CompactionContext {
    /// Model-call boundary at which the operation was admitted.
    pub after_model_call_index: u32,
    /// Whether the operation is before a turn or inside a continuation.
    pub phase: CompactionPhase,
    /// Whether the operation was explicit or automatic.
    pub trigger: CompactionTrigger,
    /// Estimated active context before summary generation.
    pub active_context_tokens: u64,
    /// Actual configured model context capacity.
    pub context_window_tokens: u64,
    /// Automatic threshold that admitted the operation.
    pub auto_compact_token_limit: u64,
    /// Managed-history revision captured before this operation.
    pub history_revision: u64,
    /// Opaque token that a decision must echo before it can be installed.
    pub operation_id: String,
    /// Exact safe-boundary history being compacted, with origin identities.
    pub history: Vec<CompactionHistoryItem>,
    /// Private summary generated by the engine for this operation.
    pub summary: String,
}

/// One installed item and its original-history provenance, when applicable.
#[derive(Clone, Debug, Serialize)]
pub struct CompactionInstalledItem {
    /// Original identity for retained items, or `None` for host-created items.
    pub origin: Option<CompactionItemIdentity>,
    /// Exact typed item installed into the managed session.
    pub item: ResponseItem,
}

/// Result of one completed host-selected context replacement.
#[derive(Clone, Debug)]
pub struct CompactionOutcome {
    revision: u64,
    trigger: CompactionTrigger,
    summary: Option<String>,
    installed_history: Vec<CompactionInstalledItem>,
    context: AgentSessionContext,
}

/// Ordered event payload emitted at the exact replacement boundary.
#[derive(Serialize)]
pub(crate) struct CompactionReplacedEvent<'a> {
    pub(crate) after_model_call_index: u32,
    pub(crate) phase: CompactionPhase,
    pub(crate) revision: String,
    pub(crate) trigger: CompactionTrigger,
    pub(crate) summary: Option<&'a str>,
    pub(crate) installed_history: &'a [CompactionInstalledItem],
    pub(crate) context: CompactionReplacedContext<'a>,
}

#[derive(Serialize)]
pub(crate) struct CompactionReplacedContext<'a> {
    pub(crate) workspace: &'a str,
    pub(crate) context_window_tokens: u64,
    pub(crate) active_context_tokens: u64,
    pub(crate) history: &'a [ResponseItem],
}

impl CompactionOutcome {
    pub(crate) fn pending(
        revision: u64,
        trigger: CompactionTrigger,
        summary: Option<String>,
        installed_history: Vec<CompactionInstalledItem>,
    ) -> Self {
        Self {
            revision,
            trigger,
            summary,
            installed_history,
            context: AgentSessionContext::from_backend(String::new(), Vec::new(), 0, 0),
        }
    }

    pub(crate) fn with_context(mut self, context: AgentSessionContext) -> Self {
        self.context = context;
        self
    }

    pub(crate) fn event<'a>(
        &'a self,
        after_model_call_index: u32,
        phase: CompactionPhase,
    ) -> CompactionReplacedEvent<'a> {
        CompactionReplacedEvent {
            after_model_call_index,
            phase,
            revision: self.revision.to_string(),
            trigger: self.trigger,
            summary: self.summary.as_deref(),
            installed_history: &self.installed_history,
            context: CompactionReplacedContext {
                workspace: self.context.workspace(),
                context_window_tokens: self.context.context_window_tokens(),
                active_context_tokens: self.context.active_context_tokens(),
                history: self.context.history(),
            },
        }
    }

    /// Returns the monotonic history-replacement revision.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Returns whether the replacement was explicitly requested or automatic.
    #[must_use]
    pub const fn trigger(&self) -> CompactionTrigger {
        self.trigger
    }

    /// Returns the generated private summary, when the custom path produced one.
    #[must_use]
    pub fn summary(&self) -> Option<&str> {
        self.summary.as_deref()
    }

    /// Returns the complete installed history and truthful provenance mapping.
    #[must_use]
    pub fn installed_history(&self) -> &[CompactionInstalledItem] {
        &self.installed_history
    }

    /// Returns the complete model-visible context after this replacement.
    #[must_use]
    pub const fn context(&self) -> &AgentSessionContext {
        &self.context
    }
}

pub(crate) fn operation_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

pub(crate) fn context_history(history: &[ResponseItem]) -> Vec<CompactionHistoryItem> {
    history
        .iter()
        .enumerate()
        .map(|(index, item)| CompactionHistoryItem {
            origin: item_identity(index, item),
            item: item.clone(),
        })
        .collect()
}

/// Validates and materializes a host decision without mutating session state.
pub(crate) fn materialize_decision(
    context: &CompactionContext,
    decision: CompactionDecision,
) -> Result<(Vec<ResponseItem>, Vec<Option<usize>>)> {
    if decision.operation_id != context.operation_id {
        return Err(NanocodexError::InvalidRequest(
            "compaction decision belongs to a different operation".to_owned(),
        ));
    }
    let mut selected = Vec::with_capacity(decision.history.len());
    let mut provenance = Vec::with_capacity(decision.history.len());
    let mut origins = HashSet::new();
    for replacement in decision.history {
        match replacement {
            CompactionReplacementItem::Original { origin } => {
                if !origins.insert(origin.index) {
                    return Err(NanocodexError::InvalidRequest(
                        "compaction decision selected an original item more than once".to_owned(),
                    ));
                }
                let Some(original) = context.history.iter().find(|item| item.origin == origin)
                else {
                    return Err(NanocodexError::InvalidRequest(
                        "compaction decision referenced an item outside its operation snapshot"
                            .to_owned(),
                    ));
                };
                selected.push(original.item.clone());
                provenance.push(Some(origin.index));
            }
            CompactionReplacementItem::Item { item } => {
                selected.push(item);
                provenance.push(None);
            }
            CompactionReplacementItem::Summary { text } => {
                if text.trim().is_empty() {
                    return Err(NanocodexError::InvalidRequest(
                        "compaction summary replacement must not be empty".to_owned(),
                    ));
                }
                selected.push(ResponseItem::message(
                    MessageRole::Developer,
                    [ContentItem::input_text(format!(
                        "<compacted-summary>\n{text}\n</compacted-summary>"
                    ))],
                ));
                provenance.push(None);
            }
        }
    }
    Ok((selected, provenance))
}

pub(crate) fn outcome_from_installation(
    installation: CompactionInstallation,
    input_history: &[ResponseItem],
    revision: u64,
    trigger: CompactionTrigger,
    summary: Option<String>,
) -> CompactionOutcome {
    let installed_history = installation
        .history
        .into_iter()
        .zip(installation.provenance)
        .map(|(item, origin)| CompactionInstalledItem {
            origin: origin.and_then(|index| {
                input_history
                    .get(index)
                    .map(|item| item_identity(index, item))
            }),
            item,
        })
        .collect();
    CompactionOutcome::pending(revision, trigger, summary, installed_history)
}

pub(crate) fn summary_text(item: &ResponseItem) -> Option<String> {
    let ResponseItem::Message {
        role: MessageRole::Developer,
        content,
        ..
    } = item
    else {
        return None;
    };
    let text = content.iter().find_map(|content| match content {
        ContentItem::InputText { text } => Some(text),
        _ => None,
    })?;
    text.strip_prefix("<compacted-summary>\n")
        .and_then(|text| text.strip_suffix("\n</compacted-summary>"))
        .map(str::to_owned)
}

fn item_identity(index: usize, item: &ResponseItem) -> CompactionItemIdentity {
    let value = serde_json::to_value(item).unwrap_or_default();
    CompactionItemIdentity {
        index,
        kind: value
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        id: item.id().map(ToString::to_string),
        call_id: value
            .get("call_id")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> CompactionContext {
        let history = vec![
            ResponseItem::message(MessageRole::User, [ContentItem::input_text("first")]),
            ResponseItem::message(MessageRole::Assistant, [ContentItem::output_text("second")]),
            ResponseItem::message(MessageRole::User, [ContentItem::input_text("third")]),
        ];
        CompactionContext {
            after_model_call_index: 2,
            phase: CompactionPhase::PreTurn,
            trigger: CompactionTrigger::Manual,
            active_context_tokens: 30,
            context_window_tokens: 100,
            auto_compact_token_limit: 90,
            history_revision: 4,
            operation_id: "operation-1".to_owned(),
            history: context_history(&history),
            summary: "generated summary".to_owned(),
        }
    }

    #[test]
    fn materializes_non_contiguous_originals_and_host_summary() {
        let context = context();
        let decision = CompactionDecision {
            operation_id: context.operation_id.clone(),
            history: vec![
                CompactionReplacementItem::Original {
                    origin: context.history[0].origin.clone(),
                },
                CompactionReplacementItem::Summary {
                    text: "host summary".to_owned(),
                },
                CompactionReplacementItem::Original {
                    origin: context.history[2].origin.clone(),
                },
            ],
        };
        let (history, provenance) = materialize_decision(&context, decision).unwrap();
        assert_eq!(history.len(), 3);
        assert_eq!(provenance, vec![Some(0), None, Some(2)]);
        assert!(summary_text(&history[1]).is_some_and(|summary| summary == "host summary"));
    }

    #[test]
    fn permits_zero_retained_originals() {
        let context = context();
        let decision = CompactionDecision {
            operation_id: context.operation_id.clone(),
            history: vec![CompactionReplacementItem::Summary {
                text: "only the host summary".to_owned(),
            }],
        };
        let (history, provenance) = materialize_decision(&context, decision).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(provenance, vec![None]);
    }

    #[test]
    fn rejects_stale_or_unknown_original_identity() {
        let context = context();
        let mut stale = context.history[0].origin.clone();
        stale.index = 99;
        let error = materialize_decision(
            &context,
            CompactionDecision {
                operation_id: context.operation_id.clone(),
                history: vec![CompactionReplacementItem::Original { origin: stale }],
            },
        )
        .expect_err("unknown original identities must not install");
        assert!(error.to_string().contains("outside its operation snapshot"));
    }

    #[test]
    fn operation_ids_are_fresh_opaque_tokens() {
        let first = operation_id();
        let second = operation_id();
        assert_ne!(first, second);
        assert_eq!(first.len(), 36);
        assert_eq!(second.len(), 36);
    }

    #[test]
    fn rejects_a_decision_from_a_failed_operation_on_retry() {
        let first = context();
        let mut retry = context();
        retry.operation_id = operation_id();
        let stale = CompactionDecision {
            operation_id: first.operation_id,
            history: vec![CompactionReplacementItem::Summary {
                text: "stale summary".to_owned(),
            }],
        };
        let error = materialize_decision(&retry, stale)
            .expect_err("a failed operation's decision must not install on retry");
        assert!(error.to_string().contains("different operation"));
    }

    #[test]
    fn rejects_a_decision_cached_before_cancellation_on_retry() {
        let cancelled = context();
        let mut retry = context();
        retry.operation_id = operation_id();
        let stale = CompactionDecision {
            operation_id: cancelled.operation_id,
            history: Vec::new(),
        };
        let error = materialize_decision(&retry, stale)
            .expect_err("a cancelled operation's decision must not install on retry");
        assert!(error.to_string().contains("different operation"));
    }
}
