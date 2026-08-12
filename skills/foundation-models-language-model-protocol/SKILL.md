---
name: foundation-models-language-model-protocol

description: Use this skill when building a Swift package that adapts a server-side language model to Apple's Foundation Models framework so it can be used with `LanguageModelSession`. Triggered when the user asks to "build a Foundation Models LanguageModel", "implement the LanguageModel protocol", "wrap our inference API for Foundation Models", "create a server model package for Apple", or works on a `*LanguageModel.swift` / `*Executor.swift` file that conforms to `LanguageModel` / `LanguageModelExecutor`.
---

# Foundation Models — Server Model LanguageModel Creation

This skill teaches you how to build the open-source Swift package that bridges a server-side inference API to Apple's Foundation Models framework. The package is the **translation layer** between the framework's API and your inference endpoint. App developers import the package, name your model, and call the same `LanguageModelSession` API they use for the on-device model — your endpoint serves the request.

After your package ships, an app developer's code looks like this:

```swift
import MyLanguageModel

let model = MyLanguageModel(name: "your-model-id", baseURL: URL(string: "https://api.example.com")!)
try await model.authenticateIfNeeded()  // OAuth — user signs into their account

let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires…")
```

That's the whole developer surface. Same `LanguageModelSession` API as the on-device model. Your endpoint runs the inference.

## What you own

You own the package, ship it on GitHub (open source is encouraged), and maintain it. Specifically the package:

- **Translates** the framework's API calls — conversation history, tool definitions, output schema — into your inference API request shape.
- **Declares** what your model supports — structured output, tool calling, thinking, multimodal — via `LanguageModelCapabilities`.
- **Owns authentication** — OAuth for end-user accounts, API keys for developer-paid usage, or both.
- **Surfaces errors** — including plan limits, with an upsell flow if you want to build one.
- **Streams events** through the framework's executor channel.

If a developer asks for a capability you didn't declare (e.g. tool calling on a model that doesn't support it), the framework throws `unsupportedCapability` for you — you don't write defensive code for that.

## What you implement

The framework defines two protocols. You provide a conformance to each, plus a Configuration value:

```swift
public protocol LanguageModel: Sendable {
  associatedtype Executor: LanguageModelExecutor where Executor.Model == Self
  var capabilities: LanguageModelCapabilities { get }
  var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
  associatedtype Configuration: Hashable & Sendable
  associatedtype Model: LanguageModel
  init(configuration: Configuration) throws
  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws
  func prewarm(model: Model, transcript: Transcript)  // default no-op
}
```

| Type | Purpose |
|---|---|
| `MyLanguageModel: LanguageModel` | The user-facing model description — capabilities, model id, auth state. Lightweight and `Sendable`. |
| `MyLanguageModel.Executor: LanguageModelExecutor` | Does the actual work — opens the stream, translates events. |
| `MyLanguageModel.Executor.Configuration: Hashable & Sendable` | Snapshot of everything the executor needs. The framework caches one executor per unique configuration, so equality matters — only put Hashable primitives in here. |

## Step 1 — Define your model type

```swift
import Foundation
import FoundationModels

public struct MyLanguageModel: Sendable {
  public let modelID: String
  public let baseURL: URL
  public let timeout: TimeInterval
  let authMode: AuthMode

  /// Initialize with an OAuth-backed credential store.
  public init(name: String, baseURL: URL, timeout: TimeInterval = 60) {
    self.modelID = name
    self.baseURL = baseURL
    self.timeout = timeout
    self.authMode = .oauth(accountID: OAuthSession.shared.accountID)
  }

  /// Initialize with a developer-supplied API key.
  public init(name: String, apiKey: String, baseURL: URL, timeout: TimeInterval = 60) {
    self.modelID = name
    self.baseURL = baseURL
    self.timeout = timeout
    self.authMode = .apiKey(apiKey)
  }

  /// Trigger an OAuth sign-in flow if the user is not already authenticated.
  /// No-op when the model was created with an API key.
  public func authenticateIfNeeded() async throws {
    if case .oauth = authMode {
      try await OAuthSession.shared.authenticateIfNeeded()
    }
  }
}

extension MyLanguageModel: LanguageModel {
  public var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([
      .toolCalling,
      .vision,
      .reasoning,
      // .guidedGeneration  // include only if your model strictly enforces JSON Schema
    ])
  }

  public var executorConfiguration: Executor.Configuration {
    Executor.Configuration(
      modelID: modelID,
      baseURL: baseURL,
      authMode: authMode,
      timeout: timeout
    )
  }
}
```

## Step 2 — Define your executor

The executor does the actual work. The framework caches one executor per unique `Configuration`, so make `Configuration` hold only Hashable primitives that identify the network endpoint and credential — NOT opaque store objects whose equality is unclear, and NOT per-request data.

