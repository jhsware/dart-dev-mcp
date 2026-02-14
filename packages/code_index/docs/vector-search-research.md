# Vector Search for Code-Index: Research Findings

**Date:** 2026-02-14
**Task:** Investigate embedding-based vector search for code-index using Haiku and SQLite
**Status:** Research complete — recommendation at bottom

---

## 1. Anthropic API Embedding Capabilities

### Finding: Anthropic does NOT offer an embeddings API

As confirmed by the official documentation (https://docs.anthropic.com/en/docs/build-with-claude/embeddings), Anthropic explicitly states: *"Anthropic does not offer its own embedding model."* Claude models (including Haiku) generate text responses, not dense vector representations. There is no hidden embedding endpoint.

Anthropic's recommended embedding provider is **Voyage AI**, which offers:

| Model | Dimension | Use Case |
|-------|-----------|----------|
| voyage-3.5 | 1024 (default) | General-purpose retrieval |
| voyage-code-3 | 1024 (default) | Code retrieval (most relevant) |
| voyage-3-large | 1024 (default) | Best quality general retrieval |
| voyage-3.5-lite | 1024 (default) | Optimized for latency/cost |

### Alternative Approaches Evaluated

#### A. Prompt Haiku to generate semantic tags/keywords

**Concept:** Ask Haiku to analyze code metadata and return semantic keywords that expand FTS5 search coverage. For example, for `addTask()` → "create, insert, add, new, task, CRUD".

**Pros:**
- Integrates directly with existing FTS5 infrastructure (add a `semantic_tags` column)
- No new dependencies (vector DB, embedding model)
- Keywords are human-readable and debuggable
- More stable across model versions than dense embeddings
- Works with the Anthropic API the project already has access to

**Cons:**
- Requires an API call per file during indexing (latency + cost)
- Does not work offline
- Keywords are still discrete tokens — won't capture nuanced semantic similarity
- Model version changes could alter generated keywords (though impact is limited)
- Cost: ~100-200 input tokens + ~50 output tokens per file. At Haiku pricing ($0.25/1M input, $1.25/1M output), a 100-file project costs ~$0.01

**Verdict:** Viable as a lightweight enhancement to FTS5, but adds API dependency.

#### B. External embedding APIs (Voyage AI, OpenAI, Cohere)

**Concept:** Use a dedicated embedding API to generate dense vectors for file metadata.

| Provider | Model | Cost | Dimension |
|----------|-------|------|-----------|
| Voyage AI | voyage-code-3 | ~$0.06/1M tokens | 1024 |
| OpenAI | text-embedding-3-small | $0.02/1M tokens | 1536 |
| Cohere | embed-v3 | varies | 1024 |

**Pros:**
- High-quality semantic representations
- True semantic similarity (not just keyword matching)
- voyage-code-3 is specifically optimized for code

**Cons:**
- Requires a separate API key (Voyage/OpenAI) — adds user configuration burden
- Requires a vector storage/search extension in SQLite
- Does not work offline
- Model version changes require re-indexing all embeddings
- Adds external dependency to a tool meant to be self-contained

**Verdict:** Best quality, but heaviest integration burden for a dev tool.

#### C. Local embedding models via Dart packages

**Concept:** Run a sentence-transformer model locally using ONNX Runtime.

Two packages exist on pub.dev:

1. **`flutter_embedder`** (v0.1.7) — FFI plugin wrapping HuggingFace tokenizers + ONNX Runtime via Rust. Supports MiniLM, BGE, Qwen3, Gemma, Jina V3.
   - **Problem:** This is a *Flutter* package — requires `WidgetsFlutterBinding.ensureInitialized()` and Flutter SDK. The code-index MCP server is a **pure Dart CLI application**, so this package cannot be used directly.

2. **`onnxruntime` / `onnxruntime_v2`** — Raw ONNX Runtime bindings for Dart/Flutter.
   - Could theoretically run a sentence-transformer ONNX model, but would need to implement tokenization and pooling manually in Dart.
   - Heavy dependency (ONNX Runtime native libraries ~50-100MB)

3. **`transformers`** (Dart) — Attempts to port HuggingFace Transformers to Dart.
   - Still under heavy development, inference recommended to be avoided for now.

**Pros:**
- Works offline
- No API costs
- Deterministic (same model = same embeddings)

**Cons:**
- `flutter_embedder` requires Flutter, not usable in pure Dart CLI
- Raw ONNX approach requires significant manual implementation
- Large binary size increase (~50-100MB for ONNX Runtime)
- Model files add another ~30-100MB
- Platform-specific native compilation needed
- Dart ecosystem for ML is immature

**Verdict:** Not viable for a pure Dart CLI tool in 2026. The ecosystem is Flutter-focused, not Dart CLI-focused.

---

## 2. SQLite Vector Search Extensions

### sqlite_vector (by sqlite.ai) — RECOMMENDED if pursuing vector search

**Package:** `sqlite_vector` on pub.dev (published Feb 2026)
**Integration:** Works directly with `package:sqlite3` (which code-index already uses)

```dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

sqlite3.loadSqliteVectorExtension();
final db = sqlite3.open('code_index.db');

// Create table with vector column
db.execute('CREATE TABLE embeddings (file_id TEXT PRIMARY KEY, vec BLOB)');

// Insert vector
db.execute("INSERT INTO embeddings VALUES (?, vector_as_f32(?))",
    ['file-123', '[0.1, 0.2, ...]']);

// Initialize index
db.execute("SELECT vector_init('embeddings', 'vec', 'type=FLOAT32,dimension=384')");

// KNN search
db.select('''
  SELECT e.file_id, v.distance FROM embeddings e
  JOIN vector_full_scan('embeddings', 'vec', vector_as_f32(?), 10) AS v
  ON e.file_id = v.rowid
''', ['[0.1, 0.2, ...]']);
```

**Pros:**
- Native Dart package that works with `package:sqlite3`
- Cross-platform: Android, iOS, macOS, Linux, Windows
- Multiple precision formats (Float32, Float16, Int8, etc.)
- 30MB memory usage
- Simple API — no complex indexing setup needed
- Uses `vector_full_scan` for exact KNN (good for small datasets)

**Cons:**
- Very new package (published days ago) — stability unknown
- Adds native binary dependency
- License is "unknown" on pub.dev — needs investigation
- Still need an embedding source to generate vectors

### sqlite-vec (by asg017)

The better-known option, but has **no Dart package**. Would require:
1. Compiling sqlite-vec for each target platform
2. Manually loading the extension via `sqlite3.open()` + `SELECT load_extension(...)`
3. Managing native binaries in the build/distribution process

**Verdict:** `sqlite_vector` is more practical for Dart integration, but both require an embedding source.

---

## 3. Model Version Stability

### The re-indexing problem

Any approach using ML models (LLM or embedding) faces version drift:

| Approach | Stability | Re-index needed on update? |
|----------|-----------|---------------------------|
| Haiku keyword generation | Medium — keywords are discrete, changes are incremental | Sometimes (keywords may shift) |
| Dense embeddings (any model) | Low — vector spaces change completely between versions | Always |
| Local ONNX model (pinned version) | High — deterministic if model file unchanged | Only if you update the model |

### Mitigation strategies

1. **Store model version** alongside each embedding/tag set in the DB
2. **Lazy re-indexing:** Flag stale entries, re-embed on next access
3. **Pin model version:** For local models, ship a specific ONNX file
4. **For Haiku keywords:** Store keywords alongside the model version used; only refresh when version changes

---

## 4. Trade-off Analysis

### Approach comparison matrix

| Factor | FTS5 only (current) | FTS5 + Haiku keywords | FTS5 + External embeddings | FTS5 + Local embeddings |
|--------|---------------------|----------------------|---------------------------|------------------------|
| **Complexity** | Low | Medium | High | Very High |
| **New dependencies** | None | API calls to Anthropic | API key + sqlite_vector | ONNX Runtime + sqlite_vector + model files |
| **Offline support** | Yes | No | No | Yes |
| **Cost per 100 files** | $0 | ~$0.01 | ~$0.002 | $0 |
| **Binary size impact** | None | None | +30MB (sqlite_vector) | +150MB+ (ONNX + model + sqlite_vector) |
| **Semantic quality** | Keywords only | Good (expanded keywords) | Best (dense similarity) | Good (local model quality) |
| **Platform portability** | Excellent | Excellent | Good (native ext) | Poor (native binaries) |
| **Maintenance burden** | Low | Medium | High | Very High |
| **Pure Dart CLI compatible** | Yes | Yes | Yes (with sqlite_vector) | No (Flutter-only packages) |

### Cost of FTS5 improvements vs. vector search

The current FTS5 setup already indexes: file names, descriptions, export names, export descriptions, variable names, and file paths. With the recent addition of export descriptions (schema v4) and potential OR semantics improvements, FTS5 covers the majority of search use cases.

The gap is **concept-based search** — finding "create" when the code says "add", or "authentication" when the code says "login". This is a real but narrow gap for a code-index tool where:
- Users are typically developers who know the codebase terminology
- The code-index agent can try multiple search terms
- Export descriptions (written by the indexing agent) can include synonyms naturally

---

## 5. Recommendation

### **Do NOT proceed with vector search implementation at this time.**

**Rationale:**

1. **The Dart CLI ecosystem is not ready.** The most promising local embedding package (`flutter_embedder`) requires Flutter and cannot be used in a pure Dart CLI application. There is no viable pure-Dart solution for generating embeddings locally.

2. **External APIs add unacceptable friction.** Requiring users to configure a Voyage AI or OpenAI API key for a code-index tool adds significant onboarding friction and introduces a hard dependency on internet connectivity.

3. **The cost/benefit ratio is poor.** FTS5 with good descriptions, OR semantics, and export descriptions already covers ~80-90% of search needs. Vector search adds substantial complexity (new dependencies, API management, re-indexing concerns) for marginal improvement in a tool where the AI agent can iteratively refine searches.

4. **sqlite_vector is too new.** Published days ago with an unknown license — not ready for production dependency.

### Recommended alternative: Haiku-assisted keyword expansion (future)

If semantic search becomes a clear pain point, the **lightest viable enhancement** would be:

1. During `index-file`, optionally call Haiku to generate 5-10 semantic keywords for each file
2. Store keywords in a new `semantic_tags` FTS5 column
3. No new binary dependencies — reuses existing FTS5 infrastructure
4. Can be toggled on/off based on API availability

This approach should be revisited when:
- The Dart embedding ecosystem matures (pure Dart ONNX support)
- `sqlite_vector` has a stable release with clear licensing
- Users report that FTS5 search is insufficient in practice

### Immediate improvements to pursue instead

1. **FTS5 OR semantics** (separate task already planned) — expand keyword matching
2. **Better descriptions** — improve the indexing prompt to generate more search-friendly descriptions with synonyms
3. **Multi-term search** — allow the agent to search for multiple related terms in a single query
