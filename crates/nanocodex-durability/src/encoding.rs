//! Bounded-memory encoding of opaque total-state checkpoints.

use std::{
    collections::HashMap,
    io::{self, BufWriter, Read, Write},
};

use base64::{Engine, engine::general_purpose::STANDARD, write::EncoderWriter};
use flate2::{Compression, bufread::GzDecoder, write::GzEncoder};
use serde::{Serialize, de::DeserializeOwned};

const INLINE_BYTES: usize = 256 * 1024;
const CHUNK_MIN_BYTES: usize = 8 * 1024;
const CHUNK_MAX_BYTES: usize = 64 * 1024;
const CHUNK_MASK: u64 = 0x7fff;
const ROLLING_WINDOW_BYTES: usize = 64;
const ROLLING_BASE: u64 = 1_099_511_628_211;
const GZIP_PREFIX: &str = "nanocodex-durable-state-gzip-v1:";
const DEDUP_PREFIX: &str = "nanocodex-durable-state-dedup-v1:";
const DEDUP_MAGIC: [u8; 4] = *b"NCD1";
const TOKEN_LITERAL: u8 = 0;
const TOKEN_REFERENCE: u8 = 1;
const MAX_DEDUP_JSON_BYTES: u64 = 256 * 1024 * 1024;

type CompressedWriter =
    BufWriter<GzEncoder<EncoderWriter<'static, base64::engine::GeneralPurpose, Vec<u8>>>>;

#[derive(Default)]
struct CheckpointWriter {
    inline: Vec<u8>,
    compressed: Option<CompressedWriter>,
}

impl Write for CheckpointWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.compressed.is_none() && self.inline.len().saturating_add(bytes.len()) > INLINE_BYTES
        {
            let encoded = EncoderWriter::new(GZIP_PREFIX.as_bytes().to_vec(), &STANDARD);
            let mut compressed =
                BufWriter::with_capacity(64 * 1024, GzEncoder::new(encoded, Compression::fast()));
            compressed.write_all(&self.inline)?;
            self.inline = Vec::new();
            self.compressed = Some(compressed);
        }
        if let Some(compressed) = &mut self.compressed {
            compressed.write_all(bytes)?;
        } else {
            self.inline.extend_from_slice(bytes);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        match &mut self.compressed {
            Some(compressed) => compressed.flush(),
            None => Ok(()),
        }
    }
}

impl CheckpointWriter {
    fn finish(self) -> io::Result<Vec<u8>> {
        match self.compressed {
            Some(compressed) => compressed
                .into_inner()
                .map_err(|error| error.into_error())
                .and_then(GzEncoder::finish)
                .and_then(|mut encoded| encoded.finish()),
            None => Ok(self.inline),
        }
    }
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct ChunkKey {
    hash: u64,
    len: u32,
}

impl ChunkKey {
    fn from_bytes(bytes: &[u8]) -> io::Result<Self> {
        let len = u32::try_from(bytes.len()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "durable chunk exceeds u32 length",
            )
        })?;
        let mut hash = 14_695_981_039_346_656_037u64;
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(1_099_511_628_211);
        }
        Ok(Self { hash, len })
    }
}

const fn wrapping_pow(mut base: u64, mut exponent: usize) -> u64 {
    let mut result = 1u64;
    while exponent > 0 {
        if exponent & 1 == 1 {
            result = result.wrapping_mul(base);
        }
        base = base.wrapping_mul(base);
        exponent >>= 1;
    }
    result
}

const ROLLING_POWER: u64 = wrapping_pow(ROLLING_BASE, ROLLING_WINDOW_BYTES - 1);

struct Chunker {
    current: Vec<u8>,
    hash: u64,
    window: [u8; ROLLING_WINDOW_BYTES],
    window_len: usize,
    window_start: usize,
}

impl Default for Chunker {
    fn default() -> Self {
        Self {
            current: Vec::new(),
            hash: 0,
            window: [0; ROLLING_WINDOW_BYTES],
            window_len: 0,
            window_start: 0,
        }
    }
}

