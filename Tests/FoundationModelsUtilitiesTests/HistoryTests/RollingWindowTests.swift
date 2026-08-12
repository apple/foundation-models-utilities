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
struct RollingWindowTests {
  @Test func `preserves entries when under limit`() async throws {
    let recorder = TranscriptRecorder()
    let model = MockModel(textResponse: "OK", tokenCount: 1, recorder: recorder)
    let profile = WindowedProfile(windowSize: 10).model(model)
    let session = LanguageModelSession(profile: profile)

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")

    // Window is larger than the transcript, so the model sees the full history
    // on its final turn.
    #expect(
      recorder.transcripts.last?.summary == [
        .instructions,
        .prompt("first"),
        .response("OK"),
        .prompt("second")
      ]
    )
  }

  @Test func `trims to the most recent entries`() async throws {
    let recorder = TranscriptRecorder()
    let model = MockModel(textResponse: "OK", tokenCount: 1, recorder: recorder)
    let profile = WindowedProfile(windowSize: 3).model(model)
    let session = LanguageModelSession(profile: profile)

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")
    let _ = try await session.respond(to: "third")

    // On the third prompt the history exceeds the window of 3, so the model
    // sees only the last three entries — the first prompt/response pair and
    // the instructions are dropped from the transcript sent to the model.
    #expect(
      recorder.transcripts.last?.summary == [
        .prompt("second"),
        .response("OK"),
        .prompt("third")
      ]
    )
  }

  @Test
  func `splits a prompt-response pair when the window is even`() async throws {
    let recorder = TranscriptRecorder()
    let model = MockModel(textResponse: "OK", tokenCount: 1, recorder: recorder)
    let profile = WindowedProfile(windowSize: 2).model(model)
    let session = LanguageModelSession(profile: profile)

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")
    let _ = try await session.respond(to: "third")
    let _ = try await session.respond(to: "fourth")

    // The naive suffix(2) trim cuts between the third prompt's response and
    // the fourth prompt, so the model sees an orphaned response followed by
    // the new prompt.
    #expect(
      recorder.transcripts.last?.summary == [
        .response("OK"),
        .prompt("fourth")
      ]
    )
  }
}

private struct WindowedProfile: LanguageModelSession.DynamicProfile {
  let windowSize: Int

  var body: some DynamicProfile {
    Profile {
      Instructions("You are a helpful assistant.")
    }
    .rollingWindow(entries: windowSize)
  }
}
