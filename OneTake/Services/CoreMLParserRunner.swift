import CoreML
import Foundation

/// Native Swift Core ML Runner for on-device Apple Neural Engine (ANE) inference.
/// Ported from OneTake-iOS-main; automatically picks up `OneTakeParser` / `OneTakeParserANE`
/// / `needle3-onetake-cq2` `.mlmodelc` or `.mlpackage` if bundled in the app.
actor CoreMLParserRunner {
    static let shared = CoreMLParserRunner()

    private var model: MLModel?
    private let tokenizer = BPETokenizer.shared
    private let modelResourceNames = ["OneTakeParser", "OneTakeParserANE", "needle3-onetake-cq2"]

    var isAvailable: Bool {
        for name in modelResourceNames {
            if Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil {
                return true
            }
            if Bundle.main.url(forResource: name, withExtension: "mlpackage") != nil {
                return true
            }
        }
        return false
    }

    func loadModelIfNeeded() throws {
        guard model == nil else { return }

        var targetURL: URL? = nil
        for name in modelResourceNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                targetURL = url
                break
            }
            if let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage"),
               let compiled = try? MLModel.compileModel(at: packageURL) {
                targetURL = compiled
                break
            }
        }

        guard let modelURL = targetURL else {
            throw NSError(
                domain: "CoreMLParserRunner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Compiled Core ML parser model asset not found in bundle."]
            )
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        config.allowLowPrecisionAccumulationOnGPU = true

        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    func generate(
        systemPrompt: String = "You are OneTake's audition notice parser. Output valid JSON only.",
        userPrompt: String,
        maxNewTokens: Int = 512,
        grammarConstrained: Bool = true
    ) async -> String? {
        do {
            try loadModelIfNeeded()
        } catch {
            return nil
        }

        guard let model = self.model else { return nil }

        var tokenIDs = tokenizer.applyChatTemplate(system: systemPrompt, user: userPrompt)
        guard !tokenIDs.isEmpty else { return nil }

        var generatedTokens: [Int] = []
        var openBraceCount = 0
        var hasStartedJSON = false

        for _ in 0..<maxNewTokens {
            let currentSeqLen = tokenIDs.count
            guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: currentSeqLen)], dataType: .int32) else {
                break
            }

            for (idx, val) in tokenIDs.enumerated() {
                inputArray[idx] = NSNumber(value: val)
            }

            let inputFeature = DictionaryFeatureProvider(values: ["input_ids": MLFeatureValue(multiArray: inputArray)])

            guard let output = try? await model.prediction(from: inputFeature),
                  let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                break
            }

            let nextTokenID = selectNextToken(
                from: logits,
                seqLen: currentSeqLen,
                isFirstToken: generatedTokens.isEmpty && grammarConstrained
            )
            if nextTokenID == tokenizer.eosTokenID || nextTokenID == tokenizer.imEndTokenID {
                break
            }

            generatedTokens.append(nextTokenID)
            tokenIDs.append(nextTokenID)

            if grammarConstrained {
                let tokenStr = tokenizer.decode(tokens: [nextTokenID])
                for char in tokenStr {
                    if char == "{" || char == "[" {
                        openBraceCount += 1
                        hasStartedJSON = true
                    } else if char == "}" || char == "]" {
                        openBraceCount -= 1
                    }
                }

                if hasStartedJSON && openBraceCount <= 0 {
                    break
                }
            }
        }

        let result = tokenizer.decode(tokens: generatedTokens).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func selectNextToken(from logits: MLMultiArray, seqLen: Int, isFirstToken: Bool) -> Int {
        if isFirstToken {
            return 90
        }

        var maxIndex = 0
        var maxVal = -Float.greatestFiniteMagnitude

        let vocabSize = logits.shape.last?.intValue ?? 151645
        let baseOffset = (seqLen - 1) * vocabSize
        let inspectLimit = min(vocabSize, 151645)

        if logits.dataType == .float16 {
            let ptr = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)
            let offsetPtr = ptr.advanced(by: baseOffset)
            for i in 0..<inspectLimit {
                let val = Float(offsetPtr[i])
                if val > maxVal {
                    maxVal = val
                    maxIndex = i
                }
            }
            return maxIndex
        } else if logits.dataType == .float32 {
            let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
            let offsetPtr = ptr.advanced(by: baseOffset)
            for i in 0..<inspectLimit {
                let val = offsetPtr[i]
                if val > maxVal {
                    maxVal = val
                    maxIndex = i
                }
            }
            return maxIndex
        }

        for i in 0..<inspectLimit {
            let score = logits[baseOffset + i].floatValue
            if score > maxVal {
                maxVal = score
                maxIndex = i
            }
        }

        return maxIndex
    }

    func unloadModel() {
        self.model = nil
    }
}

nonisolated private final class DictionaryFeatureProvider: MLFeatureProvider, @unchecked Sendable {
    let values: [String: MLFeatureValue]
    var featureNames: Set<String> { Set(values.keys) }
    init(values: [String: MLFeatureValue]) { self.values = values }
    func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}