```swift
extension MyLanguageModel {
  public struct Executor: LanguageModelExecutor {
    public typealias Model = MyLanguageModel

    public struct Configuration: Hashable, Sendable {
      let modelID: String
      let baseURL: URL
      let authMode: AuthMode
      let timeout: TimeInterval
    }

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
      self.configuration = configuration
      // Validate configuration here if useful (e.g. malformed URL, missing
      // required fields) and throw on bad input. Stand up any per-executor
      // resources you want to reuse across requests (HTTP client, gRPC stub,
      // vendored SDK handle — your choice).
    }

    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: MyLanguageModel,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      // 1. Translate `request` into your provider's request format.
      //    See "What `request` gives you" and "Translating request.transcript →
      //    provider request" for what's available and how to map it.

      // 2. Open the stream to your provider. The transport is your choice —
      //    URLSession.bytes, a vendored SDK, gRPC, WebSocket, anything that
      //    yields an async sequence of provider events.

      // 3. For each provider event, translate it into one or more channel
      //    events and send them. Use the same `entryID` for all events that
      //    belong to one response entry; use a DIFFERENT `entryID` for the
      //    tool-calls entry.

      let responseEntryID = UUID().uuidString
      let toolCallsEntryID = UUID().uuidString
      let reasoningEntryID = UUID().uuidString

      for try await providerEvent in openProviderStream(for: request) {
        try Task.checkCancellation()

        switch providerEvent {
        case .textDelta(let text):
          await channel.send(
            .response(entryID: responseEntryID, action: .appendText(text, tokenCount: 1))
          )

        case .toolCallStart(let id, let name):
          await channel.send(
            .toolCalls(
              entryID: toolCallsEntryID,
              action: .toolCall(
                id: id,
                name: name,
                action: .appendArguments("", tokenCount: 0)
              )
            )
          )

        case .toolCallArgsDelta(let id, let name, let args):
          await channel.send(
            .toolCalls(
              entryID: toolCallsEntryID,
              action: .toolCall(
                id: id,
                name: name,
                action: .appendArguments(args, tokenCount: 1)
              )
            )
          )

        case .toolCallRetracted(let toolCall):
          // Drop a tool call the model started streaming and then retracted.
          // `removeToolCall` takes the `Transcript.ToolCall` to drop.
          await channel.send(
            .toolCalls(entryID: toolCallsEntryID, action: .removeToolCall(toolCall))
          )

        case .reasoningDelta(let text):
          // Reasoning is its own top-level event. Pass `entryID: nil` to
          // coalesce consecutive deltas into the trailing reasoning entry, or
          // pass a stable id (as below) when you want to anchor a specific
          // entry — for example, a per-tool-call reasoning entry that you'll
          // close before tool-call deltas begin.
          await channel.send(
            .reasoning(entryID: reasoningEntryID, action: .appendText(text, tokenCount: 1))
          )

        case .reasoningSignature(let signature):
          // Wholesale replacement of the entry's signature bytes. `signature`
          // is opaque provider-supplied data — pass it through as `Data`.
          await channel.send(
            .reasoning(
              entryID: reasoningEntryID,
              action: .updateSignature(signature, tokenCount: 0)
            )
          )

        case .usage(let prompt, let cached, let completion, let reasoning):
          await channel.send(
            .response(
              entryID: responseEntryID,
              action: .updateUsage(
                input: .init(totalTokenCount: prompt, cachedTokenCount: cached),
                output: .init(totalTokenCount: completion, reasoningTokenCount: reasoning)
              )
            )
          )

        case .done:
          return
        }
      }
    }
  }
}

public enum AuthMode: Hashable, Sendable {
  case oauth(accountID: String)   // package looks up the live token at request time
  case apiKey(String)
}
```

That's the whole shape. The provider-specific work is just translation.

## What `request` gives you

`LanguageModelExecutorGenerationRequest` is what the framework hands you on every `respond(...)` call:

```swift
public struct LanguageModelExecutorGenerationRequest: Sendable {
  public var id: UUID
  public var transcript: Transcript
  public var enabledToolDefinitions: [Transcript.ToolDefinition]
  public var schema: GenerationSchema?
  public var generationOptions: GenerationOptions
  public var contextOptions: ContextOptions
  public var metadata: [String: GeneratedContent]
}
```

