---
name: foundation-models-utilities

description: Use this skill when working with the `FoundationModelsUtilities` Swift package — a collection of utilities that extend Apple's Foundation Models framework with a chat completions client, on-demand "skills" that activate via tool calls, and history-management modifiers (drop completed tool calls, rolling window, summarization). Triggered when the user asks to "talk to a chat completions endpoint", "connect to OpenAI / a local LLM server", "add skills to a session", "manage transcript size", "summarize history", "drop tool calls", "rolling window", or works in a file that imports `FoundationModelsUtilities`.
---

# FoundationModelsUtilities

`FoundationModelsUtilities` is a Swift package that adds practical utilities on top of Apple's Foundation Models framework. It is built to compose with the framework's `LanguageModelSession`, `Profile`, and `DynamicProfile` APIs — not replace them. Three independent feature areas, each guarded by its own SwiftPM trait:

| Trait | What it adds |
|---|---|
| `ChatCompletions` | `ChatCompletionsLanguageModel` — a `LanguageModel` that talks to any OpenAI-compatible `/chat/completions` endpoint and streams results back through Foundation Models. |
| `Skills` | `Skill`, `Skills`, `SkillActivations`, `SkillsBuilder` — on-demand instructions or prompt fragments the model can activate by issuing a tool call. |
| `History` | `summarizeHistory(...)`, `rollingWindow(entries:)`, `droppingCompletedToolCalls()` — `DynamicProfile` modifiers that compress the transcript before each generation. |

All three traits are enabled by default, so for most apps `import FoundationModelsUtilities` is all that's needed.

```swift
import FoundationModels
import FoundationModelsUtilities
```

The package targets macOS, iOS, visionOS, and watchOS 27.0 or newer.

## ChatCompletionsLanguageModel — talking to an OpenAI-compatible `/chat/completions` endpoint

`ChatCompletionsLanguageModel` conforms to `FoundationModels.LanguageModel`, so you drop it into a `LanguageModelSession` exactly like the on-device `SystemLanguageModel`. It speaks the OpenAI Chat Completions REST API: `POST /chat/completions`, JSON body, `text/event-stream` response, `[DONE]` sentinel.

```swift
let model = ChatCompletionsLanguageModel(
  name: "your-model-name",
  url: URL(string: "https://api.example.com")!
)

let session = LanguageModelSession(model: model)
let response = try await session.respond(
  to: "How many folds does it take to make a paper crane?"
)
print(response.content)
```

### Initializer

```swift
public init(
  name: String,
  url: URL,
  additionalHeaders: [String: String] = [:],
  supportsGuidedGeneration: Bool = true
)
```

