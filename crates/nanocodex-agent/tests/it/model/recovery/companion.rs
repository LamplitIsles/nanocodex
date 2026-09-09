use std::{
    future::{Ready, ready},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
    },
    task::{Context, Poll},
};

use nanocodex_oai_api::{
    responses::{ContentItem, MessageRole, ResponseItem, Usage},
    tower::{
        CodeCall, CodeCallKind, GenerationOutput, ResponsePipelineStats, ResponsesAttempt,
        ResponsesAttemptKind, ResponsesOutput, ResponsesServiceResponse,
    },
};
use tower::Service;

use super::*;

const COMPANION_INSTRUCTION: &str = "Keep durable facts and recent work in a compact summary.";

#[derive(Default)]
struct AttemptObservations {
    kinds: Vec<&'static str>,
    previous_response_ids: Vec<Option<String>>,
}

#[derive(Clone, Copy)]
enum CompanionFlow {
    AutomaticPressure,
    MidToolPressure,
    ContextOverflow,
}

#[derive(Clone)]
struct CompanionService {
    calls: Arc<AtomicU32>,
    observations: Arc<Mutex<AttemptObservations>>,
    flow: CompanionFlow,
}

impl Service<ResponsesAttempt> for CompanionService {
    type Response = ResponsesServiceResponse;
    type Error = ResponseError;
    type Future = Ready<std::result::Result<Self::Response, Self::Error>>;

    fn poll_ready(
        &mut self,
        _context: &mut Context<'_>,
    ) -> Poll<std::result::Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, request: ResponsesAttempt) -> Self::Future {
        let kind = match request.kind() {
            ResponsesAttemptKind::Warmup => "warmup",
            ResponsesAttemptKind::Generation => "generation",
            ResponsesAttemptKind::Compaction => "compaction",
            _ => "unknown",
        };
        let input = request
            .input_items()
            .map(|item| serde_json::to_value(item).expect("attempt input serializes"))
            .collect::<Vec<_>>();
        let previous_response_id = request.previous_response_id().map(str::to_owned);
        {
            let mut observations = self.observations.lock().unwrap();
            observations.kinds.push(kind);
            observations
                .previous_response_ids
                .push(previous_response_id.clone());
        }
        let call = self.calls.fetch_add(1, Ordering::Relaxed);
        let result = match (self.flow, call, request.kind()) {
            (CompanionFlow::AutomaticPressure, 0, ResponsesAttemptKind::Generation) => {
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-pressure-before",
                    "pressure baseline",
                    120,
                )))
            }
            (CompanionFlow::AutomaticPressure, 1, ResponsesAttemptKind::Generation) => {
                assert!(contains_text(&input, COMPANION_INSTRUCTION));
                assert!(!input.iter().any(|item| item["type"] == "additional_tools"));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-pressure-summary",
                    "CUSTOM_PRESSURE_SUMMARY",
                    30,
                )))
            }
            (CompanionFlow::AutomaticPressure, 2, ResponsesAttemptKind::Generation) => {
                assert!(previous_response_id.is_none());
                assert!(contains_text(&input, "<compacted-summary>"));
                assert!(contains_text(&input, "CUSTOM_PRESSURE_SUMMARY"));
                assert!(contains_text(&input, "after pressure"));
                assert!(!contains_text(&input, COMPANION_INSTRUCTION));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-pressure-after",
                    "continued after automatic pressure compaction",
                    30,
                )))
            }
            (CompanionFlow::MidToolPressure, 0, ResponsesAttemptKind::Generation) => Ok(
                ResponsesServiceResponse::new(custom_tool_generation_output(
                    "resp-tool-pressure",
                    "call-tool-pressure",
                    "const result = await tools.exec_command({cmd: \"printf x >> companion-tool-marker\", login: false}); text(result.output);",
                    120,
                )),
            ),
            (CompanionFlow::MidToolPressure, 1, ResponsesAttemptKind::Generation) => {
                assert!(contains_text(&input, COMPANION_INSTRUCTION));
                assert!(contains_text(&input, "call-tool-pressure"));
                assert!(contains_text(&input, "custom_tool_call_output"));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-tool-pressure-summary",
                    "CUSTOM_TOOL_PRESSURE_SUMMARY",
                    30,
                )))
            }
            (CompanionFlow::MidToolPressure, 2, ResponsesAttemptKind::Generation) => {
                assert!(previous_response_id.is_none());
                assert!(contains_text(&input, "<compacted-summary>"));
                assert!(contains_text(&input, "CUSTOM_TOOL_PRESSURE_SUMMARY"));
                assert!(contains_text(&input, "custom_tool_call_output"));
                assert!(!contains_text(&input, COMPANION_INSTRUCTION));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-tool-pressure-after",
                    "continued after mid-tool pressure compaction",
                    30,
                )))
            }
            (CompanionFlow::ContextOverflow, 0, ResponsesAttemptKind::Generation) => {
                Err(ResponseError::from(ResponsesError::ContextWindowExceeded {
                    event: "fixture context overflow".to_owned(),
                }))
            }
            (CompanionFlow::ContextOverflow, 1, ResponsesAttemptKind::Generation) => {
                assert!(contains_text(&input, COMPANION_INSTRUCTION));
                assert!(contains_text(&input, "before overflow"));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-overflow-summary",
                    "CUSTOM_OVERFLOW_SUMMARY",
                    30,
                )))
            }
            (CompanionFlow::ContextOverflow, 2, ResponsesAttemptKind::Generation) => {
                assert!(previous_response_id.is_none());
                assert!(contains_text(&input, "<compacted-summary>"));
                assert!(contains_text(&input, "CUSTOM_OVERFLOW_SUMMARY"));
                assert!(contains_text(&input, "after overflow"));
                assert!(!contains_text(&input, COMPANION_INSTRUCTION));
                Ok(ResponsesServiceResponse::new(generation_output(
                    "resp-overflow-after",
                    "continued after context overflow compaction",
                    30,
                )))
            }
            (_, _, ResponsesAttemptKind::Compaction) => {
                panic!("Companion flow must not invoke provider-default compaction")
            }
            (_, _, _) => panic!("unexpected Companion lifecycle attempt {call}: {kind}"),
        };
        ready(result)
    }
}

