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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ChatCompletionsTests {
  @Suite struct RequestFormat {
    init() { MockSSEProtocol.reset() }

    @Test func `sends model name in request body`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel(name: "foo-mini"))
      let _ = try await session.respond(to: "test")

      let body = try requestBody()
      #expect(body["model"] as? String == "foo-mini")
    }

    @Test func `enables streaming in request`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let body = try requestBody()
      #expect(body["stream"] as? Bool == true)
    }

    @Test func `includes messages in request`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel()
      let instructions = Instructions { "Always respond in rhyme" }
      let session = LanguageModelSession(model: model, instructions: instructions)
      let _ = try await session.respond(to: "Hello!")

      let body = try requestBody()
      let messages = body["messages"] as? [[String: Any]]
      #expect(messages != nil)
      #expect((messages?.count ?? 0) >= 2)

      #expect(messages?.first?["role"] as? String == "system")
      #expect(messages?.last?["role"] as? String == "user")
    }

    @Test func `merges custom headers with defaults`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel(
        headers: ["X-Custom": "value", "Authorization": "Bearer key"]
      )
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func `appends chat completions endpoint to base URL`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.url?.path.hasSuffix("/chat/completions") == true)
    }

    @Test func `does not duplicate version when base URL includes v1`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel(url: URL(string: "https://mock-llm.test/v1")!)
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.url?.path == "/v1/chat/completions")
    }

    @Test func `preserves alternate version segments in base URL`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel(url: URL(string: "https://mock-llm.test/api/v3")!)
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.url?.path == "/api/v3/chat/completions")
    }

    @Test func `injects v1 when base URL has no version segment`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel(url: URL(string: "https://mock-llm.test")!)
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.url?.path == "/v1/chat/completions")
    }
  }
}
