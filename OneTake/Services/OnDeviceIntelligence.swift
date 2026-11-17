import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device neural notice refinement adapted from `OneTake-iOS-main`'s `OnDeviceIntelligence`.
/// Priority order:
/// 1. Core ML Needle 3 / ANE parser (`CoreMLParserRunner`) when weights are bundled.
/// 2. Apple Intelligence `FoundationModels` (`SystemLanguageModel`) on iOS 26+.
/// Every neural field is source-grounded against the OCR/notice text and only fills gaps
/// left open by the deterministic parser.
nonisolated enum OnDeviceIntelligence {
    struct GroundedNoticeFields: Sendable {
        var projectName: String?
        var roleName: String?
        var roleDescription: String?
        var recipientEmail: String?
        var deadline: Date?
    }

    static func refineParsedCall(_ parsed: ParsedCastingCall, sourceText: String) async -> ParsedCastingCall {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return parsed }

        let needsProject = parsed.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || parsed.projectName == "Untitled Audition"
        let needsRole = parsed.roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || parsed.roleName == "Lead Character"
        let needsEmail = parsed.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsDeadline = !parsed.hasDetectedDeadline

        guard needsProject || needsRole || needsEmail || needsDeadline else {
            return parsed
        }

        guard let neural = await extractGroundedFields(from: trimmed) else {
            return parsed
        }

        var updated = parsed
        if needsProject, let project = neural.projectName, isGroundedNoticeValue(project, in: trimmed) {
            updated.projectName = project
        }
        if needsRole, let role = neural.roleName, isGroundedNoticeValue(role, in: trimmed) {
            updated.roleName = role
        }
        if updated.roleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let desc = neural.roleDescription,
           isGroundedNoticeValue(desc, in: trimmed) {
            updated.roleDescription = desc
        }
        if needsEmail, let email = neural.recipientEmail, isGroundedNoticeValue(email, in: trimmed) {
            updated.recipientEmail = email
        }
        if needsDeadline, let date = neural.deadline {
            updated.deadline = date
            updated.hasDetectedDeadline = true
        }
        return updated
    }

    private static func extractGroundedFields(from text: String) async -> GroundedNoticeFields? {
        let snippet = String(text.prefix(2800))

        // 1. Core ML Needle 3 / ANE Runner (100% offline when OneTakeParser / needle3 bundle is present)
        if await CoreMLParserRunner.shared.isAvailable {
            defer { Task { await CoreMLParserRunner.shared.unloadModel() } }
            let system = """
            You are OneTake's audition notice parser.
            Extract the casting details from the provided text into JSON:
            {"project": "Title", "role": "Target Character", "role_description": null, "due_date": null, "submission_email": null}
            Output valid JSON only.
            """
            if let jsonString = await CoreMLParserRunner.shared.generate(systemPrompt: system, userPrompt: snippet),
               let fields = parseJSONFields(from: jsonString, sourceText: text) {
                return fields
            }
        }

        // 2. Apple Intelligence FoundationModels (iOS 26+)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let prompt = """
            Extract ONLY explicitly stated casting notice values from the text below into plain lines. Use None if not explicitly present.
            PROJECT: [project title or None]
            ROLE: [character/role name or None]
            DEADLINE: [explicit due date/time or None]
            EMAIL: [submission email or None]

            Text:
            \(snippet)
            """
            do {
                let session = LanguageModelSession(instructions: "Extract only grounded, explicitly present casting fields. Never invent missing fields.")
                let response = try await session.respond(to: prompt)
                let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return parsePlainLines(answer, sourceText: text)
            } catch {
                return nil
            }
        }
        #endif

        return nil
    }

    private static func parseJSONFields(from jsonString: String, sourceText: String) -> GroundedNoticeFields? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var fields = GroundedNoticeFields()
        if let project = (json["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !project.isEmpty, project.lowercased() != "none" {
            fields.projectName = project
        }
        if let role = (json["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !role.isEmpty, role.lowercased() != "none" {
            fields.roleName = role
        }
        if let desc = (json["role_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty, desc.lowercased() != "none" {
            fields.roleDescription = desc
        }
        if let email = (json["submission_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           email.contains("@") {
            fields.recipientEmail = email
        }
        if let due = (json["due_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isGroundedNoticeValue(due, in: sourceText),
           let date = CastingCallParserService.shared.parseUserDeadlineInput(due) {
            fields.deadline = date
        }
        return fields
    }

    private static func parsePlainLines(_ answer: String, sourceText: String) -> GroundedNoticeFields? {
        guard !answer.isEmpty else { return nil }
        var fields = GroundedNoticeFields()
        for rawLine in answer.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("PROJECT:") {
                let val = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val.lowercased() != "none" { fields.projectName = val }
            } else if upper.hasPrefix("ROLE:") {
                let val = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val.lowercased() != "none" { fields.roleName = val }
            } else if upper.hasPrefix("EMAIL:") {
                let val = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if val.contains("@") { fields.recipientEmail = val }
            } else if upper.hasPrefix("DEADLINE:") {
                let val = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val.lowercased() != "none" && isGroundedNoticeValue(val, in: sourceText),
                   let date = CastingCallParserService.shared.parseUserDeadlineInput(val) {
                    fields.deadline = date
                }
            }
        }
        return fields
    }

    static func isGroundedNoticeValue(_ value: String, in source: String) -> Bool {
        let candidate = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.,;:-"))
        guard candidate.count >= 2, candidate.lowercased() != "none" else { return false }
        if source.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        let words = candidate.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return false }
        let normalizedSource = source.lowercased()
        let matches = words.filter { normalizedSource.contains($0) }.count
        return Double(matches) / Double(words.count) >= 0.75
    }

    /// Uses Apple Intelligence `FoundationModels` on iOS 26+ (e.g., iPhone 17 Pro) when available
    /// to resolve which upcoming teleprompter line best matches a paraphrased spoken utterance.
    static func resolveSpokenTeleprompterLine(
        spokenSnippet: String,
        candidateLines: [(index: Int, text: String)]
    ) async -> Int? {
        let trimmed = spokenSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidateLines.isEmpty else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let formattedCandidates = candidateLines
                .prefix(6)
                .map { "\($0.index): \($0.text)" }
                .joined(separator: "\n")
            let prompt = """
            The actor just spoke: "\(trimmed)"
            Which numbered script line below is the actor currently reading? Reply with ONLY the integer line number, or None.
            \(formattedCandidates)
            """
            do {
                let session = LanguageModelSession(instructions: "Output only the matching integer line index or None.")
                let response = try await session.respond(to: prompt)
                let digits = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .joined()
                if let matchedIndex = Int(digits),
                   candidateLines.contains(where: { $0.index == matchedIndex }) {
                    return matchedIndex
                }
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