fn contains_text(input: &[Value], expected: &str) -> bool {
    input.iter().any(|item| item.to_string().contains(expected))
}

fn generation_output(response_id: &str, message: &str, total_tokens: u64) -> ResponsesOutput {
    ResponsesOutput::Generation(GenerationOutput {
        id: response_id.to_owned(),
        status: "completed".to_owned(),
        end_turn: Some(true),
        final_message: Some(message.to_owned()),
        output_items: vec![ResponseItem::message(
            MessageRole::Assistant,
            [ContentItem::output_text(message)],
        )],
        code_calls: Vec::new(),
        usage: Some(Usage {
            total_tokens,
            ..Usage::default()
        }),
        time_to_first_event_ns: 0,
        time_to_first_output_ns: None,
        pipeline_stats: ResponsePipelineStats::default(),
    })
}

fn custom_tool_generation_output(
    response_id: &str,
    call_id: &str,
    code: &str,
    total_tokens: u64,
) -> ResponsesOutput {
    let item = serde_json::from_value(serde_json::json!({
        "type": "custom_tool_call",
        "call_id": call_id,
        "name": "exec",
        "input": code,
    }))
    .expect("custom tool call item decodes");
    ResponsesOutput::Generation(GenerationOutput {
        id: response_id.to_owned(),
        status: "completed".to_owned(),
        end_turn: Some(false),
        final_message: None,
        output_items: vec![item],
        code_calls: vec![CodeCall {
            call_id: call_id.to_owned(),
            name: "exec".to_owned(),
            namespace: None,
            input: code.to_owned(),
            kind: CodeCallKind::Custom,
        }],
        usage: Some(Usage {
            total_tokens,
            ..Usage::default()
        }),
        time_to_first_event_ns: 0,
        time_to_first_output_ns: None,
        pipeline_stats: ResponsePipelineStats::default(),
    })
}

#[tokio::test]
async fn automatic_companion_pressure_uses_a_tool_free_custom_summary_generation() -> Result<()> {
    let workspace = temporary_workspace("companion-automatic-pressure")?;
    let observations = Arc::new(Mutex::new(AttemptObservations::default()));
    let calls = Arc::new(AtomicU32::new(0));
    let service_observations = Arc::clone(&observations);
    let service_calls = Arc::clone(&calls);
    let openai = OpenAi::builder("test-key")
        .context_window_tokens(100)
        .websocket_warmup(false)
        .service(move || CompanionService {
            calls: Arc::clone(&service_calls),
            observations: Arc::clone(&service_observations),
            flow: CompanionFlow::AutomaticPressure,
        })
        .build()?;
    let (agent, events) = Nanocodex::builder(openai)
        .instructions("Companion persona marker")
        .companion_compaction_instruction(COMPANION_INSTRUCTION)
        .thinking(Thinking::Low)
        .workspace(&workspace)
        .session_id(test_session_id())
        .tools(Tools::builder().without_defaults().build()?)
        .build()?;

    assert_eq!(
        agent
            .prompt("pressure baseline")
            .await?
            .result()
            .await?
            .final_message(),
        "pressure baseline"
    );
    assert_eq!(
        agent
            .prompt("after pressure")
            .await?
            .result()
            .await?
            .final_message(),
        "continued after automatic pressure compaction"
    );

    let observations = observations.lock().unwrap();
    assert_eq!(
        observations.kinds,
        ["generation", "generation", "generation"]
    );
    assert!(
        observations
            .previous_response_ids
            .iter()
            .all(Option::is_none)
    );
    drop(observations);
    agent.shutdown().await?;
    drop((agent, events));
    std::fs::remove_dir_all(workspace)?;
    Ok(())
}