impl Chunker {
    fn push<F>(&mut self, bytes: &[u8], mut emit: F) -> io::Result<()>
    where
        F: FnMut(&[u8]) -> io::Result<()>,
    {
        for byte in bytes {
            self.current.push(*byte);
            if self.window_len < ROLLING_WINDOW_BYTES {
                self.window[self.window_len] = *byte;
                self.window_len += 1;
                self.hash = self
                    .hash
                    .wrapping_mul(ROLLING_BASE)
                    .wrapping_add(u64::from(*byte));
            } else {
                let outgoing = self.window[self.window_start];
                self.window[self.window_start] = *byte;
                self.window_start = (self.window_start + 1) % ROLLING_WINDOW_BYTES;
                self.hash = self
                    .hash
                    .wrapping_sub(u64::from(outgoing).wrapping_mul(ROLLING_POWER))
                    .wrapping_mul(ROLLING_BASE)
                    .wrapping_add(u64::from(*byte));
            }
            let length = self.current.len();
            if length >= CHUNK_MIN_BYTES
                && self.window_len == ROLLING_WINDOW_BYTES
                && ((self.hash & CHUNK_MASK) == 0 || length >= CHUNK_MAX_BYTES)
            {
                emit(&self.current)?;
                self.current.clear();
            }
        }
        Ok(())
    }

    fn finish<F>(&mut self, mut emit: F) -> io::Result<()>
    where
        F: FnMut(&[u8]) -> io::Result<()>,
    {
        if !self.current.is_empty() {
            emit(&self.current)?;
            self.current.clear();
        }
        Ok(())
    }
}

#[derive(Default)]
struct ChunkCountWriter {
    chunker: Chunker,
    counts: HashMap<ChunkKey, u32>,
    preview: Vec<u8>,
    total_len: u64,
}

impl Write for ChunkCountWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.total_len = self
            .total_len
            .checked_add(u64::try_from(bytes.len()).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable payload exceeds u64 length",
                )
            })?)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable payload length overflow",
                )
            })?;
        if self.preview.len() < INLINE_BYTES {
            let remaining = INLINE_BYTES - self.preview.len();
            self.preview
                .extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        }
        let chunker = &mut self.chunker;
        let counts = &mut self.counts;
        chunker.push(bytes, |chunk| {
            let key = ChunkKey::from_bytes(chunk)?;
            counts
                .entry(key)
                .and_modify(|count| *count = count.saturating_add(1))
                .or_insert(1);
            Ok(())
        })?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct ChunkCounts {
    counts: HashMap<ChunkKey, u32>,
    preview: Vec<u8>,
    total_len: u64,
}

impl ChunkCountWriter {
    fn finish(mut self) -> io::Result<ChunkCounts> {
        let chunker = &mut self.chunker;
        let counts = &mut self.counts;
        chunker.finish(|chunk| {
            let key = ChunkKey::from_bytes(chunk)?;
            counts
                .entry(key)
                .and_modify(|count| *count = count.saturating_add(1))
                .or_insert(1);
            Ok(())
        })?;
        Ok(ChunkCounts {
            counts: self.counts,
            preview: self.preview,
            total_len: self.total_len,
        })
    }
}

struct DictionaryEntry {
    bytes: Vec<u8>,
}

struct DeduplicatingWriter {
    chunker: Chunker,
    counts: HashMap<ChunkKey, u32>,
    dictionary: Vec<DictionaryEntry>,
    dictionary_indexes: HashMap<ChunkKey, Vec<u32>>,
    tokens: Vec<u8>,
    token_count: u32,
    output_len: u64,
    expected_output_len: u64,
}

impl DeduplicatingWriter {
    fn new(counts: HashMap<ChunkKey, u32>, expected_output_len: u64) -> Self {
        Self {
            chunker: Chunker::default(),
            counts,
            dictionary: Vec::new(),
            dictionary_indexes: HashMap::new(),
            tokens: Vec::new(),
            token_count: 0,
            output_len: 0,
            expected_output_len,
        }
    }

