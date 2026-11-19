import CoreML
import NaturalLanguage
import XCTest
@testable import OneTake

final class CoreMLModelsTests: XCTestCase {

    func testBundledHeadshotPoseClassifierLoadsWithUpdatedAuthor() throws {
        let compiledURL = Bundle.main.url(forResource: "HeadshotPoseClassifier", withExtension: "mlmodelc")
        XCTAssertNotNil(compiledURL, "HeadshotPoseClassifier.mlmodelc should be compiled into OneTake.app bundle")

        if let compiledURL {
            let model = try MLModel(contentsOf: compiledURL)
            XCTAssertEqual(model.modelDescription.metadata[.author] as? String, "Porage-Lover <jitund05@gmail.com>")
        }
    }

    func testBundledScriptElementClassifierLoadsWithUpdatedAuthor() throws {
        let compiledURL = Bundle.main.url(forResource: "ScriptElementClassifier", withExtension: "mlmodelc")
        XCTAssertNotNil(compiledURL, "ScriptElementClassifier.mlmodelc should be compiled into OneTake.app bundle")

        if let compiledURL {
            let mlModel = try MLModel(contentsOf: compiledURL)
            XCTAssertEqual(mlModel.modelDescription.metadata[.author] as? String, "Porage-Lover <jitund05@gmail.com>")

            let nlModel = try NLModel(contentsOf: compiledURL)
            let label = nlModel.predictedLabel(for: "INT. PRECINCT CORRIDOR - NIGHT")
            XCTAssertNotNil(label)
        }
    }

