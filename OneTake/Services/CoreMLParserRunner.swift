import CoreML
import Foundation

/// Native Swift Core ML Runner for on-device Apple Neural Engine (ANE) inference.
/// Ported from OneTake-iOS-main; automatically picks up `OneTakeParser` / `OneTakeParserANE`
/// / `needle3-onetake-cq2` `.mlmodelc` or `.mlpackage` if bundled in the app.
actor CoreMLParserRunner {
    static let shared = CoreMLParserRunner()

    private var model: MLModel?
    private let tokenizer = BPETokenizer.shared
    private let modelResourceNames = ["OneTakeParserANE", "OneTakeParser", "needle3-onetake-cq2"]
    private let maxContextTokens = 512

    /// Devices with <= 4 GB RAM (e.g., iPhone 11) hit iOS Jetsam limits (~1.4 GB) when compiling
    /// or holding the 0.5B Core ML transformer alongside active camera/UI memory.
    /// On iOS Simulator (which lacks Neural Engine / MPSGraph), default notice parsing skips
    /// CPU-only 0.5B generation unless explicitly requested by `CoreMLModelsTests`.
    nonisolated static var supportsInProcessParserModel: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ProcessInfo.processInfo.physicalMemory >= 5_000_000_000
        #endif
    }

    var isAvailable: Bool {
        guard Self.supportsInProcessParserModel else { return false }
        return hasBundledModelAsset
    }

    var hasBundledModelAsset: Bool {
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

    func loadModelIfNeeded(allowSimulator: Bool = false) throws {
        #if targetEnvironment(simulator)
        let allowed = allowSimulator || Self.supportsInProcessParserModel
        #else
        let allowed = Self.supportsInProcessParserModel
        #endif
        guard allowed else {
            throw NSError(
                domain: "CoreMLParserRunner",
                code: 412,
                userInfo: [NSLocalizedDescriptionKey: "In-process Core ML parser skipped on <=4 GB RAM device to prevent memory termination."]
            )
        }
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
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        config.allowLowPrecisionAccumulationOnGPU = true

        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    func generate(
        systemPrompt: String = "You are OneTake's audition notice parser. Output valid JSON only.",
        userPrompt: String,
        maxNewTokens: Int = 192,
        grammarConstrained: Bool = true,
        allowSimulator: Bool = false
    ) async -> String? {
        do {
            try loadModelIfNeeded(allowSimulator: allowSimulator)
        } catch {
            return nil
        }

        guard let model = self.model else { return nil }
        let inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        let usesExplicitMaskAndPos = inputNames.contains("causal_mask") && inputNames.contains("position_ids")

        let reservedOutputTokens = min(maxNewTokens, 160)
        let maxPromptTokens = max(128, maxContextTokens - reservedOutputTokens)
        var boundedUserPrompt = userPrompt
        var tokenIDs = tokenizer.applyChatTemplate(system: systemPrompt, user: boundedUserPrompt)
        while tokenIDs.count > maxPromptTokens && boundedUserPrompt.count > 120 {
            let keepCount = max(100, (boundedUserPrompt.count * 3) / 4)
            boundedUserPrompt = String(boundedUserPrompt.prefix(keepCount))
            tokenIDs = tokenizer.applyChatTemplate(system: systemPrompt, user: boundedUserPrompt)
        }
        guard !tokenIDs.isEmpty else { return nil }

        var generatedTokens: [Int] = []
        var openBraceCount = 0
        var hasStartedJSON = false

        let effectiveMaxNew = min(maxNewTokens, max(0, maxContextTokens - tokenIDs.count))
        for _ in 0..<effectiveMaxNew {
            let currentSeqLen = tokenIDs.count
            guard currentSeqLen > 0, currentSeqLen <= maxContextTokens else { break }

            let nextTokenID: Int
            if generatedTokens.isEmpty && grammarConstrained {
                nextTokenID = 90 // "{"
            } else {
                guard let inputFeature = makeInputFeatures(
                    tokenIDs: tokenIDs,
                    usesExplicitMaskAndPos: usesExplicitMaskAndPos
                ),
                let output = try? await model.prediction(from: inputFeature),
                let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                    break
                }
                nextTokenID = selectNextToken(
                    from: logits,
                    seqLen: currentSeqLen,
                    isFirstToken: false
                )
            }

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

    private func makeInputFeatures(tokenIDs: [Int], usesExplicitMaskAndPos: Bool) -> MLFeatureProvider? {
        let s = tokenIDs.count
        guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: s)], dataType: .int32) else {
            return nil
        }
        let idStride = inputArray.strides.last?.intValue ?? 1
        let idsPtr = inputArray.dataPointer.bindMemory(to: Int32.self, capacity: inputArray.count)
        for i in 0..<s {
            idsPtr[i * idStride] = Int32(tokenIDs[i])
        }

        guard usesExplicitMaskAndPos else {
            return DictionaryFeatureProvider(values: ["input_ids": MLFeatureValue(multiArray: inputArray)])
        }

        guard let maskArray = try? MLMultiArray(
            shape: [1, 1, NSNumber(value: s), NSNumber(value: s)],
            dataType: .float16
        ),
        let posArray = try? MLMultiArray(
            shape: [1, NSNumber(value: s)],
            dataType: .float16
        ) else {
            return nil
        }

        let maskRowStride = maskArray.strides.count >= 3 ? maskArray.strides[2].intValue : s
        let maskColStride = maskArray.strides.last?.intValue ?? 1
        let maskPtr = maskArray.dataPointer.bindMemory(to: Float16.self, capacity: maskArray.count)
        let negInf = Float16(-10000.0)
        let zero = Float16(0.0)
        for r in 0..<s {
            let rowBase = r * maskRowStride
            for c in 0..<s {
                maskPtr[rowBase + c * maskColStride] = c <= r ? zero : negInf
            }
        }

        let posStride = posArray.strides.last?.intValue ?? 1
        let posPtr = posArray.dataPointer.bindMemory(to: Float16.self, capacity: posArray.count)
        for i in 0..<s {
            posPtr[i * posStride] = Float16(i)
        }

        return DictionaryFeatureProvider(values: [
            "input_ids": MLFeatureValue(multiArray: inputArray),
            "causal_mask": MLFeatureValue(multiArray: maskArray),
            "position_ids": MLFeatureValue(multiArray: posArray)
        ])
    }

    private func selectNextToken(from logits: MLMultiArray, seqLen: Int, isFirstToken: Bool) -> Int {
        if isFirstToken {
            return 90
        }

        var maxIndex = 0
        var maxVal = -Float.greatestFiniteMagnitude

        let vocabSize = logits.shape.last?.intValue ?? 151646
        let outputSeqLen = logits.shape.count >= 2 ? logits.shape[1].intValue : 1
        let seqStride = logits.strides.count >= 2 ? logits.strides[logits.strides.count - 2].intValue : vocabSize
        let baseOffset = max(0, outputSeqLen - 1) * seqStride
        let inspectLimit = min(vocabSize, 151646)

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
        self.tokenizer.unload()
    }
}

nonisolated private final class DictionaryFeatureProvider: MLFeatureProvider, @unchecked Sendable {
    let values: [String: MLFeatureValue]
    var featureNames: Set<String> { Set(values.keys) }
    init(values: [String: MLFeatureValue]) { self.values = values }
    func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}