    fn finish(mut self) -> io::Result<Vec<u8>> {
        let chunker = &mut self.chunker;
        let counts = &self.counts;
        let dictionary = &mut self.dictionary;
        let dictionary_indexes = &mut self.dictionary_indexes;
        let tokens = &mut self.tokens;
        let token_count = &mut self.token_count;
        let output_len = &mut self.output_len;
        chunker.finish(|chunk| {
            record_deduplicated_chunk(
                counts,
                dictionary,
                dictionary_indexes,
                tokens,
                token_count,
                output_len,
                chunk,
            )
        })?;
        if self.output_len != self.expected_output_len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable payload serialization changed between encoding passes",
            ));
        }

        let dictionary_count = u32::try_from(self.dictionary.len()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "durable dictionary has too many entries",
            )
        })?;
        let dictionary_bytes = self.dictionary.iter().try_fold(0usize, |total, entry| {
            total
                .checked_add(4)
                .and_then(|total| total.checked_add(entry.bytes.len()))
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "durable dictionary is too large",
                    )
                })
        })?;
        let capacity = DEDUP_MAGIC
            .len()
            .checked_add(4 + 4 + 8)
            .and_then(|size| size.checked_add(dictionary_bytes))
            .and_then(|size| size.checked_add(self.tokens.len()))
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "durable encoding is too large")
            })?;
        let mut body = Vec::with_capacity(capacity);
        body.extend_from_slice(&DEDUP_MAGIC);
        body.extend_from_slice(&dictionary_count.to_le_bytes());
        body.extend_from_slice(&self.token_count.to_le_bytes());
        body.extend_from_slice(&self.output_len.to_le_bytes());
        for entry in self.dictionary {
            let length = u32::try_from(entry.bytes.len()).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable dictionary entry is too large",
                )
            })?;
            body.extend_from_slice(&length.to_le_bytes());
            body.extend_from_slice(&entry.bytes);
        }
        body.extend_from_slice(&self.tokens);
        Ok(body)
    }
}

impl Write for DeduplicatingWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let chunker = &mut self.chunker;
        let counts = &self.counts;
        let dictionary = &mut self.dictionary;
        let dictionary_indexes = &mut self.dictionary_indexes;
        let tokens = &mut self.tokens;
        let token_count = &mut self.token_count;
        let output_len = &mut self.output_len;
        chunker.push(bytes, |chunk| {
            record_deduplicated_chunk(
                counts,
                dictionary,
                dictionary_indexes,
                tokens,
                token_count,
                output_len,
                chunk,
            )
        })?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn record_deduplicated_chunk(
    counts: &HashMap<ChunkKey, u32>,
    dictionary: &mut Vec<DictionaryEntry>,
    dictionary_indexes: &mut HashMap<ChunkKey, Vec<u32>>,
    tokens: &mut Vec<u8>,
    token_count: &mut u32,
    output_len: &mut u64,
    chunk: &[u8],
) -> io::Result<()> {
    let key = ChunkKey::from_bytes(chunk)?;
    *output_len = output_len
        .checked_add(u64::try_from(chunk.len()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "durable payload exceeds u64 length",
            )
        })?)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "durable payload length overflow",
            )
        })?;

    let is_repeated = counts.get(&key).is_some_and(|count| *count > 1);
    if !is_repeated {
        append_token(tokens, token_count, TOKEN_LITERAL, chunk)
    } else {
        let existing = dictionary_indexes.get(&key).and_then(|indexes| {
            indexes.iter().copied().find(|index| {
                dictionary
                    .get(usize::try_from(*index).unwrap_or(usize::MAX))
                    .is_some_and(|entry| entry.bytes == chunk)
            })
        });
        let index = match existing {
            Some(index) => index,
            None => {
                let index = u32::try_from(dictionary.len()).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "durable dictionary has too many entries",
                    )
                })?;
                dictionary.push(DictionaryEntry {
                    bytes: chunk.to_vec(),
                });
                dictionary_indexes.entry(key).or_default().push(index);
                index
            }
        };
        append_token(tokens, token_count, TOKEN_REFERENCE, &index.to_le_bytes())
    }
}

fn append_token(
    tokens: &mut Vec<u8>,
    token_count: &mut u32,
    kind: u8,
    value: &[u8],
) -> io::Result<()> {
    *token_count = token_count.checked_add(1).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "durable encoding has too many tokens",
        )
    })?;
    tokens.push(kind);
    match kind {
        TOKEN_LITERAL => {
            let length = u32::try_from(value.len()).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable literal token is too large",
                )
            })?;
            tokens.extend_from_slice(&length.to_le_bytes());
            tokens.extend_from_slice(value);
        }
        TOKEN_REFERENCE => {
            if value.len() != 4 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable reference token has an invalid index",
                ));
            }
            tokens.extend_from_slice(value);
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable encoding emitted an unknown token",
            ));
        }
    }
    Ok(())
}

