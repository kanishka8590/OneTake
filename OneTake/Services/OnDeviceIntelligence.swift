import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
nonisolated struct GroundedCastingExtraction: Sendable {
    @Guide(description: "Exact project or production title explicitly stated in the notice, or null if absent.")
    var project: String?
    @Guide(description: "Exact role or character breakdown sought, or null if absent.")
    var role: String?
    @Guide(description: "Concise grounded role requirements copied or condensed from the notice, or null if absent.")
    var roleDescription: String?
    @Guide(description: "Exact explicit submission deadline date/time string from the notice, or null if absent.")
    var dueDate: String?
    @Guide(description: "Submission email address for sending applications, preferring submission email over general agency email, or null if absent.")
    var submissionEmail: String?
}
#endif

/// On-device neural notice refinement adapted from `OneTake-iOS-main`'s `OnDeviceIntelligence`.
/// Priority order (Option A Hybrid):
/// 1. Tier 1: Core ML Seq2Seq / ANE parser (`CoreMLParserRunner`) when weights are bundled.
/// 2. Tier 2: Apple Intelligence `FoundationModels` (`@Generable`) on iOS 26+ if any core field remains missing.
/// Every neural field is source-grounded against the OCR/notice text and only fills gaps
/// left open by prior tiers.
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
        guard !trimmed.isEmpty, hasMissingCoreFields(parsed) else { return parsed }

        var updated = parsed
        let snippet = String(trimmed.prefix(2800))

        // Tier 1: Core ML Parser Runner (100% offline, iOS 18+ all devices >= 2.5 GB RAM)
        if await CoreMLParserRunner.shared.isAvailable {
            defer { Task { await CoreMLParserRunner.shared.unloadModel() } }
            let system = """
            You are OneTake's audition notice parser.
            Extract the casting details from the provided text into JSON:
            {"project": "Title", "role": "Target Character", "role_description": null, "due_date": null, "submission_email": null}
            Output valid JSON only.
            """
            if let rawOutput = await CoreMLParserRunner.shared.generate(systemPrompt: system, userPrompt: snippet),
               let tier1Fields = parseModelOutput(rawOutput, sourceText: trimmed) {
                updated = apply(tier1Fields, to: updated, sourceText: trimmed)
            }
        }

        // Tier 2: Apple Intelligence FoundationModels (@Generable) semantic rescue for any remaining gaps
        if hasMissingCoreFields(updated),
           let tier2Fields = await extractWithFoundationModels(from: snippet, fullSourceText: trimmed) {
            updated = apply(tier2Fields, to: updated, sourceText: trimmed)
        }

        return updated
    }

    static func hasMissingCoreFields(_ parsed: ParsedCastingCall) -> Bool {
        let needsProject = parsed.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || parsed.projectName == "Untitled Audition"
        let needsRole = parsed.roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || parsed.roleName == "Lead Character"
        let needsEmail = parsed.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsDeadline = !parsed.hasDetectedDeadline
        return needsProject || needsRole || needsEmail || needsDeadline
    }

    static func apply(_ fields: GroundedNoticeFields, to parsed: ParsedCastingCall, sourceText: String) -> ParsedCastingCall {
        var updated = parsed
        let needsProject = updated.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || updated.projectName == "Untitled Audition"
        let needsRole = updated.roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || updated.roleName == "Lead Character"
        let needsEmail = updated.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsDeadline = !updated.hasDetectedDeadline

        if needsProject, let project = fields.projectName, isGroundedNoticeValue(project, in: sourceText) {
            updated.projectName = project
        }
        if needsRole, let role = fields.roleName, isGroundedNoticeValue(role, in: sourceText) {
            updated.roleName = role
        }
        if updated.roleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let desc = fields.roleDescription,
           isGroundedNoticeValue(desc, in: sourceText) {
            updated.roleDescription = desc
        }
        if needsEmail, let email = fields.recipientEmail, isGroundedNoticeValue(email, in: sourceText) {
            updated.recipientEmail = email
        }
        if needsDeadline, let date = fields.deadline {
            updated.deadline = date
            updated.hasDetectedDeadline = true
        }
        return updated
    }

    static func parseModelOutput(_ raw: String, sourceText: String) -> GroundedNoticeFields? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), let jsonFields = parseJSONFields(from: trimmed, sourceText: sourceText) {
            return jsonFields
        }
        return parsePlainLines(trimmed, sourceText: sourceText)
    }

    private static func extractWithFoundationModels(
        from snippet: String,
        fullSourceText: String
    ) async -> GroundedNoticeFields? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let prompt = """
            Extract ONLY explicitly stated casting notice values from the text below. Return nil for any field not explicitly present.

            Text:
            \(snippet)
            """
            do {
                let session = LanguageModelSession(
                    instructions: "Extract only grounded, explicitly present casting fields. Never invent missing dates, titles, or emails."
                )
                let response = try await session.respond(to: prompt, generating: GroundedCastingExtraction.self)
                let extracted = response.content
                var fields = GroundedNoticeFields()
                fields.projectName = normalizedField(extracted.project)
                fields.roleName = normalizedField(extracted.role)
                fields.roleDescription = normalizedField(extracted.roleDescription)
                if let email = normalizedField(extracted.submissionEmail), email.contains("@") {
                    fields.recipientEmail = email
                }
                if let due = normalizedField(extracted.dueDate),
                   isGroundedNoticeValue(due, in: fullSourceText),
                   let date = CastingCallParserService.shared.parseUserDeadlineInput(due) {
                    fields.deadline = date
                }
                return fields
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static func normalizedField(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if cleaned.isEmpty || lower == "none" || lower == "null" || lower == "n/a" || lower == "nil" {
            return nil
        }
        return cleaned
    }

    static func parseJSONFields(from jsonString: String, sourceText: String) -> GroundedNoticeFields? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var fields = GroundedNoticeFields()
        fields.projectName = normalizedField(json["project"] as? String)
        fields.roleName = normalizedField(json["role"] as? String)
        fields.roleDescription = normalizedField(json["role_description"] as? String)
        if let email = normalizedField(json["submission_email"] as? String), email.contains("@") {
            fields.recipientEmail = email
        }
        if let due = normalizedField(json["due_date"] as? String),
           isGroundedNoticeValue(due, in: sourceText),
           let date = CastingCallParserService.shared.parseUserDeadlineInput(due) {
            fields.deadline = date
        }
        return fields
    }

    static func parsePlainLines(_ answer: String, sourceText: String) -> GroundedNoticeFields? {
        guard !answer.isEmpty else { return nil }
        var fields = GroundedNoticeFields()
        var matchedAnyLine = false

        for rawLine in answer.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let rawValue = String(trimmed[trimmed.index(after: colonIdx)...])
            let val = normalizedField(rawValue)

            switch key {
            case "PROJECT":
                matchedAnyLine = true
                fields.projectName = val
            case "ROLE":
                matchedAnyLine = true
                fields.roleName = val
            case "DESC", "DESCRIPTION", "ROLE_DESCRIPTION":
                matchedAnyLine = true
                fields.roleDescription = val
            case "EMAIL", "SUBMISSION_EMAIL":
                matchedAnyLine = true
                if let val, val.contains("@") {
                    fields.recipientEmail = val
                }
            case "DEADLINE", "DUE_DATE":
                matchedAnyLine = true
                if let val,
                   isGroundedNoticeValue(val, in: sourceText),
                   let date = CastingCallParserService.shared.parseUserDeadlineInput(val) {
                    fields.deadline = date
                }
            default:
                break
            }
        }
        return matchedAnyLine ? fields : nil
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