| Field | What it is | How to use it |
|---|---|---|
| `id` | Unique UUID for this request. | Forward into your provider's request id / log fields for tracing. |
| `transcript` | The full conversation history the developer wants you to continue. | Translate `transcript.entries` into your provider's chat-message array. |
| `enabledToolDefinitions` | Tool definitions the developer registered as available for this turn. Empty if none. | Translate into your provider's tool/function definitions. Skip if you didn't declare `.toolCalling`. |
| `schema` | Optional `GenerationSchema` describing required JSON output shape. | Forward into your provider's structured-output / JSON-mode field. Skip if you didn't declare `.guidedGeneration`. |
| `generationOptions` | Sampling controls: `temperature`, `samplingMode`, `maximumResponseTokens`, `toolCallingMode`. | Translate each present field into your provider's equivalent parameter. Treat `nil` fields as "use provider default". |
| `contextOptions` | Prompting controls: `includeSchemaInPrompt`, `reasoningLevel`. | Use `reasoningLevel` to set your provider's thinking-budget knob. `includeSchemaInPrompt` tells you whether to inline the JSON schema into the system prompt. |
| `metadata` | Developer-provided dictionary passed at the call site. Values arrive as `GeneratedContent` — read them out with `try value.value(String.self)` (or whatever type you expect). | Forward to your provider's metadata field for analytics, or define well-known keys for an escape hatch (e.g. a `passthrough` key for forwarding raw provider-specific options). |

### Inspecting option types

Several framework option types are enum-like structs you can *construct* but historically couldn't *read*. To let executors translate them, there is now a `kind` property on each. Switch on `kind` to map the value onto your provider's parameters.

```swift
// generationOptions.samplingMode — translate to your provider's sampling knobs.
if let mode = request.generationOptions.samplingMode {
  switch mode.kind {
  case .greedy:
    providerRequest.temperature = 0 // deterministic
  case .randomTopK(let k, let seed):
    providerRequest.topK = k
    providerRequest.seed = seed
  case .randomProbabilityThreshold(let p, let seed):
    providerRequest.topP = p
    providerRequest.seed = seed
  }
}
```

The same `kind`-based inspection applies to `Transcript.ResponseFormat` (`.schema(GenerationSchema)`) when you walk transcript entries. And `Transcript.ToolDefinition.parameters` is a `GenerationSchema` — see the note below on serializing it.

> `GenerationSchema` conforms to `Codable` and encodes to standard [JSON Schema](https://json-schema.org). Both `request.schema` and each `ToolDefinition.parameters` are `GenerationSchema` values, so for most server providers you can hand them straight to a `JSONEncoder` and drop the result into your structured-output / function-parameters field — no manual schema translation needed.

## Capabilities

Declare what your model can do. Don't declare a capability you don't fully support — the framework throws `unsupportedCapability` for the developer when they request a capability you didn't list.

| Term | API symbol | Meaning |
|---|---|---|
| Tool calling | `.toolCalling` | Model calls developer-registered tools. Translate `request.enabledToolDefinitions` into your provider's tool definitions; emit per-call tool-call events (`.toolCalls(.toolCall(...))`) as the model streams a call. |
| Vision | `.vision` | Prompts may include images. Walk `Transcript.Prompt.segments` and forward image data in your provider's format (base64, URL, etc.). |
| Reasoning | `.reasoning` | Model produces structured reasoning separate from response text. Emit `.reasoning(...)` events — a top-level event peer to `.response` and `.toolCalls` — as reasoning streams. |
| Structured output | `.guidedGeneration` | Model strictly conforms output to a JSON Schema. Forward `request.schema` into your provider's structured-output / JSON-mode field. |

## Authentication

You own auth. Two common patterns, both shown on the model type above.

### OAuth — end-user accounts

The user signs into their existing account with you. Your package handles the browser flow, stores tokens in the Keychain, refreshes them, and provides headers to the executor on demand.

```swift
public func authenticateIfNeeded() async throws {
  if try await OAuthSession.shared.currentAccessToken() == nil {
    try await OAuthSession.shared.runOAuthFlow()
  }
}
```

Make `authenticateIfNeeded()` idempotent. App developers will call it on app launch or before the first `respond(...)`.

### API key — developer-paid usage

The developer supplies the key at construction time. No interactive flow.

```swift
public init(name: String, apiKey: String, ...) { ... }
```

You can offer both initializers from the same model type. The `Configuration` should hash on a stable identity (the OAuth `accountID`, or the API key itself) so two sessions for two different users get distinct cached executors.

## The Event API — full reference

Events are sent on `LanguageModelExecutorGenerationChannel` via `await channel.send(...)`. Three top-level cases — each is a peer transcript-entry kind: `.response`, `.toolCalls`, and `.reasoning`.

### Response events — `.response(entryID:action:)`

`entryID` groups events into a single response entry in the developer's transcript. Use the same `entryID` for every event that belongs to a single response.

| Action | When to use |
|---|---|
| `.appendText(_:segmentID:tokenCount:)` | Each chunk of model-generated user-facing text. |
| `.replaceTextSegment(_:segmentID:tokenCount:)` | Whole-segment replacement when your provider sends a final corrected version. |
| `.addAttachmentSegment(_:)` | Add a `Transcript.AttachmentSegment` (currently image content) to the response. Use this when your model emits non-text output inline — e.g. a generated diagram, edited image, or visual artifact. Each call ADDS a new segment; pass a stable `id` if you'll later remove it. See "Attachment segments" below. |
| `.removeAttachmentSegment(_:)` | Remove a previously-added attachment by passing the `Transcript.AttachmentSegment` to drop. Symmetric to `.removeToolCall(_:)` — use when the model retracts an attachment mid-stream, or as the first half of a remove-then-add replacement. |
| `.updateMetadata(_:)` | Wholesale snapshot of entry metadata. Takes `[String: any ConvertibleToGeneratedContent]`, so pass values unwrapped (`["provider": "acme", "attempt": 2]`). Re-emit every key on every event. |
| `.updateUsage(input:output:)` | Cumulative running totals. Each event REPLACES prior totals (does not add). Authoritative. |

### Reasoning events — `.reasoning(entryID:action:)`

Reasoning is a top-level event peer to `.response` and `.toolCalls`. Each event belongs to a `Transcript.Reasoning` entry identified by `entryID`.

`entryID` is **optional**. Pass `nil` to coalesce into the trailing reasoning entry — if the most-recent consumed event was also reasoning, the framework reuses that entry's id; otherwise it mints a fresh UUID. Pass an explicit id when you need a stable anchor (e.g. a per-tool-call reasoning entry that you'll reference again from a separate emission point).