pub(crate) fn encode(value: &impl Serialize) -> serde_json::Result<String> {
    let mut measured = ChunkCountWriter::default();
    serde_json::to_writer(&mut measured, value)?;
    let measured = measured.finish().map_err(serde_json::Error::io)?;
    if measured.total_len <= INLINE_BYTES as u64 {
        return string_from_bytes(measured.preview);
    }

    // The new envelope has an explicit recovery bound. Older gzip payloads
    // remain readable without changing their existing format contract, but a
    // newly written deduplicated payload must always be recoverable within
    // this bound.
    if measured.total_len > MAX_DEDUP_JSON_BYTES {
        return encode_gzip(value);
    }

    if !measured.counts.values().any(|count| *count > 1) {
        return encode_gzip(value);
    }

    let mut deduplicated = DeduplicatingWriter::new(measured.counts, measured.total_len);
    serde_json::to_writer(&mut deduplicated, value)?;
    let body = deduplicated.finish().map_err(serde_json::Error::io)?;
    gzip_base64(DEDUP_PREFIX, &body)
}

fn encode_gzip(value: &impl Serialize) -> serde_json::Result<String> {
    let mut writer = CheckpointWriter::default();
    serde_json::to_writer(&mut writer, value)?;
    let bytes = writer.finish().map_err(serde_json::Error::io)?;
    string_from_bytes(bytes)
}

fn gzip_base64(prefix: &str, body: &[u8]) -> serde_json::Result<String> {
    let encoded = EncoderWriter::new(prefix.as_bytes().to_vec(), &STANDARD);
    let mut compressed =
        BufWriter::with_capacity(64 * 1024, GzEncoder::new(encoded, Compression::fast()));
    compressed.write_all(body).map_err(serde_json::Error::io)?;
    let mut encoded = compressed
        .into_inner()
        .map_err(|error| serde_json::Error::io(error.into_error()))?
        .finish()
        .map_err(serde_json::Error::io)?;
    string_from_bytes(encoded.finish().map_err(serde_json::Error::io)?)
}

fn string_from_bytes(bytes: Vec<u8>) -> serde_json::Result<String> {
    String::from_utf8(bytes)
        .map_err(|error| serde_json::Error::io(io::Error::new(io::ErrorKind::InvalidData, error)))
}

pub(crate) fn decode<T: DeserializeOwned>(payload: &str) -> serde_json::Result<T> {
    if let Some(encoded) = payload.strip_prefix(DEDUP_PREFIX) {
        let compressed = decode_base64(encoded)?;
        let mut reader = DeduplicatedReader::new(&compressed).map_err(serde_json::Error::io)?;
        let value = serde_json::from_reader(&mut reader)?;
        reader.finish().map_err(serde_json::Error::io)?;
        return Ok(value);
    }
    let Some(encoded) = payload.strip_prefix(GZIP_PREFIX) else {
        return serde_json::from_str(payload);
    };
    let compressed = decode_base64(encoded)?;
    // Decode directly into the reduced state. Never allocate a second full
    // uncompressed JSON document while recovering a large conversation.
    let mut decoder = GzDecoder::new(compressed.as_slice());
    let value = serde_json::from_reader(&mut decoder)?;
    if !decoder.get_ref().is_empty() {
        return Err(serde_json::Error::io(io::Error::new(
            io::ErrorKind::InvalidData,
            "trailing bytes in compressed durable state",
        )));
    }
    Ok(value)
}

fn decode_base64(encoded: &str) -> serde_json::Result<Vec<u8>> {
    STANDARD
        .decode(encoded)
        .map_err(|error| serde_json::Error::io(io::Error::new(io::ErrorKind::InvalidData, error)))
}

struct DeduplicatedReader<'a> {
    decoder: GzDecoder<&'a [u8]>,
    dictionary: Vec<Vec<u8>>,
    tokens_remaining: u32,
    remaining: u64,
    current: Vec<u8>,
    current_offset: usize,
    finished: bool,
}

