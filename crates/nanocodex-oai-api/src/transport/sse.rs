use std::{collections::VecDeque, mem};

use crate::ResponsesError;

/// Bounds the decoder's owned unfinished line, event data, and ready-event
/// queue. The host reader may provide larger chunks, but the decoder never
/// retains an unfinished SSE record beyond this budget.
pub(crate) const MAX_SSE_BUFFER_BYTES: usize = 16 * 1024 * 1024;

/// Incremental parser for the data fields of a server-sent event stream.
///
/// The parser retains only bytes that have not yet completed an event. Hosts
/// feed it response-reader chunks; provider event decoding remains in the
/// shared Responses stream.
#[derive(Default)]
pub(crate) struct SseDecoder {
    line: Vec<u8>,
    data: String,
    has_data: bool,
    events: VecDeque<String>,
    buffered_bytes: usize,
}

impl SseDecoder {
    pub(crate) fn push(&mut self, chunk: &[u8]) -> Result<(), ResponsesError> {
        for byte in chunk {
            if *byte == b'\n' {
                self.process_line()?;
            } else {
                self.buffered_bytes = self
                    .buffered_bytes
                    .checked_add(1)
                    .ok_or_else(Self::buffer_exceeded)?;
                if self.buffered_bytes > MAX_SSE_BUFFER_BYTES {
                    return Err(Self::buffer_exceeded());
                }
                self.line.push(*byte);
            }
        }
        Ok(())
    }

    pub(crate) fn finish(&mut self) -> Result<(), ResponsesError> {
        if !self.line.is_empty() {
            self.process_line()?;
        }
        self.process_line()
    }

    pub(crate) fn next(&mut self) -> Result<Option<String>, ResponsesError> {
        let Some(event) = self.events.pop_front() else {
            return Ok(None);
        };
        self.buffered_bytes = self
            .buffered_bytes
            .saturating_sub(event.len().saturating_add(1));
        Ok(Some(event))
    }

    fn process_line(&mut self) -> Result<(), ResponsesError> {
        let mut line = mem::take(&mut self.line);
        self.buffered_bytes = self.buffered_bytes.saturating_sub(line.len());
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        let line = std::str::from_utf8(&line).map_err(|error| ResponsesError::InvalidSseUtf8 {
            detail: error.to_string(),
        })?;
        if line.is_empty() {
            if !self.has_data {
                return Ok(());
            }
            let event = mem::take(&mut self.data);
            self.has_data = false;
            if event == "[DONE]" {
                self.buffered_bytes = self
                    .buffered_bytes
                    .saturating_sub(event.len().saturating_add(1));
            } else {
                self.events.push_back(event);
            }
            return Ok(());
        }
        let Some(data) = line.strip_prefix("data:") else {
            return Ok(());
        };
        let data = data.strip_prefix(' ').unwrap_or(data);
        let additional = data.len() + 1;
        let next_size = self
            .buffered_bytes
            .checked_add(additional)
            .ok_or_else(Self::buffer_exceeded)?;
        if next_size > MAX_SSE_BUFFER_BYTES {
            return Err(Self::buffer_exceeded());
        }
        if self.has_data {
            self.data.push('\n');
        }
        self.data.push_str(data);
        self.has_data = true;
        self.buffered_bytes = next_size;
        Ok(())
    }

    fn buffer_exceeded() -> ResponsesError {
        ResponsesError::SseBufferExceeded {
            limit: MAX_SSE_BUFFER_BYTES,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_SSE_BUFFER_BYTES, SseDecoder};

    #[test]
    fn decodes_fragmented_and_multiline_sse_events() {
        let mut decoder = SseDecoder::default();
        decoder
            .push(b": keepalive\n\ndata: {\"type\":\"response.")
            .unwrap();
        assert_eq!(decoder.next().unwrap(), None);
        decoder
            .push(b"created\"}\r\n\r\ndata: first\ndata: second\n\n")
            .unwrap();
        assert_eq!(
            decoder.next().unwrap().as_deref(),
            Some("{\"type\":\"response.created\"}")
        );
        assert_eq!(decoder.next().unwrap().as_deref(), Some("first\nsecond"));
        assert_eq!(decoder.next().unwrap(), None);
    }

    #[test]
    fn skips_done_and_flushes_an_unterminated_final_event() {
        let mut decoder = SseDecoder::default();
        decoder.push(b"data: [DONE]\n\ndata: final").unwrap();
        decoder.finish().unwrap();
        assert_eq!(decoder.next().unwrap().as_deref(), Some("final"));
        assert_eq!(decoder.next().unwrap(), None);
    }

    #[test]
    fn decodes_many_events_from_one_chunk_without_repacking_each_line() {
        let mut body = String::new();
        for index in 0..4_096 {
            body.push_str("data: event-");
            body.push_str(&index.to_string());
            body.push_str("\n\n");
        }

        let mut decoder = SseDecoder::default();
        decoder.push(body.as_bytes()).unwrap();
        for index in 0..4_096 {
            assert_eq!(
                decoder.next().unwrap().as_deref(),
                Some(format!("event-{index}").as_str())
            );
        }
        assert_eq!(decoder.next().unwrap(), None);
    }

    #[test]
    fn rejects_an_unfinished_line_that_exceeds_the_record_budget() {
        let mut decoder = SseDecoder::default();
        let line = vec![b'x'; MAX_SSE_BUFFER_BYTES + 1];
        assert!(matches!(
            decoder.push(&line),
            Err(crate::ResponsesError::SseBufferExceeded { .. })
        ));
    }

    #[test]
    fn rejects_many_data_lines_without_an_event_delimiter() {
        let mut decoder = SseDecoder::default();
        let mut lines = Vec::new();
        let line = format!("data: {}\n", "x".repeat(1024));
        while lines.len() <= MAX_SSE_BUFFER_BYTES + 128 * 1024 {
            lines.extend_from_slice(line.as_bytes());
        }
        assert!(matches!(
            decoder.push(&lines),
            Err(crate::ResponsesError::SseBufferExceeded { .. })
        ));
    }
}