    func testBundledOneTakeParserANELoadsWithUpdatedAuthor() throws {
        let compiledURL = Bundle.main.url(forResource: "OneTakeParserEncoder", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "OneTakeParserANE", withExtension: "mlmodelc")
        XCTAssertNotNil(compiledURL, "Seq2Seq Core ML parser should be compiled into OneTake.app bundle")

        if let compiledURL {
            let infoPlistURL = compiledURL.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: infoPlistURL),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let author = arr.first?["metadataOutputVersion"] != nil ? (arr.first?["author"] as? String) : nil {
                XCTAssertEqual(author, "Porage-Lover <jitund05@gmail.com>")
                return
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: compiledURL, configuration: config)
            XCTAssertEqual(model.modelDescription.metadata[.author] as? String, "Porage-Lover <jitund05@gmail.com>")
        }
    }

    func testUnigramTokenizerLoadsFullVocabAndRoundTripsUTF8() throws {
        let tokenizer = UnigramTokenizer.shared
        XCTAssertTrue(tokenizer.hasFullVocab, "sp_vocab.json must be bundled and loaded")

        let sample = "PROJECT: MCCC - KOSHISHE\nROLE: Male Lead\nEMAIL: abhinav@mcc.in"
        let encoded = tokenizer.encode(text: sample, appendEOS: true)
        XCTAssertEqual(encoded.last, tokenizer.eosTokenID)
        XCTAssertEqual(tokenizer.decode(tokens: encoded), sample)
        tokenizer.unload()
    }

    func testUnigramTokenizerMatchesPythonGoldenParityVectors() throws {
        let bundle = Bundle(for: CoreMLModelsTests.self)
        guard let url = bundle.url(forResource: "golden_parity_vectors", withExtension: "json")
            ?? bundle.url(forResource: "golden_parity_vectors", withExtension: "json", subdirectory: "TestFixtures") else {
            // Fall back to source-relative TestFixtures path when running locally in Xcode
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("TestFixtures/golden_parity_vectors.json")
            let data = try Data(contentsOf: fixtureURL)
            try assertGoldenParity(data: data)
            return
        }
        let data = try Data(contentsOf: url)
        try assertGoldenParity(data: data)
    }

    private func assertGoldenParity(data: Data) throws {
        struct Vector: Decodable {
            let text: String
            let ids: [Int]
        }
        let vectors = try JSONDecoder().decode([Vector].self, from: data)
        XCTAssertEqual(vectors.count, 20)
        let tokenizer = UnigramTokenizer.shared
        for (idx, vec) in vectors.enumerated() {
            let swiftIDs = tokenizer.encode(text: vec.text, appendEOS: true)
            XCTAssertEqual(swiftIDs, vec.ids, "Parity mismatch at golden vector #\(idx)")
        }
        tokenizer.unload()
    }

    func testCoreMLParserRunnerExtractsStructuredCastingJSON() async throws {
        let hasAsset = await CoreMLParserRunner.shared.hasBundledModelAsset
        XCTAssertTrue(hasAsset, "CoreMLParserRunner should discover bundled Seq2Seq parser")
        #if !targetEnvironment(simulator)
        guard CoreMLParserRunner.supportsInProcessParserModel else {
            let available = await CoreMLParserRunner.shared.isAvailable
            XCTAssertFalse(available)
            return
        }
        #endif

        let notice = """
        CASTING CALL
        MCCC - KOSHISHE
        Role: Male Lead for an upcoming Hindi theatrical feature film
        Submission Deadline: 15 December, 2026
        Email to Apply: abhinav@mcc.in
        """

        let start = Date()
        let raw = await CoreMLParserRunner.shared.generate(
            userPrompt: notice,
            maxNewTokens: 96,
            allowSimulator: true
        )
        let elapsed = Date().timeIntervalSince(start)
        await CoreMLParserRunner.shared.unloadModel()

        let outputString = try XCTUnwrap(raw, "CoreMLParserRunner should return tagged output (elapsed \(String(format: "%.2f", elapsed))s)")
        let fields = try XCTUnwrap(OnDeviceIntelligence.parseModelOutput(outputString, sourceText: notice), "Failed to parse: \(outputString)")
        let project = try XCTUnwrap(fields.projectName, "Missing project in: \(outputString)")
        XCTAssertTrue(
            project.localizedCaseInsensitiveContains("MCCC") || project.localizedCaseInsensitiveContains("KOSHISHE"),
            "Unexpected project in: \(outputString)"
        )
        XCTAssertEqual(fields.roleName, "Male Lead", "Unexpected role in: \(outputString)")
        XCTAssertNotNil(fields.deadline, "Missing deadline in: \(outputString)")
        XCTAssertEqual(fields.recipientEmail, "abhinav@mcc.in", "Unexpected email in: \(outputString)")
    }

    // MARK: - Task 4: UnigramTokenizer Tests

    func testUnigramTokenizerViterbiAndUTF8ByteFallback() {
        var pieces: [(piece: String, score: Double)] = [
            ("<pad>", 0.0),
            ("</s>", 0.0),
            ("<unk>", 0.0)
        ]
        for byte in 0...255 {
            pieces.append((String(format: "<0x%02X>", byte), -20.0))
        }
        pieces.append(contentsOf: [
            (piece: "\u{2581}", score: -2.5),
            (piece: "\u{2581}PROJECT", score: -1.5),
            (piece: ":", score: -1.0),
            (piece: "\u{2581}Male", score: -1.8),
            (piece: "\u{2581}Lead", score: -1.9)
        ])

        let tokenizer = UnigramTokenizer(pieces: pieces)
        let sample = "PROJECT: Male Lead \u{2013} \u{20B9}5000 हिन्दी\nabhinav@mcc.in"
        let encoded = tokenizer.encode(text: sample, appendEOS: true)
        XCTAssertEqual(encoded.last, tokenizer.eosTokenID)
        XCTAssertFalse(encoded.contains(tokenizer.unkTokenID), "Byte fallback should eliminate <unk> tokens")
        XCTAssertEqual(tokenizer.decode(tokens: encoded), "PROJECT: Male Lead - Rs.5000 हिन्दी\nabhinav@mcc.in")
    }

    func testUnigramTokenizerUnloadResetsMemoryState() {
        let tokenizer = UnigramTokenizer.shared
        tokenizer.unload()
        XCTAssertFalse(tokenizer.isLoadedInMemory)
    }

    // MARK: - Task 5: OnDeviceIntelligence 3-Tier & Tagged Line Tests

    func testOnDeviceIntelligenceParsePlainLinesExtractsDescAndHandlesNoneAndColons() {
        let source = """
        CASTING CALL
        MCCC - KOSHISHE
        Role: Male Lead
        Details: 20-25 yrs, Hindi & English: Lead
        Email to Apply: abhinav@mcc.in
        """
        let output = """
        PROJECT: MCCC - KOSHISHE
        ROLE: Male Lead
        DESC: 20-25 yrs, Hindi & English: Lead
        DEADLINE: NONE
        EMAIL: abhinav@mcc.in
        """

        let fields = OnDeviceIntelligence.parseModelOutput(output, sourceText: source)
        XCTAssertEqual(fields?.projectName, "MCCC - KOSHISHE")
        XCTAssertEqual(fields?.roleName, "Male Lead")
        XCTAssertEqual(fields?.roleDescription, "20-25 yrs, Hindi & English: Lead")
        XCTAssertNil(fields?.deadline)
        XCTAssertEqual(fields?.recipientEmail, "abhinav@mcc.in")
    }

    func testOnDeviceIntelligenceApplyPreservesGroundedFieldsAndFillsOnlyMissingOnes() {
        let source = """
        PHOTON - A FEATURE FILM
        Looking for Male Talent aged 22-25 years.
        Deadline: 30 November 2026
        Send to: casting@schoolofdrama.com
        """
        var initial = ParsedCastingCall()
        initial.projectName = "PHOTON"
        initial.roleName = "Lead Character" // default placeholder -> needs rescue
        initial.recipientEmail = ""         // empty -> needs rescue

        let tier1 = OnDeviceIntelligence.GroundedNoticeFields(
            projectName: "SHOULD_NOT_OVERWRITE",
            roleName: "Male Talent",
            roleDescription: "aged 22-25 years",
            recipientEmail: nil,
            deadline: nil
        )
        let afterTier1 = OnDeviceIntelligence.apply(tier1, to: initial, sourceText: source)
        XCTAssertEqual(afterTier1.projectName, "PHOTON")
        XCTAssertEqual(afterTier1.roleName, "Male Talent")
        XCTAssertEqual(afterTier1.roleDescription, "aged 22-25 years")
        XCTAssertEqual(afterTier1.recipientEmail, "")
        XCTAssertFalse(afterTier1.hasDetectedDeadline)

        let tier2 = OnDeviceIntelligence.GroundedNoticeFields(
            projectName: "Ignored Project",
            roleName: "Ignored Role",
            roleDescription: "Ignored Desc",
            recipientEmail: "casting@schoolofdrama.com",
            deadline: CastingCallParserService.shared.parseUserDeadlineInput("30 November 2026")
        )
        let afterTier2 = OnDeviceIntelligence.apply(tier2, to: afterTier1, sourceText: source)
        XCTAssertEqual(afterTier2.projectName, "PHOTON")
        XCTAssertEqual(afterTier2.roleName, "Male Talent")
        XCTAssertEqual(afterTier2.roleDescription, "aged 22-25 years")
        XCTAssertEqual(afterTier2.recipientEmail, "casting@schoolofdrama.com")
        XCTAssertTrue(afterTier2.hasDetectedDeadline)
    }

    // MARK: - Task 6: CoreMLParserRunner Seq2Seq & RAM Gate Tests

    func testCoreMLParserRunnerSeq2SeqMemoryFloorAndPromptFormatting() {
        XCTAssertEqual(CoreMLParserRunner.minimumSeq2SeqPhysicalMemoryBytes, 2_500_000_000)
        let formatted = CoreMLParserRunner.seq2SeqInputPrompt(for: "CASTING CALL\nPHOTON")
        XCTAssertEqual(formatted, "parse audition notice:\nCASTING CALL\nPHOTON")
    }
}