| Action | When to use |
|---|---|
| `.appendText(_:segmentID:tokenCount:)` | Append reasoning text to the entry's current text segment. The common case for streaming a thought block. |
| `.replaceTextSegment(_:segmentID:tokenCount:)` | Replace the entry's current reasoning text segment wholesale (e.g. provider sent a corrected/finalized thought). |
| `.updateSignature(_:tokenCount:)` | Replace the entry's signature wholesale. Pass opaque bytes as `Data` — don't UTF-8 decode signatures assuming text. |
| `.updateMetadata(_:)` | Wholesale metadata snapshot for the reasoning entry. |
| `.updateUsage(input:output:)` | Cumulative usage totals. Each event REPLACES prior totals. Reasoning-token totals are also accumulated separately by the framework from `appendText` token counts, so emit `updateUsage` only when your provider reports authoritative totals. |

### Tool-call events — `.toolCalls(entryID:action:)`

Use a DIFFERENT `entryID` from your response entry — they live in different transcript entries. Common pattern: one fresh UUID per response, one fresh UUID per tool-calls entry.

`ToolCalls.Action` is a small outer enum. Its main case, `.toolCall(id:name:action:)`, wraps a **nested** per-call action for argument streaming and per-call metadata. Argument deltas for parallel tool calls may be interleaved; each inner `.toolCall(...)` event carries its own `id` to route the delta to the right call.

| Outer action | When to use |
|---|---|
| `.toolCall(id:name:action:)` | Wraps a per-call event. `id` selects (or opens) the tool call; `name` carries the function name on every event for that id; `action` names the mutation (see inner table). |
| `.removeToolCall(_:)` | Drop a tool call the model streamed and then retracted. Pass the `Transcript.ToolCall` to remove. |
| `.updateMetadata(_:)` | Entry-level metadata snapshot. Prefer per-call metadata via `.toolCall(..., .updateMetadata(...))` for values that belong to one specific call. |
| `.updateUsage(input:output:)` | Usage totals. Cumulative, not additive — each event REPLACES prior totals. |

Inner `ToolCall.Action` — what you set on `.toolCall(id:name:action:)`:

| Inner action | When to use |
|---|---|
| `.appendArguments(_:tokenCount:)` | The first inner event for a given `id` opens the tool call; subsequent events with the same `id` append argument text. Deltas for parallel tool calls may be interleaved — each event carries its own `id` to distinguish them. |
| `.updateMetadata(_:)` | Per-call metadata snapshot (e.g. a per-call tag from your provider). Replaces the call's metadata wholesale — re-emit every key you want preserved. Emit this BEFORE the first `.appendArguments` for the id so the metadata lands on the call when it's first written. |

> If your provider emits reasoning interleaved with tool calls (e.g. a thought trace before picking a function), send it as a `.reasoning(entryID:..., action: ...)` event. Reasoning has its own transcript entries — they sit alongside the tool-calls entry in the transcript, not inside it.

## Structured payloads — use metadata

When your provider returns a structured payload that doesn't fit any of the framework's built-in segment kinds (text, reasoning, attachments, citations, advisories), put it in entry metadata with `.updateMetadata(_:)`. Values are stored as `GeneratedContent`, so nested objects and arrays round-trip and survive transcript serialization.

