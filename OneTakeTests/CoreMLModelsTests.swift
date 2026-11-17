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
        let compiledURL = Bundle.main.url(forResource: "OneTakeParserANE", withExtension: "mlmodelc")
        XCTAssertNotNil(compiledURL, "OneTakeParserANE.mlmodelc should be compiled into OneTake.app bundle")

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

    func testBPETokenizerLoadsFullVocabAndRoundTripsUTF8() {
        let tokenizer = BPETokenizer.shared
        XCTAssertTrue(tokenizer.hasFullVocab, "vocab.json and merges.txt must be bundled and loaded")

        let sample = "{\"project\": \"MCCC - KOSHISHE\", \"role_description\": \"20–25 years\\nHindi & English\"}"
        let encoded = tokenizer.encode(text: sample)
        XCTAssertFalse(encoded.isEmpty)
        XCTAssertEqual(tokenizer.decode(tokens: encoded), sample)

        let templated = tokenizer.applyChatTemplate(
            system: "You are OneTake's audition notice parser.",
            user: "PHOTON — Casting Call"
        )
        XCTAssertEqual(templated.first, tokenizer.imStartTokenID)
        XCTAssertEqual(templated.last, tokenizer.encode(text: "assistant\n").last)
        tokenizer.unload()
    }

    func testCoreMLParserRunnerExtractsStructuredCastingJSON() async throws {
        let hasAsset = await CoreMLParserRunner.shared.hasBundledModelAsset
        XCTAssertTrue(hasAsset, "CoreMLParserRunner should discover bundled OneTakeParserANE")
        #if !targetEnvironment(simulator)
        guard CoreMLParserRunner.supportsInProcessParserModel else {
            let available = await CoreMLParserRunner.shared.isAvailable
            XCTAssertFalse(available, "Low-RAM devices (<=4 GB) must disable in-process 0.5B Core ML to avoid Jetsam OOM")
            return
        }
        #endif

        let system = """
        You are OneTake's audition notice parser.
        Extract the casting details from the provided text into JSON:
        {"project": "Title", "role": "Target Character", "role_description": null, "due_date": null, "submission_email": null}
        Output valid JSON only.
        """
        let notice = """
        CASTING CALL
        MCCC - KOSHISHE
        Role: Male Lead for an upcoming Hindi theatrical feature film
        Submission Deadline: 15 December, 2026
        Email to Apply: abhinav@mcc.in
        """

        let raw = await CoreMLParserRunner.shared.generate(
            systemPrompt: system,
            userPrompt: notice,
            maxNewTokens: 80,
            grammarConstrained: true,
            allowSimulator: true
        )
        await CoreMLParserRunner.shared.unloadModel()

        let jsonString = try XCTUnwrap(raw, "CoreMLParserRunner should return JSON output")
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "Invalid JSON: \(jsonString)")
        let project = try XCTUnwrap(json["project"] as? String, "Missing project in \(jsonString)")
        XCTAssertTrue(
            project.localizedCaseInsensitiveContains("MCCC") || project.localizedCaseInsensitiveContains("KOSHISHE"),
            "Unexpected project in \(jsonString)"
        )
        XCTAssertEqual(json["role"] as? String, "Male Lead", "Unexpected role in \(jsonString)")
        XCTAssertEqual(json["due_date"] as? String, "15 December, 2026", "Unexpected due_date in \(jsonString)")
        XCTAssertEqual(json["submission_email"] as? String, "abhinav@mcc.in", "Unexpected email in \(jsonString)")
    }
}