| Parameter | What it does |
|---|---|
| `name` | The model identifier sent in the `model` field of every request. Forwarded verbatim to the server. |
| `url` | The base URL of the chat completions endpoint. The model appends `/chat/completions` (or `/v1/chat/completions` if the base URL doesn't already include `v1`). |
| `additionalHeaders` | Headers merged on top of the defaults (`Content-Type: application/json`, `Accept: text/event-stream`, `User-Agent: <bundle id>`). The most common use is auth — `["Authorization": "Bearer \(apiKey)"]`. Custom headers always win on collision. |
| `supportsGuidedGeneration` | Whether the server honors the `response_format` / JSON-Schema field. Set to `false` for LLM servers that don't enforce strict structured output. |

### Capabilities

`ChatCompletionsLanguageModel` declares `.vision`, `.toolCalling`, and `.reasoning` unconditionally, plus `.guidedGeneration` when `supportsGuidedGeneration` is `true`. If your server lacks structured-output support, pass `supportsGuidedGeneration: false` so the framework throws `unsupportedCapability` instead of silently sending a `response_format` field the server will ignore.

### What it sends on the wire

For each `respond(...)` call the executor builds a single streaming POST:

- `messages`: built by walking the transcript. `instructions` → `system`, `prompt` → `user`, `response` → `assistant`, `toolCalls` → `assistant` with a `tool_calls` array, `toolOutput` → `tool` (with `tool_call_id`).
- `tools`: each enabled `Transcript.ToolDefinition` becomes `{"type":"function","function":{"name","description","parameters"}}`.
- `tool_choice`: derived from `request.generationOptions.toolCallingMode` — `.allowed`/`.none` → `auto`, `.required` → `required`, `.disallowed` → `none`.
- `response_format`: when `request.schema` is non-nil and `supportsGuidedGeneration` is true, sent as `{"type":"json_schema","json_schema":{"name","schema","strict":true}}`. The `name` is read from the schema's `title`/`type`, falling back to `"Response"`.
- `temperature`, `max_completion_tokens`: forwarded from `request.generationOptions`.
- `stream: true`, `stream_options: {include_usage: true}` — both always set.

Vision: any `.attachment(.image(...))` segment in a prompt is JPEG-encoded, base64-wrapped, and sent as a `data:image/jpeg;base64,...` URL inside an `image_url` content block. `CGImage`-only input is currently supported; other attachment types throw `unsupportedTranscriptContent`.

### What it parses on the way back

Each SSE `data:` chunk is decoded as a `ChatCompletionChunk`. The executor maintains three stable `entryID`s (one each for response, reasoning, and tool calls) so interleaved deltas land in the right transcript entry instead of fragmenting:

- `delta.content` → `.response(.appendText(...))`
- `delta.reasoning_content` → `.reasoning(.appendText(...))`
- `delta.tool_calls[i]` → `.toolCalls(.toolCall(id:name:action: .appendArguments(...)))`. The first chunk for a given `index` carries the `id`/`name`; later chunks carry only argument fragments and are routed by index.
- `usage` (sent because `include_usage: true`) → `.response(.updateUsage(...))`. Cumulative; emitted AFTER content in the same chunk so the authoritative total replaces any tokens credited by `appendText`.

`data: [DONE]` and SSE comments (`:` prefix) and non-`data:` field lines (`event:`, `id:`, `retry:`) are skipped.

### Reasoning round-trips

When the previous turn produced reasoning, the executor echoes it back as `reasoning_content` on the next assistant message. Reasoning entries are buffered and attached to the next assistant entry (response or tool calls). A trailing reasoning entry with no following assistant message becomes a standalone assistant message with `reasoning_content` set.

### Errors

- HTTP non-200 → `ChatCompletionsLanguageModel.RequestError.httpError(statusCode:data:)`.
- Server emits `{"error":{"message",...}}` mid-stream → `ChatCompletionsLanguageModel.APIError(message:type:param:code:)`.
- Malformed SSE → `ChatCompletionsLanguageModel.RequestError.invalidStreamData`.
- Unsupported attachment kinds in the transcript → `LanguageModelError.unsupportedTranscriptContent`.

Both `RequestError` and `APIError` conform to `LocalizedError`; pattern-match on them at the call site if you need to translate to UI.

## Skills — on-demand instructions activated by tool calls

`Skills` is a `DynamicInstructions` component that pairs a list of `Skill` values with a synthesized tool the model can call to toggle them. The model decides, mid-conversation, when to pull in a skill's content. Until activation, only the skill's **name** and **description** are in the prompt — the body of the skill stays out, keeping the prompt small and time-to-first-token low.

```swift
@Observable
class Assistant {
  let activations = SkillActivations()
}

struct MyProfile: LanguageModelSession.DynamicProfile {
  let assistant: Assistant

  var body: some DynamicProfile {
    Profile {
      Instructions("A conversation between a user and a helpful assistant.")
      ToggleDarkModeTool()

      Skills(activations: assistant.activations) {
        Skill(
          name: "style-guide",
          description: "Applies the project's writing style guide",
          prompt: "# Style Guide\n…"
        )

        Skill(
          name: "calendaring",
          description: "Read and modify the user's calendar",
          instructions: "Unless specified otherwise, all work meetings should "
            + "start 5 minutes after the hour"
        )
      }
    }
  }
}
```

### Two flavors of `Skill`

| Flavor | Initializer | Where the body lands | KV-cache impact |
|---|---|---|---|
| Prompt-based | `Skill(name:description:prompt:onActivate:)` or trailing `@PromptBuilder` | Returned as the **tool output** for the activation tool call. Lives inside the new turn. | None — earlier transcript bytes are unchanged. |
| Instructions-based | `Skill(name:description:instructions:allowsDeactivation:onActivate:onDeactivate:)` | Spliced into the existing top-of-transcript instructions entry. Persists while active. | Invalidates the KV cache for the entire conversation (the prefix changed). |

Choose prompt-based when the body is large or only relevant for one turn (style guides, reference docs, big rules). Choose instructions-based when the body is short, must take effect across many turns, and benefits from being treated as system-level instructions. Instructions-based skills can opt into deactivation (`allowsDeactivation: true`), which lets the model issue a second tool call to remove the body and restore the original instructions — useful in combination with `droppingCompletedToolCalls()` to fully evict the activation/deactivation tool-call pair from history.

### `SkillActivations` — observable, collection-conforming activation state

`SkillActivations` is a `Sendable` reference type that tracks active skill names. It is **observable** (`@Observable` semantics via `ObservationRegistrar`) and conforms to `RandomAccessCollection<String>`, so a SwiftUI view can iterate it and re-render when the model activates a skill. Mutations are guarded by a `Mutex` so it's safe to share across actors.

```swift
@Observable final class Assistant {
  let activations = SkillActivations()
}

// In a SwiftUI view:
ForEach(assistant.activations, id: \.self) { name in
  Text("Active skill: \(name)")
}
```

You don't call `activate(_:)` / `deactivate(_:)` yourself in the normal case — the synthesized tool does it. But the methods are public; reach for them when restoring state from disk or wiring tests.

### The synthesized toggle tool

Behind `Skills` is a private `ToggleSkillTool` that:

- Has a name of `"toggle_skill"` when at least one instructions skill allows deactivation, otherwise `"activate_skill"`. Override either default by passing `toolName:` to `Skills(...)`.
- Has a description of `"Activate or deactivate a skill"` or `"Activates a skill"` correspondingly. Override with `toolDescription:`.
- Takes a single argument `skill: String`, constrained to the list of currently-eligible skill names via `DynamicGenerationSchema.anyOf(...)`.
- When `strictSchema: true`, the eligible list excludes skills that are already in their target state (so the model can't try to activate an already-active skill). Default is `false`.
- When called: looks up the named skill, toggles its activation in `SkillActivations`, fires the appropriate `onActivate` / `onDeactivate` callback, and returns the skill's prompt body (for prompt skills) or a short success message (for instructions skills).

### `SkillsBuilder` — declarative skill list

`SkillsBuilder` is the result builder used inside `Skills { ... }`. It supports single skills, multiple skills, optional values, `if` / `else`, and `for`-`in` loops. There is no `Optional` flag in the API — the builder accepts a `Skill?` directly.

```swift
Skills(activations: activations) {
  Skill(name: "always-on", description: "...", prompt: "...")

  if userOptedIntoCalendaring {
    Skill(name: "calendaring", description: "...", instructions: "...")
  }

  for tag in dynamicTags {
    Skill(name: tag, description: "Handles \(tag)", prompt: "...")
  }
}
```

You can also call `Skills(activations:toolName:toolDescription:strictSchema:skills:)` with an `[Skill]` array if your skills come from runtime data.

### `onActivate` / `onDeactivate` callbacks

Both initializers take a `@Sendable` closure that fires when the model toggles the skill. Use this to drive UI, log analytics, or kick off side effects (e.g. requesting a permission the skill needs). Prompt skills get `onActivate` only. Instructions skills get both, and `onDeactivate` fires only when `allowsDeactivation: true`.

## History — keeping the transcript inside the context window

Three modifiers on `LanguageModelSession.DynamicProfile`. They run in `onPrompt` (i.e. before each new generation) and rewrite `history` in place.

The README and individual doc comments recommend composing them outside-in:

```swift
Profile {
  Instructions("A helpful assistant.")
  ToggleDarkModeTool()
}
.summarizeHistory(entryThreshold: 50, model: summarizerModel)
.rollingWindow(entries: 10)
.droppingCompletedToolCalls()
```

Order matters: modifiers are applied **outside-in**, so the outermost call (`droppingCompletedToolCalls()` above) runs first, then the rolling window, then summarization. Lighter compression first means heavier compression sees a smaller transcript.

### `droppingCompletedToolCalls()`

Removes every `.toolCalls` and `.toolOutput` entry from the transcript **except the most recent pair**. It does this by finding the index of the last `.response` or `.toolCalls` entry, filtering out tool-call/tool-output entries from the prefix before that index, and leaving the suffix from that index onward intact.

Use when long-running conversations accumulate tool-call exchanges that no longer add useful context. Combines especially well with deactivatable instructions skills — once a skill is deactivated, both the activation and deactivation tool calls become eligible to drop.

### `rollingWindow(entries:)`

Keeps only the last `entries` transcript entries via `history.suffix(size)`. Simple, predictable, and cheap. Use when you want a hard cap on transcript size and don't need any reasoning preserved across the cut.

### `summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)`

When `history.count > entryThreshold`, runs a separate `LanguageModelSession` against `model` to compress the entire prior conversation into a third-person summary, then replaces the transcript with a single prompt entry whose first segment is the summary followed by the user's most recent prompt. The summarization is gated on the trailing entry being a `.prompt` — if it isn't (e.g. the modifier ran mid-tool-call), summarization is a no-op for that turn.

```swift
public func summarizeHistory<Model: LanguageModel>(
  entryThreshold: Int,
  model: Model = SystemLanguageModel(),
  instructions: Instructions? = nil,
  summaryPostamble: String? = nil
) -> some DynamicProfile
```

| Parameter | Notes |
|---|---|
| `entryThreshold` | The number of transcript entries above which summarization runs. Compared against `history.count`, not token count. |
| `model` | The summarizer. Defaults to `SystemLanguageModel()`. Use a small, fast model — summarization runs on every prompt once the threshold is crossed, so its latency is on the user-facing critical path. |
| `instructions` | Custom instructions for the summarizer. Default: a built-in prompt that asks for compact third-person statements covering established facts, current topic, the most-recent thread, and unresolved items. |
| `summaryPostamble` | Text appended after the summary. Default: a postamble forbidding meta-phrases like "Based on the context", "Based on the summary", etc., so the downstream model doesn't leak that summarization happened. Pass `""` to omit. |

The summary is given to the summarizer as a role-tagged plain-text rendering of the prior transcript via the package's internal `chatLog()` extension on `Sequence<Transcript.Entry>`.

> Note: as of writing the `entryThreshold` parameter compares to entry count, not token count; the README example wording suggesting otherwise (e.g. "exceeds 5000 tokens") is aspirational. See the disabled / known-issue test in `SummarizeHistoryTests.swift`.

## Composing all three

A typical chat agent uses everything at once: a chat-completions backend, JIT skills, and history compression.

```swift
struct AgentProfile: LanguageModelSession.DynamicProfile {
  let assistant: Assistant

  var body: some DynamicProfile {
    Profile {
      Instructions("A conversation between a user and a helpful assistant.")

      Skills(activations: assistant.activations) {
        Skill(
          name: "style-guide",
          description: "Applies the project's writing style guide",
          prompt: "# Style Guide\n…"
        )
      }
    }
    .summarizeHistory(entryThreshold: 50, model: SystemLanguageModel())
    .rollingWindow(entries: 20)
    .droppingCompletedToolCalls()
  }
}

let model = ChatCompletionsLanguageModel(
  name: "my-model",
  url: URL(string: "https://api.example.com/v1")!,
  additionalHeaders: ["Authorization": "Bearer \(apiKey)"]
)

let session = LanguageModelSession(profile: AgentProfile(assistant: assistant).model(model))
let response = try await session.respond(to: userPrompt)
```

## Pitfalls

- **`supportsGuidedGeneration: true` is the default.** If your server doesn't support `response_format`, set it to `false` explicitly — otherwise the framework will let `respond(to:generating:)` calls through and you'll get whatever free-form output the server produces.
- **`additionalHeaders` overrides defaults.** Setting `Content-Type` or `User-Agent` here replaces the package's default for that header. Usually you only want to *add* an `Authorization` header.
- **Base URL handling is "include `/v1` or don't".** If the base URL contains `v1` in any path component, the executor appends `/chat/completions`. Otherwise it appends `/v1/chat/completions`. Pass the base of your endpoint without the `/chat/completions` suffix.
- **A `Skills` activation produces a tool call in the transcript.** Even prompt-based skills generate a tool-call/tool-output pair. Pair with `droppingCompletedToolCalls()` if these are noise for your model.
- **Instructions-based skills invalidate the KV cache.** Reach for them only when the body really must persist across turns; otherwise prefer prompt-based skills.
- **`SkillActivations` is a reference type and `Sendable`.** Hold one per "session-equivalent" — usually on your `@Observable` model. Don't recreate it on every render or you'll lose the activation state and break observation.
- **History modifiers run outside-in.** Apply summarization first in source order so it ends up innermost; cheaper modifiers go last (they apply first at runtime).
- **`summarizeHistory` thresholds on entry count.** If you expect long, low-entry-count chats with big segments, the threshold may never trip. Add a `rollingWindow` for a token-bounded fallback.
- **`summarizeHistory` requires the trailing entry to be `.prompt`.** It is a no-op for any other trailing entry kind — don't rely on it firing mid-tool-call.

## Package layout

```
FoundationModelsUtilities/
├── Package.swift
├── README.md
├── Sources/
│   └── FoundationModelsUtilities/
│       ├── Documentation.docc/Documentation.md
│       ├── LanguageModels/
│       │   └── ChatCompletionsLanguageModel.swift
│       ├── Skills/
│       │   ├── Skill.swift
│       │   ├── Skills.swift
│       │   ├── SkillActivations.swift
│       │   └── SkillBuilder.swift
│       └── History/
│           ├── DropCompletedToolCalls.swift
│           ├── RollingWindow.swift
│           ├── SummarizeHistory.swift
│           └── TranscriptRendering.swift
└── Tests/
    ├── FoundationModelsUtilitiesTests/   # unit tests
    └── FoundationModelsUtilitiesEvaluations/  # eval-driven tests for summarization
```

The source files are gated by `#if ChatCompletions`, `#if Skills`, and `#if History` — if your app disables traits in `Package.swift`, the corresponding APIs disappear at compile time.