impl<'a> DeduplicatedReader<'a> {
    fn new(compressed: &'a [u8]) -> io::Result<Self> {
        let mut decoder = GzDecoder::new(compressed);
        let mut magic = [0u8; DEDUP_MAGIC.len()];
        decoder.read_exact(&mut magic)?;
        if magic != DEDUP_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid durable deduplication header",
            ));
        }
        let dictionary_count = read_u32(&mut decoder)?;
        let token_count = read_u32(&mut decoder)?;
        let output_len = read_u64(&mut decoder)?;
        if output_len == 0 || output_len > MAX_DEDUP_JSON_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable deduplicated output exceeds its bound",
            ));
        }
        let max_chunks = output_len / CHUNK_MIN_BYTES as u64 + 1;
        if token_count == 0
            || u64::from(token_count) > max_chunks
            || u64::from(dictionary_count) > max_chunks
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable deduplicated counts are invalid",
            ));
        }

        let dictionary_capacity = usize::try_from(dictionary_count).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "durable dictionary count overflows usize",
            )
        })?;
        let mut dictionary = Vec::with_capacity(dictionary_capacity);
        let mut dictionary_bytes = 0u64;
        for _ in 0..dictionary_count {
            let length = read_u32(&mut decoder)?;
            let length_usize = usize::try_from(length).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable dictionary length overflows usize",
                )
            })?;
            if length_usize == 0 || length_usize > CHUNK_MAX_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable dictionary entry has an invalid length",
                ));
            }
            dictionary_bytes =
                dictionary_bytes
                    .checked_add(u64::from(length))
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            "durable dictionary length overflow",
                        )
                    })?;
            if dictionary_bytes > output_len || dictionary_bytes > MAX_DEDUP_JSON_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable dictionary exceeds its bound",
                ));
            }
            let mut entry = vec![0u8; length_usize];
            decoder.read_exact(&mut entry)?;
            dictionary.push(entry);
        }

        Ok(Self {
            decoder,
            dictionary,
            tokens_remaining: token_count,
            remaining: output_len,
            current: Vec::new(),
            current_offset: 0,
            finished: false,
        })
    }

    fn load_token(&mut self) -> io::Result<()> {
        let mut kind = [0u8; 1];
        self.decoder.read_exact(&mut kind)?;
        self.tokens_remaining -= 1;
        match kind[0] {
            TOKEN_LITERAL => {
                let length = read_u32(&mut self.decoder)?;
                let length_usize = usize::try_from(length).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "durable literal length overflows usize",
                    )
                })?;
                if length_usize == 0 || length_usize > CHUNK_MAX_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "durable literal token has an invalid length",
                    ));
                }
                self.reserve_output(u64::from(length))?;
                self.current.resize(length_usize, 0);
                self.decoder.read_exact(&mut self.current)?;
            }
            TOKEN_REFERENCE => {
                let index = read_u32(&mut self.decoder)?;
                let entry = self
                    .dictionary
                    .get(usize::try_from(index).map_err(|_| {
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            "durable reference index overflows usize",
                        )
                    })?)
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            "durable reference index is out of range",
                        )
                    })?
                    .clone();
                self.reserve_output(u64::try_from(entry.len()).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "durable reference length overflows u64",
                    )
                })?)?;
                self.current.clear();
                self.current.extend_from_slice(&entry);
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "durable token kind is invalid",
                ));
            }
        }
        self.current_offset = 0;
        Ok(())
    }

    fn reserve_output(&mut self, length: u64) -> io::Result<()> {
        if length == 0 || length > self.remaining {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable token exceeds declared output length",
            ));
        }
        self.remaining -= length;
        Ok(())
    }

    fn finish_stream(&mut self) -> io::Result<()> {
        if self.finished {
            return Ok(());
        }
        if self.tokens_remaining != 0 || self.remaining != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "durable deduplicated stream ended before its declared output",
            ));
        }
        let mut trailing = [0u8; 1];
        if self.decoder.read(&mut trailing)? != 0 || !self.decoder.get_ref().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "trailing bytes in deduplicated durable state",
            ));
        }
        self.finished = true;
        Ok(())
    }

    fn finish(&mut self) -> io::Result<()> {
        let mut buffer = [0u8; 8 * 1024];
        while self.read(&mut buffer)? != 0 {}
        Ok(())
    }
}