`.updateMetadata(_:)` takes `[String: any ConvertibleToGeneratedContent]`. `String`, `Int`, `Double`, `Bool`, `Decimal`, arrays of those, and any `@Generable` type conform. For an ad-hoc nested object, build a `GeneratedContent(properties:)` — a plain Swift dictionary does *not* conform:

```swift
// Web-search results as response metadata:
let searchResults = results.map { result in
  GeneratedContent(properties: ["title": result.title, "url": result.url.absoluteString])
}

await channel.send(
  .response(
    entryID: responseEntryID,
    action: .updateMetadata(["searchResults": searchResults])
  )
)
```

The developer reads it back off `Transcript.Response.metadata`, which is `[String: GeneratedContent]`:

```swift
if let results = response.metadata["searchResults"] {
  for result in try results.value([GeneratedContent].self) {
    let title = try result.value(String.self, forProperty: "title")
  }
}
```

If the payload has a fixed shape, declaring it `@Generable` is nicer on both sides — pass the value straight into `.updateMetadata` and read it back with `try results.value([SearchResult].self)`.

Metadata is a wholesale snapshot — re-emit every key you want preserved on each event.

## Attachment segments

When your model produces non-text output inline with its response — currently images, with the enum designed to grow to other media types — emit it as an attachment segment. The framework places the attachment in the developer's transcript alongside the response text so they can render or persist it. This is the streaming-out counterpart to the `.vision` capability, which describes streaming-*in* image input.

```swift
public struct AttachmentSegment: Sendable, Identifiable, Equatable {
  public var id: String
  public var content: Attachment
  public var label: String?
}

public enum Attachment: Sendable, Equatable {
  case image(ImageAttachment)
}
```

Add an attachment via `.response(action: .addAttachmentSegment(...))`:

```swift
let attachment = Transcript.AttachmentSegment(
  id: imageID,                                              // stable id you mint
  content: .image(Transcript.ImageAttachment(cgImage)),     // CGImage / CIImage / CVPixelBuffer / URL
  label: "Generated diagram"                                // optional caption / alt text
)

await channel.send(
  .response(entryID: responseEntryID, action: .addAttachmentSegment(attachment))
)
```

| Field | Notes |
|---|---|
| `id` | Stable identifier for this attachment within the response. Mint a UUID. Keep the `AttachmentSegment` around (or rebuild one with the same `id`) if you later need to `.removeAttachmentSegment(_:)`. |
| `content` | A `Transcript.Attachment` enum — currently `.image(ImageAttachment)`. Build the `ImageAttachment` from a `CGImage`, `CIImage`, `CVPixelBuffer`, or a `URL`. |
| `label` | Optional human-readable label (e.g. caption or alt-text). |

To retract or supersede an attachment, send `.removeAttachmentSegment(_:)` with the segment to drop:

```swift
await channel.send(
  .response(entryID: responseEntryID, action: .removeAttachmentSegment(attachment))
)
```

There is no `replaceAttachmentSegment` — to replace an attachment with a refined version, send a `removeAttachmentSegment` followed by a fresh `addAttachmentSegment` (with either the same `id` or a new one). Each `addAttachmentSegment` ADDS a new segment; it does not replace an existing one of the same id.

Reach for an attachment segment whenever your provider returns binary media as part of the assistant turn — generated images, image edits, or visual diagnostic artifacts. For provider-specific *metadata about* media (e.g. a moderation label on an image), use `.updateMetadata`.

## Translating `request.transcript` → provider request

`request.transcript.entries` is an array of `Transcript.Entry`:

```swift
public enum Entry {
  case instructions(Instructions)  // system prompt
  case prompt(Prompt)              // user message (may contain text + images)
  case toolCalls(ToolCalls)        // model's prior tool calls
  case toolOutput(ToolOutput)      // results returned from those tools
  case response(Response)          // model's prior text response
  case reasoning(Reasoning)        // model's prior reasoning
}
```

Map this to your provider's chat-message array. Typical translation:

| Entry | Common provider role | Notes |
|---|---|---|
| `.instructions` | `system` | Concatenate text segments. |
| `.prompt` | `user` | Walk `segments` — text and images interleaved; forward as your provider's content blocks. |
| `.toolCalls` | `assistant` | Emit a message with the provider's tool-calls array. |
| `.toolOutput` | `tool` (or `user`, depending on provider convention) | One per tool result. |
| `.response` | `assistant` | The model's prior text. Concatenate text segments. |
| `.reasoning` | provider-specific | Model's prior reasoning. If your provider preserves reasoning across turns (e.g. as a dedicated field on assistant messages, or via a signature it requires you to echo back), forward `segments` and `signature` accordingly. When `signature` is non-nil, `segments` may be a partial summary rather than the full reasoning — treat the signature as the authoritative anchor. If your provider does not accept prior reasoning, drop these entries — the framework keeps them in the transcript for downstream consumers regardless. |

