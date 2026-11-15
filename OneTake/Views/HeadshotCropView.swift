import SwiftUI

struct HeadshotCropView: View {
    @Environment(\.dismiss) private var dismiss

    let originalImage: UIImage
    let defaultRatio: HeadshotAspectRatio
    let onCropConfirmed: (UIImage, HeadshotAspectRatio, HeadshotCropPreset) -> Void

    @State private var selectedRatio: HeadshotAspectRatio = .ratio4x5
    @State private var selectedPreset: HeadshotCropPreset = .theatrical
    @State private var croppedPreviewImage: UIImage?
    @State private var isProcessingCrop = false
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    // Framing Preset Selector
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(HeadshotCropPreset.allCases, id: \.self) { preset in
                                Button {
                                    selectedPreset = preset
                                    updateRatioForPreset(preset)
                                    generateAutoCrop()
                                } label: {
                                    Text(preset.rawValue)
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(selectedPreset == preset ? Color.white : Theme.Colors.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedPreset == preset ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 8)

                    // Crop Preview Display
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.85))
                            .aspectRatio(previewAspectRatio, contentMode: .fit)
                            .padding(.horizontal, 24)

                        if let preview = croppedPreviewImage {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 28)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }

                        // Rule-of-thirds grid overlay
                        gridOverlay
                            .aspectRatio(previewAspectRatio, contentMode: .fit)
                            .padding(.horizontal, 24)
                            .allowsHitTesting(false)
                    }
                    .frame(maxHeight: 380)

                    // Aspect Ratio Picker
                    Picker("Ratio", selection: $selectedRatio) {
                        ForEach(HeadshotAspectRatio.allCases, id: \.self) { ratio in
                            Text(ratio.rawValue).tag(ratio)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)
                    .onChange(of: selectedRatio) { _, _ in
                        generateAutoCrop()
                    }

                    // Face-aware auto center button
                    Button {
                        generateAutoCrop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "face.smiling")
                            Text("Auto-Align Face & Eye Line")
                        }
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.primaryPlum)
                    }

                    Spacer()

                    // Confirm Crop
                    Button {
                        if let finalImage = croppedPreviewImage {
                            onCropConfirmed(finalImage, selectedRatio, selectedPreset)
                            dismiss()
                        }
                    } label: {
                        Text("Apply Crop")
                            .primaryCapsuleButton()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Adjust Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                selectedRatio = defaultRatio
                generateAutoCrop()
            }
        }
    }

    private var previewAspectRatio: CGFloat {
        switch selectedRatio {
        case .ratio4x5: return 4.0 / 5.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio1x1: return 1.0
        case .free: return 4.0 / 5.0
        }
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height

                // Vertical lines
                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: 2.0 * w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: 2.0 * w / 3.0, y: h))

                // Horizontal lines
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: 2.0 * h / 3.0))
                path.addLine(to: CGPoint(x: w, y: 2.0 * h / 3.0))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
    }

    private func updateRatioForPreset(_ preset: HeadshotCropPreset) {
        switch preset {
        case .theatrical, .cardSlotFit, .tightCloseUp:
            selectedRatio = .ratio4x5
        case .commercial:
            selectedRatio = .ratio4x5
        case .square:
            selectedRatio = .ratio1x1
        case .headAndShoulders:
            selectedRatio = .ratio2x3
        }
    }

    private func generateAutoCrop() {
        isProcessingCrop = true
        Task {
            let cropped = await ImageFramer.autoCrop(
                image: originalImage,
                aspectRatio: selectedRatio,
                preset: selectedPreset
            )
            await MainActor.run {
                self.croppedPreviewImage = cropped
                self.isProcessingCrop = false
            }
        }
    }
}