impl Read for DeduplicatedReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() {
            return Ok(0);
        }
        loop {
            if self.current_offset < self.current.len() {
                let available = &self.current[self.current_offset..];
                let amount = available.len().min(output.len());
                output[..amount].copy_from_slice(&available[..amount]);
                self.current_offset += amount;
                return Ok(amount);
            }
            self.current.clear();
            self.current_offset = 0;
            if self.tokens_remaining == 0 {
                self.finish_stream()?;
                return Ok(0);
            }
            self.load_token()?;
        }
    }
}

fn read_u32(reader: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0u8; 4];
    reader.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_u64(reader: &mut impl Read) -> io::Result<u64> {
    let mut bytes = [0u8; 8];
    reader.read_exact(&mut bytes)?;
    Ok(u64::from_le_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn incompressible_base64(size: usize) -> String {
        let mut bytes = Vec::with_capacity(size);
        let mut state = 0x6d2b_79f5u32;
        for _ in 0..size {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            bytes.push((state >> 24) as u8);
        }
        STANDARD.encode(bytes)
    }

    fn old_gzip_payload<T: Serialize>(value: &T) -> String {
        let json = serde_json::to_vec(value).unwrap();
        gzip_base64(GZIP_PREFIX, &json).unwrap()
    }

    fn body_from_deduplicated(payload: &str) -> Vec<u8> {
        let compressed = STANDARD
            .decode(payload.strip_prefix(DEDUP_PREFIX).unwrap())
            .unwrap();
        let mut decoder = GzDecoder::new(compressed.as_slice());
        let mut body = Vec::new();
        decoder.read_to_end(&mut body).unwrap();
        assert!(decoder.get_ref().is_empty());
        body
    }

    #[test]
    fn legacy_and_large_checkpoints_round_trip_exactly() {
        let small = serde_json::json!({"input": "quotes: \" \\ unicode: 🧪"});
        assert_eq!(encode(&small).unwrap(), small.to_string());
        assert_eq!(
            decode::<serde_json::Value>(&small.to_string()).unwrap(),
            small
        );
        let large = serde_json::json!({"history": "quoted \" 🧪\n".repeat(100_000)});
        let encoded = encode(&large).unwrap();
        assert!(encoded.starts_with(DEDUP_PREFIX));
        assert!(encoded.len() < large.to_string().len() / 10);
        assert_eq!(
            encoded,
            encode(&large).unwrap(),
            "retry bytes must be deterministic"
        );
        assert_eq!(decode::<serde_json::Value>(&encoded).unwrap(), large);
    }

    #[test]
    fn repeated_nested_payloads_are_stored_once_and_round_trip_exactly() {
        let image = incompressible_base64(2 * 1024 * 1024);
        let nested = |suffix: &str| {
            serde_json::json!({
                "history": [
                    {"role": "user", "content": [{"type": "input_image", "image_url": format!("data:image/png;base64,{image}")}]},
                    {"role": "assistant", "content": [{"type": "output_text", "text": suffix}]}
                ]
            })
            .to_string()
        };
        let value = serde_json::json!({
            "nanocodex_durable_state": {
                "format": 2,
                "operations": {
                    "one": {"input": nested("one"), "status": {"completed": {"checkpoint": nested("one checkpoint"), "output": "\"one\""}}, "steps": {}, "accepted_order": 1},
                    "two": {"input": "\"two\"", "status": {"completed": {"checkpoint": nested("two checkpoint"), "output": "\"two\""}}, "steps": {}, "accepted_order": 2},
                    "three": {"input": "\"three\"", "status": {"completed": {"checkpoint": nested("three checkpoint"), "output": "\"three\""}}, "steps": {}, "accepted_order": 3},
                    "four": {"input": "\"four\"", "status": {"completed": {"checkpoint": nested("four checkpoint"), "output": "\"four\""}}, "steps": {}, "accepted_order": 4}
                },
                "latest_checkpoint": nested("four checkpoint")
            }
        });
        let raw = serde_json::to_string(&value).unwrap();
        let encoded = encode(&value).unwrap();
        assert!(encoded.starts_with(DEDUP_PREFIX));
        assert!(
            encoded.len() < raw.len() / 2,
            "deduplicated payload should materially shrink repeated image data: {} vs {}",
            encoded.len(),
            raw.len()
        );
        let compressed = decode_base64(encoded.strip_prefix(DEDUP_PREFIX).unwrap()).unwrap();
        let mut reconstructed = DeduplicatedReader::new(&compressed).unwrap();
        let mut reconstructed_json = Vec::new();
        reconstructed.read_to_end(&mut reconstructed_json).unwrap();
        reconstructed.finish().unwrap();
        assert_eq!(reconstructed_json, raw.as_bytes());
        assert_eq!(decode::<serde_json::Value>(&encoded).unwrap(), value);
        assert_eq!(
            encoded,
            encode(&value).unwrap(),
            "dedup retry bytes must be deterministic"
        );
    }

    #[test]
    fn unique_large_input_keeps_the_legacy_gzip_representation() {
        let value = serde_json::json!({"image": incompressible_base64(2 * 1024 * 1024)});
        let encoded = encode(&value).unwrap();
        assert!(encoded.starts_with(GZIP_PREFIX));
        assert_eq!(decode::<serde_json::Value>(&encoded).unwrap(), value);
    }

    #[test]
    fn previous_gzip_representation_remains_supported() {
        let value = serde_json::json!({"history": "legacy".repeat(INLINE_BYTES)});
        let encoded = old_gzip_payload(&value);
        assert!(encoded.starts_with(GZIP_PREFIX));
        assert_eq!(decode::<serde_json::Value>(&encoded).unwrap(), value);
    }

    #[test]
    fn compressed_checkpoints_reject_corruption_truncation_trailing_and_bad_references() {
        let image = incompressible_base64(2 * 1024 * 1024);
        let value = serde_json::json!({
            "one": image.clone(),
            "two": image
        });
        let encoded = encode(&value).unwrap();
        let bytes = STANDARD
            .decode(encoded.strip_prefix(DEDUP_PREFIX).unwrap())
            .unwrap();
        for length in [0, 1, bytes.len() / 2, bytes.len() - 1] {
            let truncated = format!("{DEDUP_PREFIX}{}", STANDARD.encode(&bytes[..length]));
            assert!(decode::<serde_json::Value>(&truncated).is_err());
        }
        let mut corrupted = bytes.clone();
        let checksum = corrupted.len() - 8;
        corrupted[checksum] ^= 1;
        assert!(
            decode::<serde_json::Value>(&format!("{DEDUP_PREFIX}{}", STANDARD.encode(corrupted)))
                .is_err()
        );
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(
            decode::<serde_json::Value>(&format!("{DEDUP_PREFIX}{}", STANDARD.encode(trailing)))
                .is_err()
        );

        let mut body = body_from_deduplicated(&encoded);
        let dictionary_count = u32::from_le_bytes(body[4..8].try_into().unwrap()) as usize;
        let token_count = u32::from_le_bytes(body[8..12].try_into().unwrap());
        let mut offset = 20;
        for _ in 0..dictionary_count {
            let length = u32::from_le_bytes(body[offset..offset + 4].try_into().unwrap()) as usize;
            offset += 4 + length;
        }
        let mut changed_reference = false;
        for _ in 0..token_count {
            let kind = body[offset];
            offset += 1;
            let length_or_index = offset;
            offset += 4;
            if kind == TOKEN_REFERENCE {
                body[length_or_index..length_or_index + 4].copy_from_slice(&u32::MAX.to_le_bytes());
                changed_reference = true;
                break;
            }
            offset += u32::from_le_bytes(
                body[length_or_index..length_or_index + 4]
                    .try_into()
                    .unwrap(),
            ) as usize;
        }
        assert!(
            changed_reference,
            "fixture must contain a dictionary reference"
        );
        let malformed = gzip_base64(DEDUP_PREFIX, &body).unwrap();
        assert!(decode::<serde_json::Value>(&malformed).is_err());
        assert!(decode::<serde_json::Value>(&format!("{DEDUP_PREFIX}!invalid-base64!")).is_err());
    }
}