## Translating provider stream events → channel events

Patterns repeat across providers:

| Provider concept | Channel event |
|---|---|
| Text delta in assistant message | `.response(.appendText)` |
| Tool/function call open + first args chunk | `.toolCalls(.toolCall(id:name:action: .appendArguments(...)))` (first event for a new id opens the call) |
| Tool/function call args delta | `.toolCalls(.toolCall(id:name:action: .appendArguments(...)))` (same id and name as the open event) |
| Tool/function call retracted mid-stream | `.toolCalls(.removeToolCall(_:))` |
| Per-call metadata (e.g. a provider-supplied call tag) | `.toolCalls(.toolCall(id:name:action: .updateMetadata(...)))` — emit BEFORE the first `.appendArguments` for the id |
| Reasoning / thinking text delta | `.reasoning(entryID: …, action: .appendText(...))` — pass `entryID: nil` to coalesce consecutive deltas, or a stable id to anchor a specific entry |
| Reasoning text superseded by a finalized version | `.reasoning(entryID: …, action: .replaceTextSegment(...))` |
| Reasoning signature bytes | `.reasoning(entryID: …, action: .updateSignature(Data, tokenCount:))` — opaque bytes, replaces wholesale |
| Inline image output (model-generated image / diagram / edited asset) | `.response(.addAttachmentSegment(Transcript.AttachmentSegment(content: .image(...))))` |
| Image output retracted or superseded | `.response(.removeAttachmentSegment(_:))` — followed by a fresh `addAttachmentSegment` to replace |
| Token usage report | `.response(.updateUsage)` — or `.reasoning(.updateUsage)` / `.toolCalls(.updateUsage)` if your provider scopes usage to that entry |
| Asset / model metadata | `.response(.updateMetadata)` |

## Error handling

Throw typed `LanguageModelError` cases so the framework can surface user-friendly messages and so app developers can pattern-match against well-known cases. The full enum has nine cases, each carrying a payload struct with a `debugDescription`, a free-form `metadata` dictionary, and case-specific fields:

| Case | Payload-specific fields | When to throw |
|---|---|---|
| `.contextSizeExceeded(ContextSizeExceeded)` | `contextSize: Int`, `tokenCount: Int` | The transcript would exceed the model's context window. The developer can recover by trimming entries and retrying. |
| `.rateLimited(RateLimited)` | `resetDate: Date?` | Provider returned 429 / a burst-throttling signal. Include `resetDate` when the provider tells you when retries will succeed. |
| `.guardrailViolation(GuardrailViolation)` | — | Provider's safety system flagged the prompt or the response. |
| `.refusal(Refusal)` | `explanation: String` (required by the public initializer) | Model declined to answer for non-safety reasons (e.g. asked for something out of scope). Surfaced to the developer via `refusal.explanation` / `refusal.explanationStream`. |
| `.unsupportedCapability(UnsupportedCapability)` | `capability: LanguageModelCapabilities.Capability` | A capability you didn't declare was requested. The framework throws this for you when you under-declare — only throw it manually when your provider rejects a capability mid-stream. |
| `.unsupportedTranscriptContent(UnsupportedTranscriptContent)` | `unsupportedContent: [Transcript.Entry]` | The transcript contains content the model can't process — unsupported file types, corrupted data, or an attachment kind your provider doesn't handle. |
| `.unsupportedGenerationGuide(UnsupportedGenerationGuide)` | `schemaName: String?` | The generation schema uses a guide your provider doesn't support (e.g. an exotic regex pattern). |
| `.unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)` | `languageCode: Locale.LanguageCode` | The model declined the request because the prompt language isn't supported. |
| `.timeout(Timeout)` | — | Request didn't complete within the configured timeout window. |