#[tokio::test]
async fn context_overflow_routes_the_next_prompt_through_custom_compaction() -> Result<()> {
    let workspace = temporary_workspace("companion-context-overflow")?;
    let observations = Arc::new(Mutex::new(AttemptObservations::default()));
    let calls = Arc::new(AtomicU32::new(0));
    let service_observations = Arc::clone(&observations);
    let service_calls = Arc::clone(&calls);
    let openai = OpenAi::builder("test-key")
        .websocket_warmup(false)
        .service(move || CompanionService {
            calls: Arc::clone(&service_calls),
            observations: Arc::clone(&service_observations),
            flow: CompanionFlow::ContextOverflow,
        })
        .build()?;
    let (agent, events) = Nanocodex::builder(openai)
        .instructions("Companion persona marker")
        .companion_compaction_instruction(COMPANION_INSTRUCTION)
        .thinking(Thinking::Low)
        .workspace(&workspace)
        .session_id(test_session_id())
        .tools(Tools::builder().without_defaults().build()?)
        .build()?;

    let overflow = agent
        .prompt("before overflow")
        .await?
        .result()
        .await
        .expect_err("the fixture must reject the first request for context size");
    assert!(
        overflow
            .responses_error()
            .is_some_and(ResponsesError::is_context_window_exceeded)
    );
    assert_eq!(
        agent
            .prompt("after overflow")
            .await?
            .result()
            .await?
            .final_message(),
        "continued after context overflow compaction"
    );

    let observations = observations.lock().unwrap();
    assert_eq!(
        observations.kinds,
        ["generation", "generation", "generation"]
    );
    assert!(
        observations
            .previous_response_ids
            .iter()
            .all(Option::is_none)
    );
    drop(observations);
    agent.shutdown().await?;
    drop((agent, events));
    std::fs::remove_dir_all(workspace)?;
    Ok(())
}

#[tokio::test]
async fn mid_tool_pressure_compacts_after_the_tool_without_rerunning_it() -> Result<()> {
    let workspace = temporary_workspace("companion-mid-tool-pressure")?;
    let observations = Arc::new(Mutex::new(AttemptObservations::default()));
    let calls = Arc::new(AtomicU32::new(0));
    let service_observations = Arc::clone(&observations);
    let service_calls = Arc::clone(&calls);
    let openai = OpenAi::builder("test-key")
        .context_window_tokens(100)
        .websocket_warmup(false)
        .service(move || CompanionService {
            calls: Arc::clone(&service_calls),
            observations: Arc::clone(&service_observations),
            flow: CompanionFlow::MidToolPressure,
        })
        .build()?;
    let (agent, events) = Nanocodex::builder(openai)
        .instructions("Companion persona marker")
        .companion_compaction_instruction(COMPANION_INSTRUCTION)
        .thinking(Thinking::Low)
        .workspace(&workspace)
        .session_id(test_session_id())
        .tools(Tools::builder().build()?)
        .build()?;

    assert_eq!(
        agent
            .prompt("run one tool during pressure")
            .await?
            .result()
            .await?
            .final_message(),
        "continued after mid-tool pressure compaction"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("companion-tool-marker"))?.len(),
        1,
        "the completed tool must not execute again after compaction"
    );
    let observations = observations.lock().unwrap();
    assert_eq!(
        observations.kinds,
        ["generation", "generation", "generation"]
    );
    assert!(
        observations
            .previous_response_ids
            .iter()
            .all(Option::is_none)
    );
    drop(observations);
    agent.shutdown().await?;
    drop((agent, events));
    std::fs::remove_dir_all(workspace)?;
    Ok(())
}
