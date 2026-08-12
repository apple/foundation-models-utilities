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
import Foundation
import FoundationModels
import Synchronization



struct MockModel: LanguageModel {
  typealias Executor = MockModelExecutor

  /// An output the mock model produces on a single generation turn. Listed in
  /// the order the model should emit them across turns: a `.toolCall` is
  /// followed by a continuation turn once its output returns, so a sequence
  /// that calls a tool should end with a `.text` response.
  enum Event: Hashable {
    case toolCall(name: String, arguments: String)
    case text(String)
  }

  let events: [Event]
  let tokenCount: Int
  let recorder: TranscriptRecorder?

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.toolCalling])
  }

  var executorConfiguration: MockModelExecutor.Configuration {
    MockModelExecutor.Configuration(events: events, tokenCount: tokenCount, recorder: recorder)
  }

  /// A model that responds with a single text response.
  init(textResponse: String, tokenCount: Int, recorder: TranscriptRecorder? = nil) {
    self.events = [.text(textResponse)]
    self.tokenCount = tokenCount
    self.recorder = recorder
  }

  /// A model that emits `events` in order, one per generation turn. The event
  /// for each turn is chosen by counting how many turns have already been
  /// taken for the current prompt, so the sequence restarts on every prompt.
  init(events: [Event], tokenCount: Int, recorder: TranscriptRecorder? = nil) {
    self.events = events
    self.tokenCount = tokenCount
    self.recorder = recorder
  }
}

struct MockModelExecutor: LanguageModelExecutor {
  struct Configuration: Hashable {
    var events: [MockModel.Event]
    var tokenCount: Int
    var recorder: TranscriptRecorder?
  }

  let events: [MockModel.Event]
  let tokenCount: Int
  let recorder: TranscriptRecorder?

  init(configuration: Configuration) throws {
    self.events = configuration.events
    self.tokenCount = configuration.tokenCount
    self.recorder = configuration.recorder
  }

  nonisolated func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: MockModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    recorder?.record(request.transcript)
    switch event(for: request.transcript) {
    case .toolCall(let name, let arguments):
      await channel.send(
        .toolCalls(
          entryID: UUID().uuidString,
          action: .toolCall(
            id: UUID().uuidString,
            name: name,
            action: .appendArguments(arguments, tokenCount: tokenCount)
          )
        )
      )
    case .text(let text):
      let entryID = UUID().uuidString
      await channel.send(
        .response(
          entryID: entryID,
          action: .appendText(text, tokenCount: tokenCount)
        )
      )
      await channel.send(
        .response(
          entryID: entryID,
          action: .updateUsage(
            input: .init(totalTokenCount: tokenCount, cachedTokenCount: 0),
            output: .init(totalTokenCount: tokenCount, reasoningTokenCount: 0)
          )
        )
      )
    }
  }

  /// The event to emit for this turn: the number of model-generated entries
  /// (tool calls and responses) since the last prompt indexes into `events`,
  /// clamped to the final event so a sequence ending in `.text` always
  /// terminates.
  private func event(for transcript: Transcript) -> MockModel.Event {
    var index = 0
    for entry in transcript {
      switch entry {
      case .prompt:
        index = 0
      case .toolCalls, .response, .reasoning:
        index += 1
      default:
        break
      }
    }
    return events[min(index, events.count - 1)]
  }
}

/// A thread-safe recorder for the transcripts a mock model observes on each
/// generation turn. Since history modifiers built on `historyTransform` do not
/// mutate the session's persisted transcript, tests can attach a recorder to
/// the mock model and assert against the transcript the model actually saw for
/// a given turn.
final class TranscriptRecorder: Sendable, Hashable {
  private let _transcripts = Mutex<[Transcript]>([])

  var transcripts: [Transcript] {
    _transcripts.withLock { $0 }
  }

  func record(_ transcript: Transcript) {
    _transcripts.withLock { $0.append(transcript) }
  }

  static func == (lhs: TranscriptRecorder, rhs: TranscriptRecorder) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}
