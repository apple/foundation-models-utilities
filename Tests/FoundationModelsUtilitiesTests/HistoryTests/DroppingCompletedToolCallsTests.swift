//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
@testable import FoundationModelsUtilities
import FoundationModels
import Testing

@Suite
struct DroppingCompletedToolCallsTests {
  /// A model that calls the skill-activation tool on its first turn, then
  /// responds with text once the tool output returns.
  private func toolCallingModel(recorder: TranscriptRecorder) -> MockModel {
    MockModel(
      events: [
        .toolCall(name: "activate_skill", arguments: #"{"skill":"echo"}"#),
        .text("OK")
      ],
      tokenCount: 1,
      recorder: recorder
    )
  }

  @Test func `keeps an incomplete tool-call exchange`() async throws {
    let recorder = TranscriptRecorder()
    let model = toolCallingModel(recorder: recorder)
    let session = LanguageModelSession(profile: DropToolCallsProfile().model(model))

    let _ = try await session.respond(to: "first")

    // The tool call/output for this prompt are not followed by a later prompt,
    // so they are still "incomplete" and are preserved in the transcript the
    // model sees on its final turn.
    #expect(
      recorder.transcripts.last?.summary == [
        .instructions,
        .prompt("first"),
        .toolCall("activate_skill"),
        .toolOutput("echoed")
      ]
    )
  }

  @Test func `drops the completed tool-call exchange once a new prompt arrives`() async throws {
    let recorder = TranscriptRecorder()
    let model = toolCallingModel(recorder: recorder)
    let session = LanguageModelSession(profile: DropToolCallsProfile().model(model))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")

    // The tool-calling mock produces two model turns per prompt (tool call,
    // then text continuation), so `transcripts[2]` is the first turn of the
    // second prompt — before the second prompt has generated any tool call of
    // its own. By this point the first prompt's completed tool call/output
    // pair is no longer the most recent exchange, so the modifier drops it
    // from the transcript the model sees.
    #expect(
      recorder.transcripts[2].summary == [
        .instructions,
        .prompt("first"),
        .response("OK"),
        .prompt("second")
      ]
    )
  }
}

private struct DropToolCallsProfile: LanguageModelSession.DynamicProfile {
  var body: some DynamicProfile {
    Profile {
      Skills(activations: SkillActivations()) {
        Skill(name: "echo", description: "Echoes input", prompt: "echoed")
      }
    }
    .droppingCompletedToolCalls()
  }
}
