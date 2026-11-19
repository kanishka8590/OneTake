import CoreML
import Foundation

/// Native Swift Core ML Runner for the compact Seq2Seq (`Flan-T5-Small` pruned) notice parser.
///
/// Loads `OneTakeParserEncoder` + `OneTakeParserDecoder` (or multi-function `OneTakeParserANE`)
/// using `.all` compute units on iOS 18+ physical devices (`>= 2.5 GB` RAM) and `.cpuOnly` under Simulator.
actor CoreMLParserRunner {
    static let shared = CoreMLParserRunner()

    nonisolated static let minimumSeq2SeqPhysicalMemoryBytes: UInt64 = 2_500_000_000

    private var encoderModel: MLModel?
    private var decoderModel: MLModel?
    private(set) var lastDiagnostic: String?

    private let unigramTokenizer = UnigramTokenizer.shared
    private let maxEncoderContextTokens = 512

    nonisolated static func seq2SeqInputPrompt(for userPrompt: String) -> String {
        "parse audition notice:\n\(userPrompt)"
    }

    /// Seq2Seq ~34.4 MB models stay well under Jetsam ceilings on all 4 GB+ RAM iPhones (iPhone 11+).
    nonisolated static var supportsInProcessParserModel: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ProcessInfo.processInfo.physicalMemory >= minimumSeq2SeqPhysicalMemoryBytes
        #endif
    }

    var isAvailable: Bool {
        guard Self.supportsInProcessParserModel else { return false }
        return hasBundledModelAsset
    }

    var hasBundledModelAsset: Bool {
        let names = ["OneTakeParserEncoder", "OneTakeParserANE"]
        for name in names {
            if Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil
                || Bundle.main.url(forResource: name, withExtension: "mlpackage") != nil {
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
                userInfo: [NSLocalizedDescriptionKey: "In-process Core ML parser skipped on low-RAM device to avoid memory termination."]
            )
        }
        guard encoderModel == nil || decoderModel == nil else { return }

        let baseConfig = { (functionName: String?) -> MLModelConfiguration in
            let config = MLModelConfiguration()
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuOnly
            #else
            config.computeUnits = .all
            #endif
            config.allowLowPrecisionAccumulationOnGPU = true
            config.functionName = functionName
            return config
        }

        // 1. Dedicated Encoder + Decoder packages
        if let encURL = resolveModelURL(named: "OneTakeParserEncoder"),
           let decURL = resolveModelURL(named: "OneTakeParserDecoder") {
            let cfg = baseConfig(nil)
            self.encoderModel = try MLModel(contentsOf: encURL, configuration: cfg)
            self.decoderModel = try MLModel(contentsOf: decURL, configuration: cfg)
            return
        }

        // 2. Multi-Function package ("encode" + "decode")
        guard let aneURL = resolveModelURL(named: "OneTakeParserANE") else {
            throw NSError(
                domain: "CoreMLParserRunner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Compiled Core ML parser model asset not found in bundle."]
            )
        }

        self.encoderModel = try MLModel(contentsOf: aneURL, configuration: baseConfig("encode"))
        self.decoderModel = try MLModel(contentsOf: aneURL, configuration: baseConfig("decode"))
    }

    func generate(
        systemPrompt: String = "You are OneTake's audition notice parser.",
        userPrompt: String,
        maxNewTokens: Int = 96,
        grammarConstrained: Bool = true,
        allowSimulator: Bool = false
    ) async -> String? {
        _ = systemPrompt
        _ = grammarConstrained
        lastDiagnostic = nil
        do {
            try loadModelIfNeeded(allowSimulator: allowSimulator)
        } catch {
            lastDiagnostic = "loadModelIfNeeded failed: \(error)"
            return nil
        }

        guard let encoderModel, let decoderModel else {
            lastDiagnostic = "Seq2Seq encoder/decoder not loaded."
            return nil
        }

        return await generateSeq2Seq(
            encoder: encoderModel,
            decoder: decoderModel,
            userPrompt: userPrompt,
            maxNewTokens: maxNewTokens
        )
    }

    // MARK: - Seq2Seq (Flan-T5 Pruned) Inference

    private func generateSeq2Seq(
        encoder: MLModel,
        decoder: MLModel,
        userPrompt: String,
        maxNewTokens: Int
    ) async -> String? {
        var encoded = unigramTokenizer.encode(
            text: Self.seq2SeqInputPrompt(for: userPrompt),
            appendEOS: true
        )
        if encoded.count > maxEncoderContextTokens {
            encoded = Array(encoded.prefix(maxEncoderContextTokens - 1)) + [unigramTokenizer.eosTokenID]
        }
        guard !encoded.isEmpty else { return nil }

        let seqLen = encoded.count
        guard let encIDs = makeInt32Array(values: encoded, shape: [1, NSNumber(value: seqLen)]),
              let encMask = makeMaskArray(
                  length: seqLen,
                  dataType: encoder.modelDescription.inputDescriptionsByName["attention_mask"]?.multiArrayConstraint?.dataType ?? .int32
              ) else {
            lastDiagnostic = "Failed to allocate encoder input tensors."
            return nil
        }

        let encInput = DictionaryFeatureProvider(values: [
            "input_ids": MLFeatureValue(multiArray: encIDs),
            "attention_mask": MLFeatureValue(multiArray: encMask)
        ])

        let encOutput: MLFeatureProvider
        do {
            encOutput = try await encoder.prediction(from: encInput)
        } catch {
            lastDiagnostic = "encoder prediction failed: \(error)"
            return nil
        }
        guard let hiddenStates = encOutput.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
            lastDiagnostic = "missing encoder_hidden_states output"
            return nil
        }

        let decMaskType = decoder.modelDescription.inputDescriptionsByName["encoder_attention_mask"]?.multiArrayConstraint?.dataType ?? .int32
        let decEncMask = (decMaskType == encMask.dataType) ? encMask : makeMaskArray(length: seqLen, dataType: decMaskType)
        guard let decEncMask else {
            lastDiagnostic = "Failed to allocate decoder attention mask."
            return nil
        }

        var decoderTokens: [Int] = [unigramTokenizer.padTokenID] // T5 decoder_start_token_id = 0
        let stepLimit = min(max(1, maxNewTokens), 96)

        for step in 0..<stepLimit {
            guard let decIDs = makeInt32Array(
                values: decoderTokens,
                shape: [1, NSNumber(value: decoderTokens.count)]
            ) else {
                break
            }

            let decInput = DictionaryFeatureProvider(values: [
                "decoder_input_ids": MLFeatureValue(multiArray: decIDs),
                "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
                "encoder_attention_mask": MLFeatureValue(multiArray: decEncMask)
            ])

            let decOutput: MLFeatureProvider
            do {
                decOutput = try await decoder.prediction(from: decInput)
            } catch {
                lastDiagnostic = "decoder prediction failed at step \(step): \(error)"
                break
            }
            guard let logits = decOutput.featureValue(for: "logits")?.multiArrayValue else {
                lastDiagnostic = "missing logits output"
                break
            }

            let nextToken = selectNextToken(from: logits)
            if nextToken == unigramTokenizer.eosTokenID || nextToken == unigramTokenizer.padTokenID {
                break
            }
            decoderTokens.append(nextToken)
        }

        let generated = Array(decoderTokens.dropFirst())
        guard !generated.isEmpty else {
            if lastDiagnostic == nil { lastDiagnostic = "empty sequence generated" }
            return nil
        }
        let decoded = unigramTokenizer.decode(tokens: generated, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: - Shared Helpers

    private func resolveModelURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        if let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage"),
           let compiled = try? MLModel.compileModel(at: packageURL) {
            return compiled
        }
        return nil
    }

    private func makeInt32Array(values: [Int], shape: [NSNumber]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: shape, dataType: .int32) else { return nil }
        let stride = array.strides.last?.intValue ?? 1
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        for i in 0..<values.count {
            ptr[i * stride] = Int32(values[i])
        }
        return array
    }

    private func makeMaskArray(length: Int, dataType: MLMultiArrayDataType) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: length)], dataType: dataType) else {
            return nil
        }
        let stride = array.strides.last?.intValue ?? 1
        if dataType == .float16 {
            let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0..<length { ptr[i * stride] = 1.0 }
        } else if dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for i in 0..<length { ptr[i * stride] = 1.0 }
        } else {
            let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            for i in 0..<length { ptr[i * stride] = 1 }
        }
        return array
    }

    private func selectNextToken(from logits: MLMultiArray) -> Int {
        var maxIndex = 0
        var maxVal = -Float.greatestFiniteMagnitude

        let vocabSize = logits.shape.last?.intValue ?? 8192
        let outputSeqLen = logits.shape.count >= 2 ? logits.shape[1].intValue : 1
        let seqStride = logits.strides.count >= 2 ? logits.strides[logits.strides.count - 2].intValue : vocabSize
        let colStride = logits.strides.last?.intValue ?? 1
        let baseOffset = max(0, outputSeqLen - 1) * seqStride

        if logits.dataType == .float16 {
            let ptr = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)
            let offsetPtr = ptr.advanced(by: baseOffset)
            for i in 0..<vocabSize {
                let val = Float(offsetPtr[i * colStride])
                if val > maxVal {
                    maxVal = val
                    maxIndex = i
                }
            }
            return maxIndex
        } else if logits.dataType == .float32 {
            let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
            let offsetPtr = ptr.advanced(by: baseOffset)
            for i in 0..<vocabSize {
                let val = offsetPtr[i * colStride]
                if val > maxVal {
                    maxVal = val
                    maxIndex = i
                }
            }
            return maxIndex
        }

        for i in 0..<vocabSize {
            let score = logits[baseOffset + i * colStride].floatValue
            if score > maxVal {
                maxVal = score
                maxIndex = i
            }
        }
        return maxIndex
    }

    func unloadModel() {
        self.encoderModel = nil
        self.decoderModel = nil
        if !Self.supportsInProcessParserModel {
            self.unigramTokenizer.unload()
        }
    }
}

nonisolated private final class DictionaryFeatureProvider: MLFeatureProvider, @unchecked Sendable {
    let values: [String: MLFeatureValue]
    var featureNames: Set<String> { Set(values.keys) }
    init(values: [String: MLFeatureValue]) { self.values = values }
    func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}