Every payload struct exposes `debugDescription: String` (developer-facing message — include the provider's raw error string) and `metadata: [String: any Sendable]` (free-form bag for extra context like provider error code or request id), in addition to the case-specific fields shown above.

```swift
import FoundationModels

throw LanguageModelError.contextSizeExceeded(
  LanguageModelError.ContextSizeExceeded(
    contextSize: 200_000,
    tokenCount: 220_000,
    debugDescription: "Prompt exceeds context window"
  )
)

throw LanguageModelError.rateLimited(
  LanguageModelError.RateLimited(
    resetDate: Date().addingTimeInterval(60),
    debugDescription: "HTTP 429"
  )
)

throw LanguageModelError.guardrailViolation(
  LanguageModelError.GuardrailViolation(debugDescription: "Provider reported unsafe content")
)

throw LanguageModelError.unsupportedCapability(
  LanguageModelError.UnsupportedCapability(
    capability: .vision,
    debugDescription: "Provider rejected an image segment mid-stream"
  )
)

throw LanguageModelError.unsupportedTranscriptContent(
  LanguageModelError.UnsupportedTranscriptContent(
    unsupportedContent: offendingEntries,
    debugDescription: "Provider could not decode the supplied image data"
  )
)

throw LanguageModelError.unsupportedGenerationGuide(
  LanguageModelError.UnsupportedGenerationGuide(
    schemaName: "ItineraryDay",
    debugDescription: "Regex anchors are not supported by this model"
  )
)

throw LanguageModelError.unsupportedLanguageOrLocale(
  LanguageModelError.UnsupportedLanguageOrLocale(
    languageCode: Locale.LanguageCode("xx"),
    debugDescription: "Model does not support this language"
  )
)

throw LanguageModelError.timeout(
  LanguageModelError.Timeout(debugDescription: "Request did not complete within configured timeout")
)
```

### Plan limits and upsell

If your service has plan tiers and the user has exhausted theirs, surface it as a structured error so app developers can present an upsell or fall-back path. Two reasonable approaches:

- **`rateLimited` with a `resetDate`** — when the limit resets on a known schedule (per-minute, per-day).
- **A custom error type** that conforms to `LocalizedError` and ships in your package, when the user needs to upgrade their account. Optionally include a sign-up URL the developer can wire to their UI.

```swift
public enum MyServiceError: Error, LocalizedError {
  case planLimitReached(upgradeURL: URL?)

  public var errorDescription: String? {
    switch self {
    case .planLimitReached: "Your plan limit has been reached."
    }
  }
}
```

Don't catch transport errors and convert them to generic strings. Let them propagate, or wrap into `LanguageModelError.timeout` only when you know that's what they represent.

## Cancellation

`respond(to:model:streamingInto:)` runs in a Task that may be cancelled. Check inside your stream loop:

```swift
for try await providerEvent in openProviderStream(for: request) {
  try Task.checkCancellation()
  // ...
}
```

When cancelled, return or throw `CancellationError()`. The framework manages the channel lifetime around your `respond(...)` call — you don't need to do anything else on cancellation.

## EntryID hygiene

- Generate a fresh UUID for each top-level response entry.
- Generate a SEPARATE fresh UUID for the tool-calls entry. They must not collide.
- For reasoning entries, you have two patterns:
  - **Coalesce consecutive deltas:** pass `entryID: nil` and let the framework reuse the trailing reasoning entry's id (or mint a new one). Best for "stream one thought block to completion" flows.
  - **Anchor a specific entry:** pass a stable id you generated. Best when you'll emit additional events for that same entry from a different code path (e.g. a per-tool-call signature that arrives later).
- Reuse the same UUID for every event within one entry (every `appendText`, every `updateUsage`).

## Package layout

```
MyLanguageModel/
├── Package.swift
├── README.md
├── LICENSE
├── Sources/
│   └── MyLanguageModel/
│       ├── MyLanguageModel.swift          // public model + LanguageModel conformance
│       ├── MyExecutor.swift               // LanguageModelExecutor conformance
│       ├── MyRequestBuilder.swift         // request → provider request body
│       ├── MyEventTranslator.swift        // provider stream → channel events
│       ├── MyClient.swift                 // transport layer (your choice)
│       ├── Auth/
│       │   ├── AuthMode.swift             // Hashable enum: .oauth(accountID:) / .apiKey(_)
│       │   └── OAuthSession.swift         // browser flow, Keychain, refresh
│       └── MyError.swift                  // custom errors → LanguageModelError mapping
└── Tests/
    └── MyLanguageModelTests/
        ├── RequestBuilderTests.swift
        ├── EventTranslatorTests.swift
        └── ExecutorIntegrationTests.swift
```

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MyLanguageModel",
  platforms: [
    // The LanguageModel / LanguageModelExecutor protocols are available on
    // iOS 27, macOS 27, visionOS 27, and watchOS 27. Set your minimums at or
    // above those, plus whatever your transport/auth dependencies require.
  ],
  products: [
    .library(name: "MyLanguageModel", targets: ["MyLanguageModel"]),
  ],
  targets: [
    .target(name: "MyLanguageModel"),
    .testTarget(
      name: "MyLanguageModelTests",
      dependencies: ["MyLanguageModel"]
    ),
  ]
)
```

`FoundationModels` is a system framework — no SwiftPM dependency declaration needed; just `import FoundationModels`. If your package depends on your own SDK as a downstream dependency, add it here normally.

## Testing

Three layers, easiest to most thorough:

### 1. Request-builder unit tests

Pure-function tests of `request → provider request body`. No network, no async.

```swift
import Testing
import FoundationModels
@testable import MyLanguageModel

