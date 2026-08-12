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
import Foundation
import Testing
import Synchronization

@Suite
struct SkillsTests {
  @Test func `prompt skill activation`() async throws {
    let model = SkillsMockModel(activatingSkill: "foo")
    let session = LanguageModelSession(profile: ActivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    let toolCalls = session.transcript.compactMap(\.toolCalls).first
    let toolOutput = session.transcript.compactMap(\.toolOutput).first
    #expect(toolCalls?.first?.toolName == "activate_skill")
    #expect(toolOutput?.segments.first?.text == "foo prompt")
  }

  @Test func `prompt skill renders as on demand`() async throws {
    // A prompt skill has no persistent active state, so the instructions list
    // it as on-demand whether or not the model has invoked it.
    let model = SkillsMockModel(activatingSkill: "foo")
    let session = LanguageModelSession(profile: ActivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    let instructionsText = session.transcript.first?.instructions?
      .segments.compactMap(\.text).joined(separator: "\n")
    #expect(instructionsText?.contains("Skill: foo [on demand]") == true)
    #expect(instructionsText?.contains("foo [inactive]") == false)
    #expect(instructionsText?.contains("foo [active]") == false)
  }

  @Test func `prompt skill is not tracked as active`() async throws {
    // Invoking a prompt skill injects its content as tool output; it should
    // not be recorded as an active skill in `SkillActivations`.
    let activations = SkillActivations()
    let model = SkillsMockModel(activatingSkill: "foo")
    let session = LanguageModelSession(
      profile: ActivatableProfile(activations: activations).model(model)
    )
    let _ = try await session.respond(to: "...")
    #expect(!activations.isActive("foo"))
  }

  @Test func `instructions skill activation reports activated`() async throws {
    let model = SkillsMockModel(activatingSkill: "bar")
    let session = LanguageModelSession(profile: ActivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    let toolOutput = session.transcript.compactMap(\.toolOutput).first
    #expect(toolOutput?.segments.compactMap(\.text).joined() == "Successfully activated skill: bar")
  }

  @Test func `instructions skill deactivation reports deactivated`() async throws {
    let model = SkillsMockModel(toolName: "toggle_skill", activatingSkill: "baz")
    let session = LanguageModelSession(profile: DeactivatableProfile().model(model))
    let _ = try await session.respond(to: "...")  // Activates skill
    let _ = try await session.respond(to: "...")  // Deactivates skill
    let toolOutputs = session.transcript.compactMap(\.toolOutput)
    #expect(
      toolOutputs.first?.segments.compactMap(\.text).joined() == "Successfully activated skill: baz"
    )
    #expect(
      toolOutputs.last?.segments.compactMap(\.text).joined()
        == "Successfully deactivated skill: baz"
    )
  }

  @Test func `instructions skill activation`() async throws {
    let model = SkillsMockModel(activatingSkill: "bar")
    let session = LanguageModelSession(profile: ActivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    let toolCalls = session.transcript.compactMap(\.toolCalls).first
    let instructions = session.transcript.first?.instructions
    #expect(toolCalls?.first?.toolName == "activate_skill")
    let instructionsText = instructions?.segments.compactMap(\.text).joined(separator: "\n")
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: foo [on demand]
        Description: foo description

        Skill: bar [active]
        bar instructions
        """
    )
  }

  @Test func `dynamic instructions builder skill activation`() async throws {
    let model = SkillsMockModel(activatingSkill: "qux")
    let session = LanguageModelSession(profile: DynamicInstructionsBuilderProfile().model(model))
    let _ = try await session.respond(to: "...")
    let transcript = session.transcript
    let toolCalls = transcript.compactMap(\.toolCalls).first
    let instructions = transcript.first?.instructions
    #expect(toolCalls?.first?.toolName == "activate_skill")
    let instructionsText = instructions?.segments.compactMap(\.text).joined(separator: "\n")
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: qux [active]
        first line
        second line
        """
    )
  }

  @Test func `custom tool name is used`() async throws {
    let toolName = "use_skill"
    let model = SkillsMockModel(toolName: toolName, activatingSkill: "foo")
    let profile = ActivatableProfile(toolName: toolName).model(model)
    let session = LanguageModelSession(profile: profile)
    let _ = try await session.respond(to: "...")
    let toolCalls = session.transcript.compactMap(\.toolCalls).first
    #expect(toolCalls?.first?.toolName == toolName)
  }

  @Test func `default tool name is toggle_skill when deactivation allowed`() async throws {
    let model = SkillsMockModel(toolName: "toggle_skill", activatingSkill: "baz")
    let session = LanguageModelSession(profile: DeactivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    let toolCalls = session.transcript.compactMap(\.toolCalls).first
    #expect(toolCalls?.first?.toolName == "toggle_skill")
  }

  // MARK: - Tool description branches

  @Test
  func `default description is activates a skill when no deactivation and no on demand skill`()
    async throws
  {
    // allowsDeactivation == false, hasOnDemandSkill == false
    let model = SkillsMockModel(activatingSkill: "solo")
    let session = LanguageModelSession(profile: ActivationOnlyProfile().model(model))
    let _ = try await session.respond(to: "...")
    #expect(
      toggleToolDescription(session) == """
        Activate a skill yourself when the user's request matches its description, \
        and otherwise respond normally without calling this tool. Don't ask the \
        user for permission to activate, and don't mention activation in your response.
        """
    )
  }

  @Test func `default description mentions on demand skills when one is present`() async throws {
    // allowsDeactivation == false, hasOnDemandSkill == true
    let model = SkillsMockModel(activatingSkill: "bar")
    let session = LanguageModelSession(profile: ActivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    #expect(
      toggleToolDescription(session) == """
        Activate a skill yourself when the user's request matches its description, \
        and otherwise respond normally without calling this tool. Don't ask the \
        user for permission to activate, and don't mention activation in your response. \
        Skills marked [on demand] aren't toggled on or off; \
        calling this tool on one delivers its guidance once.
        """
    )
  }

  @Test func `default description allows deactivation when a skill permits it`() async throws {
    // allowsDeactivation == true, hasOnDemandSkill == false
    let model = SkillsMockModel(toolName: "toggle_skill", activatingSkill: "baz")
    let session = LanguageModelSession(profile: DeactivatableProfile().model(model))
    let _ = try await session.respond(to: "...")
    #expect(
      toggleToolDescription(session) == """
        Activate or deactivate a skill yourself when the user's request matches its \
        description, and otherwise respond normally without calling this tool. Don't \
        ask the user for permission to activate, and don't mention activation in your response.
        """
    )
  }

