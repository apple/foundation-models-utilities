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
  /// Returns a modified profile that keeps only the most recent transcript
  /// entries, discarding older ones each time a new prompt is sent.
  ///
  /// Use this modifier to bound transcript growth by maintaining a
  /// fixed-size sliding window over the conversation history. It
  /// composes well with other history modifiers — for example, applying
  /// ``droppingCompletedToolCalls()`` before a rolling window ensures that
  /// stale tool-call entries are removed first.
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("You are a helpful assistant.")
  /// }
  /// .rollingWindow(entries: 10)
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Parameter entries: The maximum number of transcript entries to
  ///   retain. Older entries beyond this count are dropped.
  /// - Returns: A profile that trims its transcript to the specified window
  ///   size before each generation.
  public func rollingWindow(entries: Int) -> some DynamicProfile {
    rollingWindow(size: .entries(entries))
  }

  /// Returns a modified profile that keeps only the most recent transcript
  /// entries, discarding older ones each time a new prompt is sent.
  ///
  /// Use this modifier to bound transcript growth by maintaining a sliding
  /// window over the conversation history. Unlike the similar ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(entries:)``  which sets the window to a fixed int number of entries,
  /// this modifier uses ``RollingWindowSize`` which allows you to choose
  /// between different strategies for measuring the window's size.
  ///
  /// It composes well with other history modifiers — for example, applying
  /// ``droppingCompletedToolCalls()`` before a rolling window ensures that
  /// stale tool-call entries are removed first.
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("You are a helpful assistant.")
  /// }
  /// .rollingWindow(size: .entries(10))
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Parameter size: The size of the rolling window as determined the
  /// ``RollingWindowSize`` strategy.
  /// - Returns: A profile that trims its transcript to the specified window
  ///   size before each generation.
  public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile {
    modifier(RollingWindowModifier(size: size))
  }
}

private struct RollingWindowModifier: LanguageModelSession.DynamicProfileModifier {
  let size: RollingWindowSize

  func body(content: Content) -> some DynamicProfile {
    content.historyTransform { history in
      switch size {
      case .entries(let numberOfEntries):
        return Array(history.suffix(numberOfEntries))
      }
    }
  }
}

/// A strategy to determine how the transcript window size is measured.
public enum RollingWindowSize: Sendable {
  /// Retain a fixed number of the _most recent_ entries in the transcript.
  /// If the number of total entries in the transcript is less than this number, all entries are kept.
  case entries(Int)
}
