<h1>
  <img alt="Apple Foundation Models framework logo" src="./assets/fm-icon-27.png" width="90" valign="middle">
  &nbsp;Foundation Models framework utilities
</h1>

## Overview

This package adds extra utilities for working with LLMs via the [Foundation Models framework](https://developer.apple.com/documentation/FoundationModels), such as custom skills, context management helpers, and a chat completions client that connects to a hosted model of your choice.

- 💻 **Supported platforms**: Apple platforms and select Linux distributions like Ubuntu
- 🛠️ **Coding agent skills**: [`skills/`](skills/) can teach your favorite coding agent how to use this package
- 💬 **Issue reporting**: [Apple Developer Forums](https://developer.apple.com/forums/topics/machine-learning-and-ai/machine-learning-and-ai-foundation-models)

## Use the Package

**Xcode** (Apple platforms)

1. From the Xcode menu bar, choose File > Add Package Dependencies.
2. Enter the package URL: https://github.com/apple/foundation-models-utilities.
3. Xcode downloads the package assets.

**Swift Package Manager** (all supported platforms)

Add as a dependency to your Swift package `Package.swift` file like this:

```swift
let package = Package(
    name: "YourApp",
    dependencies: [
        .package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0-beta6")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities")
            ]
        )
    ]
)
```

## Key Features

### ChatCompletionsLanguageModel

The `ChatCompletionsLanguageModel` can communicate with any server that uses the chat completions REST API.

```swift
let model = ChatCompletionsLanguageModel(
  name: "minimax-m2.5",
  url: URL(string: "http://localhost:8000/v1")!,
)

let session = LanguageModelSession(model: model)

let response = try await session.respond(to: "How many folds does it take to make a paper crane?")

print(response.content)
```

When initializing the model, you can specify some of its capabilities based on the server you're connecting to. Some local LLM servers don't support guided generation, for example.

```swift
let model = ChatCompletionsLanguageModel(
  name: "minimax-m2.5",
  url: URL(string: "http://localhost:8000/v1")!,
  supportsGuidedGeneration: false
)
```

The `ChatCompletionsLanguageModel` is especially useful for integrating with a large ecosystem of open source utilities built around the chat completions protocol.

### History Management

This package also contains a collection of profile modifiers to help you compress a session's transcript and prevent it from outgrowing the model's context window. Strategies include dropping completed tool calls, establishing a rolling window, and summarizing previous interactions into a single entry. There's no one-size-fits-all solution, so we encourage composing strategies together to suit your specific application.

This example combines three history management modifiers. Modifiers apply in outside-in order: first, the profile drops completed tool calls, then applies a rolling window. Summarization runs only if the rolling window of 10 entries exceeds 5000 tokens.

```swift
struct MyProfile: LanguageModelSession.DynamicProfile {
  let status: Status

  var body: some DynamicProfile {
    Profile {
      Instructions("A conversation between a user and a helpful assistant.")
      ToggleDarkModeTool()
    }
    .summarizeHistory(entryThreshold: 10, model: status.summarizerModel)
    .rollingWindow(entries: 10)
    .droppingCompletedToolCalls()
  }
}
```

### Skills

`Skills` allow adding extra directions about performing specific tasks into a `LanguageModelSession` transcript on a just-in-time basis. This prevents context pollution and helps optimize time-to-first-token.

The `Skills` type conforms to `DynamicInstructions` and is initialized using a result builder. You must provide a `SkillActivations` instance that tracks which skills are currently active. Because `SkillActivations` conforms to `Observable`, you can use it to drive UI updates.

```swift
@Observable
class Assistant {
  var activations = SkillActivations()
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
          prompt: """
            # Style Guide

            ## Keep phrasing literal
            Idioms and figurative phrases can add color, but they slow
            down readers who are scanning, learning the language, or
            translating the text. Prefer literal phrasing that names
            what you mean, and reserve metaphor for places where it
            genuinely earns its keep.

            ...(continued)
            """
        )

        Skill(
          name: "calendaring",
          description: "Read and modify the user's calendar",
          instructions: """
            Unless specified otherwise, all work meetings
            should start 5 minutes after the hour
            """
        )
      }
    }
  }
}
```

A `Skill` can be initialized with a `prompt` string (or a trailing `@PromptBuilder`) or with an `instructions` string. The initializer you choose affects where the additional content is added to the transcript.

In both cases, the model activates a skill by generating a tool call.

When initialized with a prompt, a skill's content is added into the transcript as part of a matching tool output. This has the advantage of not invalidating the key-value cache.

```
         Before                         After
┌───────────────────────┐      ┌───────────────────────┐
│     Instructions      │      │     Instructions      │
│      (original)       │      │      (original)       │
├───────────────────────┤      ├───────────────────────┤
│        Prompt         │      │        Prompt         │
└───────────────────────┘      ├───────────────────────┤
                               │      Tool Call        │
                               │  (activate: skill_a)  │
                               ├───────────────────────┤
                               │     Tool Output       │
                               │   (skill_a content)   │
                               ├───────────────────────┤
                               │       Response        │
                               └───────────────────────┘
```

When initialized with instructions, a skill's content is inserted at the end of the first instructions entry in the transcript. Models are typically trained to obey instructions with high priority, but doing so often comes at the cost of a key-value cache invalidation.

```
            Before                                  After
┌────────────────────────────────┐      ┌────────────────────────────────┐
│          Instructions          │      │          Instructions          │
│           (original)           │      │  (original + skill_a content)  │
├────────────────────────────────┤      ├────────────────────────────────┤
│             Prompt             │      │             Prompt             │
└────────────────────────────────┘      ├────────────────────────────────┤
                                        │           Tool Call            │
                                        │       (activate: skill_a)      │
                                        ├────────────────────────────────┤
                                        │           Tool Output          │
                                        │    (skill activated message)   │
                                        ├────────────────────────────────┤
                                        │            Response            │
                                        └────────────────────────────────┘
```

Instructions-based skills can optionally be deactivated by the model after activation. Pass `allowsDeactivation: true` to enable this.

```swift
Skill(
  name: "calendaring",
  description: "Read and modify the user's calendar",
  instructions: """
    Unless specified otherwise, all work meetings
    should start 5 minutes after the hour
    """,
  allowsDeactivation: true
)
```

The model may now issue a second tool call to remove the skill's content from its instructions. This can be a powerful tool for combating context pollution, especially when combined with history transformations that remove complete tool calls.

```
            Before                                  After                 Dropping Completed Tool Calls
┌────────────────────────────────┐  ┌────────────────────────────────┐  ┌────────────────────────────────┐
│          Instructions          │  │          Instructions          │  │          Instructions          │
│  (original + skill_a content)  │  │           (original)           │  │           (original)           │
├────────────────────────────────┤  ├────────────────────────────────┤  ├────────────────────────────────┤
│             Prompt             │  │             Prompt             │  │             Prompt             │
├────────────────────────────────┤  ├────────────────────────────────┤  ├────────────────────────────────┤
│           Tool Call            │  │           Tool Call            │  │            Response            │
│       (activate: skill_a)      │  │       (activate: skill_a)      │  ├────────────────────────────────┤
├────────────────────────────────┤  ├────────────────────────────────┤  │             Prompt             │
│           Tool Output          │  │           Tool Output          │  ├────────────────────────────────┤
│    (skill activated message)   │  │    (skill activated message)   │  │            Response            │
├────────────────────────────────┤  ├────────────────────────────────┤  └────────────────────────────────┘
│            Response            │  │            Response            │
└────────────────────────────────┘  ├────────────────────────────────┤
                                    │             Prompt             │
                                    ├────────────────────────────────┤
                                    │           Tool Call            │
                                    │     (deactivate: skill_a)      │
                                    ├────────────────────────────────┤
                                    │           Tool Output          │
                                    │  (skill deactivated message)   │
                                    ├────────────────────────────────┤
                                    │            Response            │
                                    └────────────────────────────────┘
```
