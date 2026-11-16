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
}