@Test func `system instructions become a system message`() throws {
  let transcript = Transcript(entries: [
    .instructions(
      Transcript.Instructions(
        segments: [.text(Transcript.TextSegment(content: "Be concise."))],
        toolDefinitions: []
      )
    ),
    .prompt(
      Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "Hello"))]
      )
    ),
  ])

  let body = try buildProviderRequest(from: transcript, modelID: "test-model")

  #expect(body.messages[0].role == "system")
  #expect(body.messages[0].text == "Be concise.")
  #expect(body.messages[1].role == "user")
}
```

### 2. Event-translator unit tests

Pure-function tests of `provider event → channel event(s)`. Stub the channel with a recording sink and assert the sequence of `send(...)` calls.

```swift
@Test func `text delta becomes appendText event`() async throws {
  let sink = RecordingChannel()
  let translator = MyEventTranslator(
    responseEntryID: "r1",
    toolCallsEntryID: "t1",
    channel: sink
  )

  await translator.translate(.textDelta("Hi"))

  #expect(sink.events.count == 1)
  // Inspect the recorded event by matching on `kind.storage` to recover
  // the typed `Response` / `Reasoning` / `ToolCalls` payload, then assert on
  // its `entryID` and `action` fields directly. (Channel events are not
  // Equatable, so a literal `==` against an event literal won't compile.)
}
```

### 3. End-to-end tests through `LanguageModelSession`

Stub your transport (`URLProtocol` for URLSession-based clients, a fake gRPC stub for gRPC, etc.) and drive the executor through the real `LanguageModelSession.respond(...)` API. This validates the full pipeline — request shape, event translation, and how the framework assembles your events into the developer-visible response.

```swift
@Test func `streamed text deltas assemble into a complete response`() async throws {
  StubbedTransport.shared.respond(
    with: [
      .textDelta("Hello"),
      .textDelta(", world!"),
      .done,
    ]
  )

  let model = MyLanguageModel(name: "test-model", apiKey: "sk-test", baseURL: .testBase)
  let session = LanguageModelSession(model: model)
  let response = try await session.respond(to: "anything")

  #expect(response.content == "Hello, world!")
}
```

What to cover end-to-end:

- Plain text response.
- Tool-call streaming: open + multiple arg deltas → developer's `Response.toolCalls` contains one fully assembled call.
- Reasoning + text + tool call interleaved.
- Cancellation mid-stream.
- Each error type (`rateLimited`, `contextSizeExceeded`, `guardrailViolation`, your custom `planLimitReached`).
- Image input round-trip if you support `.vision`.

## Pitfalls

- **`updateUsage` is wholesale, not additive.** Always send cumulative totals from the provider — never deltas.
- **`updateMetadata` are wholesale snapshots.** A subsequent event with fewer items REMOVES the missing ones. Re-emit everything you want preserved.
- **Metadata values are `GeneratedContent`, not arbitrary `Codable`.** You pass `any ConvertibleToGeneratedContent` and read back `GeneratedContent`. A plain Swift dictionary doesn't conform — build nested objects with `GeneratedContent(properties:)` or declare the payload `@Generable`.
- **Put provider-specific structured payloads in metadata.** `.updateMetadata` is where a payload that isn't text, reasoning, an attachment, a citation, or an advisory belongs. See "Structured payloads — use metadata".
- **Every `.toolCall(id:name:action:)` event must carry the function `name`** — not just the opener. Subsequent events for the same `id` should pass the same `name`.
- **Emit per-call metadata BEFORE the first `.appendArguments` for that id.** This ensures the metadata is attached to the call the moment it's first written rather than arriving after the fact.
- **Use `.removeToolCall(_:)` when the model retracts a streamed tool call** rather than trying to mutate prior argument deltas — there is no `replaceArguments` equivalent for tool calls.
- **Attachments add, they don't replace.** `.addAttachmentSegment` always adds a new segment. To supersede a streamed attachment, send `.removeAttachmentSegment(_:)` followed by a fresh `.addAttachmentSegment(...)` — there is no `replaceAttachmentSegment`.
- **Don't try to "fix up" prior text via mutation.** Use `replaceTextSegment` if your provider sends a final corrected version.
- **Reasoning signatures are opaque bytes.** Don't UTF-8 decode them assuming text; pass them through as `Data`.
- **Pick an `entryID` strategy for reasoning and stick to it.** Passing `nil` coalesces consecutive deltas into the trailing reasoning entry — fine for one-thought-block flows. But if you alternate `nil` and explicit ids, or interleave reasoning with a non-reasoning event in between, you can split a single thought across two transcript entries unintentionally. When in doubt, anchor with a stable id you mint yourself.
- **Don't declare a capability you don't fully support.** The framework will throw `unsupportedCapability` for you — you don't write defensive code for that.
- **Configuration must hold only Hashable primitives.** Don't put opaque store objects or class references in there — the framework hashes Configuration to cache executors.
