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

/// A structural summary of a transcript entry: its kind plus the content
/// that matters for these assertions (prompt/response text).
enum EntrySummary: Equatable {
  case prompt(String)
  case response(String)
  case toolCall(String)
  case toolOutput(String)
  case reasoning
  case instructions
}

extension Transcript {
  var summary: [EntrySummary] {
    map(\.summary)
  }
}

extension Transcript.Entry {
  var summary: EntrySummary {
    switch self {
    case .prompt(let prompt):
      return .prompt(prompt.segments.text)
    case .response(let response):
      return .response(response.segments.text)
    case .toolCalls(let calls):
      return .toolCall(calls.map(\.toolName).joined(separator: ", "))
    case .toolOutput(let output):
      return .toolOutput(output.segments.text)
    case .reasoning:
      return .reasoning
    case .instructions:
      return .instructions
    @unknown default:
      fatalError("Unknown transcript entry")
    }
  }
}

extension [Transcript.Segment] {
  /// The joined text content of `segments`, ignoring non-text segments.
  fileprivate var text: String {
    compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined()
  }
}