  @Test func `default description allows deactivation and mentions on demand when both present`()
    async throws
  {
    // allowsDeactivation == true, hasOnDemandSkill == true
    let model = SkillsMockModel(toolName: "toggle_skill", activatingSkill: "toggle")
    let session = LanguageModelSession(profile: OnDemandToggleProfile().model(model))
    let _ = try await session.respond(to: "...")
    #expect(
      toggleToolDescription(session) == """
        Activate or deactivate a skill yourself when the user's request matches its \
        description, and otherwise respond normally without calling this tool. Don't \
        ask the user for permission to activate, and don't mention activation in your response. \
        Skills marked [on demand] aren't toggled on or off; \
        calling this tool on one delivers its guidance once.
        """
    )
  }

  @Test func `custom tool description overrides the default`() async throws {
    let model = SkillsMockModel(activatingSkill: "solo")
    let session = LanguageModelSession(
      profile: ActivationOnlyProfile(toolDescription: "Pick a skill to use.").model(model)
    )
    let _ = try await session.respond(to: "...")
    #expect(toggleToolDescription(session) == "Pick a skill to use.")
  }

  @Test func `custom instructions override the default leading text`() async throws {
    let instructionsText = try await renderSkillsInstructions(
      instructions: Instructions("Custom lead-in for skills.")
    ) {
      Skill(name: "alpha", description: "alpha description", instructions: "alpha instructions")
    }
    #expect(
      instructionsText == """
        Custom lead-in for skills.

        Skill: alpha [inactive]
        Description: alpha description
        """
    )
  }

  @Test func `onActivate callback fires for prompt skill`() async throws {
    let activated = Mutex(false)
    let onActivate: @Sendable () -> Void = { activated.withLock({ $0 = true }) }
    let model = SkillsMockModel(activatingSkill: "foo")
    let profile = ActivatableProfile(onActivate: { onActivate() }).model(model)
    let session = LanguageModelSession(profile: profile)
    let _ = try await session.respond(to: "...")
    let didFire = activated.withLock({ $0 })
    #expect(didFire)
  }

  @Test func `onActivate callback fires for instructions skill`() async throws {
    let activated = Mutex(false)
    let onActivate: @Sendable () -> Void = { activated.withLock({ $0 = true }) }
    let model = SkillsMockModel(activatingSkill: "bar")
    let profile = ActivatableProfile(onActivate: { onActivate() }).model(model)
    let session = LanguageModelSession(profile: profile)
    let _ = try await session.respond(to: "...")
    let didFire = activated.withLock({ $0 })
    #expect(didFire)
  }

  @Test func `onDeactivate callback fires for instructions skill`() async throws {
    let activated = Mutex(true)
    let onDeactivate: @Sendable () -> Void = { activated.withLock({ $0 = false }) }
    let model = SkillsMockModel(toolName: "toggle_skill", activatingSkill: "baz")
    let profile = DeactivatableProfile(onDeactivate: { onDeactivate() }).model(model)
    let session = LanguageModelSession(profile: profile)
    let _ = try await session.respond(to: "...")  // Activates skill
    let _ = try await session.respond(to: "...")  // Deactivates skill
    let didFire = activated.withLock({ !$0 })
    #expect(didFire)
  }

  // MARK: - Multi-skill rendering

  @Test func `multiple inactive skills are separated by a single newline`() async throws {
    let instructionsText = try await renderSkillsInstructions {
      Skill(name: "alpha", description: "alpha description", instructions: "alpha instructions")
      Skill(name: "beta", description: "beta description", instructions: "beta instructions")
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [inactive]
        Description: alpha description

        Skill: beta [inactive]
        Description: beta description
        """
    )
  }

  @Test func `multiple on demand skills are separated by a single newline`() async throws {
    let instructionsText = try await renderSkillsInstructions {
      Skill(name: "alpha", description: "alpha description", prompt: "alpha prompt")
      Skill(name: "beta", description: "beta description", prompt: "beta prompt")
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [on demand]
        Description: alpha description

        Skill: beta [on demand]
        Description: beta description
        """
    )
  }

  @Test func `active instructions skill is separated from the next skill by a newline`()
    async throws
  {
    let activations = SkillActivations()
    activations.activate("alpha")
    activations.activate("beta")
    let instructionsText = try await renderSkillsInstructions(activations: activations) {
      Skill(name: "alpha", description: "alpha description", instructions: "alpha instructions")
      Skill(name: "beta", description: "beta description", instructions: "beta instructions")
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [active]
        alpha instructions

        Skill: beta [active]
        beta instructions
        """
    )
  }

  @Test
  func `active instructions skill before on demand skill is separated by a newline`() async throws {
    let activations = SkillActivations()
    activations.activate("alpha")
    let instructionsText = try await renderSkillsInstructions(activations: activations) {
      Skill(name: "alpha", description: "alpha description", instructions: "alpha instructions")
      Skill(name: "beta", description: "beta description", prompt: "beta prompt")
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [active]
        alpha instructions

        Skill: beta [on demand]
        Description: beta description
        """
    )
  }

  @Test
  func `active builder skills are separated by a newline`() async throws {
    let activations = SkillActivations()
    activations.activate("alpha")
    activations.activate("beta")
    let instructionsText = try await renderSkillsInstructions(activations: activations) {
      Skill(name: "alpha", description: "alpha description") {
        Instructions {
          "alpha line one"
          "alpha line two"
        }
      }
      Skill(name: "beta", description: "beta description") {
        Instructions {
          "beta line one"
          "beta line two"
        }
      }
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [active]
        alpha line one
        alpha line two

        Skill: beta [active]
        beta line one
        beta line two
        """
    )
  }

  @Test
  func `active builder skill with a tool renders no tool text and is separated by a newline`()
    async throws
  {
    // Tools attached via the @DynamicInstructionsBuilder closure become
    // available to the model but contribute no text to the instructions
    // entry, so the rendered output should only show the skill's
    // Instructions content.
    let activations = SkillActivations()
    activations.activate("alpha")
    let instructionsText = try await renderSkillsInstructions(activations: activations) {
      Skill(name: "alpha", description: "alpha description") {
        Instructions("alpha instructions")
        NoopTool()
      }
      Skill(name: "beta", description: "beta description", instructions: "beta instructions")
    }
    #expect(
      instructionsText == """
        If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.

        Skill: alpha [active]
        alpha instructions

        Skill: beta [inactive]
        Description: beta description
        """
    )
  }
}

// MARK: - Multi-skill rendering helpers

/// Renders the instructions produced by a `Skills` container with the given
/// skills, by attaching them to a session and reading the materialized
/// instructions out of the transcript.
private func renderSkillsInstructions(
  activations: SkillActivations = SkillActivations(),
  instructions: Instructions? = nil,
  @SkillsBuilder skills: () -> [Skill]
) async throws -> String? {
  let model = MockModel(textResponse: "ok", tokenCount: 1)
  let profile = MultiSkillProfile(
    activations: activations,
    instructions: instructions,
    skills: skills()
  ).model(model)
  let session = LanguageModelSession(profile: profile)
  let _ = try await session.respond(to: "...")
  return session.transcript.first?.instructions?.segments.compactMap(\.text).joined(separator: "\n")
}

private struct MultiSkillProfile: LanguageModelSession.DynamicProfile {
  let activations: SkillActivations
  let instructions: Instructions?
  let skills: [Skill]

  var body: some DynamicProfile {
    Profile {
      Skills(activations: activations, instructions: instructions, skills: skills)
    }
  }
}

/// A minimal tool used to verify that tools attached to a builder-based skill
/// don't appear in the rendered instructions text.
private struct NoopTool: Tool {
  let name = "noop"
  let description = "Does nothing."

  @Generable
  struct Arguments {}

  func call(arguments: Arguments) async throws -> String { "" }
}

// MARK: - Profiles

private struct ActivatableProfile: LanguageModelSession.DynamicProfile {
  let toolName: String?
  let activations: SkillActivations
  let onActivate: @Sendable () -> Void

  init(
    toolName: String? = nil,
    activations: SkillActivations = SkillActivations(),
    onActivate: @Sendable @escaping () -> Void = {}
  ) {
    self.toolName = toolName
    self.activations = activations
    self.onActivate = onActivate
  }

  var body: some DynamicProfile {
    Profile {
      Skills(activations: activations, toolName: toolName) {
        Skill(
          name: "foo",
          description: "foo description",
          prompt: "foo prompt",
          onActivate: onActivate
        )
        Skill(
          name: "bar",
          description: "bar description",
          instructions: "bar instructions",
          onActivate: onActivate
        )
      }
    }
  }
}

private struct DeactivatableProfile: LanguageModelSession.DynamicProfile {
  let activations: SkillActivations
  let onDeactivate: @Sendable () -> Void

  init(
    activations: SkillActivations = SkillActivations(),
    onDeactivate: @Sendable @escaping () -> Void = {}
  ) {
    self.activations = activations
    self.onDeactivate = onDeactivate
  }

  var body: some DynamicProfile {
    Profile {
      Skills(activations: activations) {
        Skill(
          name: "baz",
          description: "baz description",
          instructions: "baz instructions",
          allowsDeactivation: true,
          onDeactivate: onDeactivate
        )
      }
    }
  }
}

private struct DynamicInstructionsBuilderProfile: LanguageModelSession.DynamicProfile {
  let activations: SkillActivations

  init(activations: SkillActivations = SkillActivations()) {
    self.activations = activations
  }

  var body: some DynamicProfile {
    Profile {
      Skills(activations: activations) {
        Skill(name: "qux", description: "qux description") {
          Instructions {
            "first line"
            "second line"
          }
        }
      }
    }
  }
}

/// A single instructions-based skill that can't be deactivated and no
/// on-demand skill, so the toggle tool's default description is the simplest
/// "Activates a skill." form. Accepts a custom description to exercise the
/// override path.
private struct ActivationOnlyProfile: LanguageModelSession.DynamicProfile {
  let toolDescription: String?

  init(toolDescription: String? = nil) {
    self.toolDescription = toolDescription
  }

  var body: some DynamicProfile {
    Profile {
      Skills(activations: SkillActivations(), toolDescription: toolDescription) {
        Skill(name: "solo", description: "solo description", instructions: "solo instructions")
      }
    }
  }
}

/// A prompt (on-demand) skill alongside a deactivatable instructions skill, so
/// both `allowsDeactivation` and `hasOnDemandSkill` are true and the toggle
/// tool's description includes the on-demand explanation.
private struct OnDemandToggleProfile: LanguageModelSession.DynamicProfile {
  let activations: SkillActivations

  init(activations: SkillActivations = SkillActivations()) {
    self.activations = activations
  }

  var body: some DynamicProfile {
    Profile {
      Skills(activations: activations) {
        Skill(name: "demand", description: "demand description", prompt: "demand prompt")
        Skill(
          name: "toggle",
          description: "toggle description",
          instructions: "toggle instructions",
          allowsDeactivation: true
        )
      }
    }
  }
}

// MARK: - Mock Model

private struct SkillsMockModel: LanguageModel {
  typealias Executor = SkillsMockModelExecutor

  let toolName: String
  let activatingSkill: String

  init(toolName: String? = nil, activatingSkill: String) {
    self.toolName = toolName ?? "activate_skill"
    self.activatingSkill = activatingSkill
  }

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.toolCalling])
  }

  var executorConfiguration: SkillsMockModelExecutor.Configuration {
    SkillsMockModelExecutor.Configuration(
      toolName: toolName,
      activatingSkill: activatingSkill
    )
  }
}

private struct SkillsMockModelExecutor: LanguageModelExecutor {
  struct Configuration: Hashable {
    var toolName: String
    var activatingSkill: String
  }

  let toolName: String
  let activatingSkill: String

  init(configuration: Configuration) throws {
    self.toolName = configuration.toolName
    self.activatingSkill = configuration.activatingSkill
  }

  nonisolated func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: SkillsMockModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    if case .toolOutput = request.transcript.last {
      await channel.send(
        .response(
          entryID: UUID().uuidString,
          action: .appendText("Success", tokenCount: 1)
        )
      )
    } else {
      await channel.send(
        .toolCalls(
          entryID: UUID().uuidString,
          action: .toolCall(
            id: UUID().uuidString,
            name: toolName,
            action: .appendArguments(
              "{\"skill\":\"\(activatingSkill)\"}",
              tokenCount: 1
            )
          )
        )
      )
    }
  }
}

// MARK: - Transcript Helpers

/// The description of the toggle tool, read from the tool definitions surfaced
/// in the transcript's instructions. The profiles in this suite bundle no
/// per-skill tools, so the toggle tool is the only tool definition present.
private func toggleToolDescription(_ session: LanguageModelSession) -> String? {
  session.transcript
    .compactMap(\.instructions)
    .flatMap(\.toolDefinitions)
    .first?
    .description
}

extension Transcript.Entry {
  fileprivate var instructions: Transcript.Instructions? {
    if case .instructions(let instructions) = self { return instructions }
    return nil
  }
}

extension Transcript.Segment {
  fileprivate var text: String? {
    if case .text(let text) = self { return text.content }
    return nil
  }
}
