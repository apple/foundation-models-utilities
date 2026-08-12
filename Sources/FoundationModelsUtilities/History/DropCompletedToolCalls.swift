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
public import FoundationModels

extension LanguageModelSession.DynamicProfile {
  /// Returns a modified profile that removes completed tool-call and
  /// tool-output entries from the transcript before each generation.
  ///
  /// Tool calls that have already been fulfilled add bulk to the
  /// transcript and are not always useful context for future responses.
  /// This modifier strips them out, keeping only the most recent
  /// tool-call exchange and all non-tool entries.
  ///
  /// It composes well with other history modifiers. For example, applying
  /// it outermost ensures tool-call entries are cleaned up before a
  /// rolling window or summarization step runs:
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("A helpful assistant.")
  /// }
  /// .summarizeHistory(entryThreshold: 50, model: model)
  /// .rollingWindow(entries: 10)
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Returns: A profile that prunes completed tool-call entries from its
  ///   transcript before each generation.
  public func droppingCompletedToolCalls() -> some DynamicProfile {
    modifier(DropCompletedToolCallsModifier())
  }
}

private struct DropCompletedToolCallsModifier: LanguageModelSession.DynamicProfileModifier {
  func body(content: Content) -> some DynamicProfile {
    content.historyTransform { history in
      let lastOutputIndex =
        history.lastIndex(where: { entry in
          if case .response = entry { return true }
          if case .toolCalls = entry { return true }
          return false
        }) ?? history.startIndex

      let prefix = history.prefix(upTo: lastOutputIndex).filter { entry in
        if case .toolCalls = entry { return false }
        if case .toolOutput = entry { return false }
        return true
      }

      let suffix = history.suffix(from: lastOutputIndex)

      return prefix + suffix
    }
  }
}
