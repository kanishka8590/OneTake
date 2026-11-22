import SwiftUI

struct HeadshotCropView: View {
    @Environment(\.dismiss) private var dismiss

    let originalImage: UIImage
    let defaultRatio: HeadshotAspectRatio
    let angle: HeadshotAngle?
    let batchProgress: (current: Int, total: Int)?
    let onCropConfirmed: (UIImage, HeadshotAspectRatio, HeadshotCropPreset) -> Void

    init(
        originalImage: UIImage,
        defaultRatio: HeadshotAspectRatio,
        angle: HeadshotAngle? = nil,
        batchProgress: (current: Int, total: Int)? = nil,
        onCropConfirmed: @escaping (UIImage, HeadshotAspectRatio, HeadshotCropPreset) -> Void
    ) {
        self.originalImage = originalImage
        self.defaultRatio = defaultRatio
        self.angle = angle
        self.batchProgress = batchProgress
        self.onCropConfirmed = onCropConfirmed
    }

    static func navigationTitle(for angle: HeadshotAngle?) -> String {
        switch angle {
        case .front: return "Crop Front"
        case .left: return "Crop Left Profile"
        case .right: return "Crop Right Profile"
        case nil: return "Adjust Crop"
        }
    }

    @State private var selectedRatio: HeadshotAspectRatio = .ratio4x5
    @State private var selectedPreset: HeadshotCropPreset = .theatrical
    @State private var croppedPreviewImage: UIImage?
    @State private var isProcessingCrop = false
    @State private var isApplyingCrop = false
    @State private var autoCropTask: Task<Void, Never>?

    // Interactive pinch & pan fine-tuning over the auto-framed preview
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var pinchScale: CGFloat = 1.0
    @State private var dragTranslation: CGSize = .zero
    @State private var previewContainerSize: CGSize = CGSize(width: 280, height: 350)

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
                                    Haptics.selectionTick()
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
                            GeometryReader { geo in
                                let effectiveScale = max(1.0, min(3.5, zoomScale * pinchScale))
                                let proposedOffset = CGSize(
                                    width: panOffset.width + dragTranslation.width,
                                    height: panOffset.height + dragTranslation.height
                                )
                                let liveOffset = HeadshotCropMath.clampedOffset(
                                    proposedOffset,
                                    imageSize: preview.size,
                                    containerSize: geo.size,
                                    scale: effectiveScale
                                )

                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .scaleEffect(effectiveScale)
                                    .offset(x: liveOffset.width, y: liveOffset.height)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        SimultaneousGesture(
                                            MagnificationGesture()
                                                .onChanged { value in
                                                    pinchScale = value
                                                }
                                                .onEnded { value in
                                                    let finalScale = max(1.0, min(3.5, zoomScale * value))
                                                    zoomScale = finalScale
                                                    panOffset = HeadshotCropMath.clampedOffset(
                                                        panOffset,
                                                        imageSize: preview.size,
                                                        containerSize: geo.size,
                                                        scale: finalScale
                                                    )
                                                    pinchScale = 1.0
                                                },
                                            DragGesture()
                                                .onChanged { val in
                                                    dragTranslation = val.translation
                                                }
                                                .onEnded { val in
                                                    let raw = CGSize(
                                                        width: panOffset.width + val.translation.width,
                                                        height: panOffset.height + val.translation.height
                                                    )
                                                    panOffset = HeadshotCropMath.clampedOffset(
                                                        raw,
                                                        imageSize: preview.size,
                                                        containerSize: geo.size,
                                                        scale: zoomScale
                                                    )
                                                    dragTranslation = .zero
                                                }
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .onAppear {
                                        previewContainerSize = geo.size
                                    }
                                    .onChange(of: geo.size) { _, newSize in
                                        previewContainerSize = newSize
                                    }
                            }
                            .aspectRatio(previewAspectRatio, contentMode: .fit)
                            .padding(.horizontal, 28)
                        }

                        if isProcessingCrop || croppedPreviewImage == nil {
                            ProgressView()
                                .tint(.white)
                                .padding(14)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                        }

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
                    .onChange(of: selectedRatio) { _, newRatio in
                        Haptics.selectionTick()
                        if selectedPreset == .commercial && newRatio != .free {
                            selectedPreset = .theatrical
                        }
                        generateAutoCrop()
                    }

                    // Face-aware auto center button
                    HStack(spacing: 16) {
                        Button {
                            generateAutoCrop()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "face.smiling")
                                Text("Auto-Align Face & Eye Line")
                            }
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.accent)
                        }
                        .disabled(isProcessingCrop)

                        if zoomScale > 1.01 || panOffset != .zero {
                            Button {
                                withAnimation {
                                    zoomScale = 1.0
                                    panOffset = .zero
                                }
                            } label: {
                                Text("Reset Pan/Zoom")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    }

                    Spacer(minLength: 8)
                }
            }
            .floatingBottomActionBar(horizontalPadding: 24) {
                let disabled = croppedPreviewImage == nil || isProcessingCrop || isApplyingCrop
                Button {
                    applyAndConfirmCrop()
                } label: {
                    Group {
                        if isApplyingCrop {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Apply Crop")
                        }
                    }
                    .primaryCapsuleButton(disabled: disabled)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
            .navigationTitle(Self.navigationTitle(for: angle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        autoCropTask?.cancel()
                        dismiss()
                    }
                }
                if let batchProgress, batchProgress.total > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(batchProgress.current) of \(batchProgress.total)")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .accessibilityLabel("Headshot \(batchProgress.current) of \(batchProgress.total)")
                    }
                }
            }
            .onAppear {
                selectedRatio = defaultRatio
                selectedPreset = defaultPreset(for: defaultRatio)
                generateAutoCrop()
            }
            .onDisappear {
                autoCropTask?.cancel()
            }
        }
    }

    private var previewAspectRatio: CGFloat {
        let imageSize = croppedPreviewImage?.size ?? HeadshotCropMath.normalizedImage(originalImage).size
        let presetForFree: HeadshotCropPreset? = (selectedRatio == .free && selectedPreset == .commercial) ? .commercial : nil
        let raw = HeadshotCropMath.targetAspect(for: selectedRatio, preset: presetForFree, imageSize: imageSize)
        return max(0.5, min(2.0, raw))
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height

                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: 2.0 * w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: 2.0 * w / 3.0, y: h))

                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: 2.0 * h / 3.0))
                path.addLine(to: CGPoint(x: w, y: 2.0 * h / 3.0))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
    }

    private func defaultPreset(for ratio: HeadshotAspectRatio) -> HeadshotCropPreset {
        switch ratio {
        case .ratio4x5: return .theatrical
        case .ratio2x3: return .headAndShoulders
        case .ratio1x1: return .square
        case .free: return .cardSlotFit
        }
    }

    private func updateRatioForPreset(_ preset: HeadshotCropPreset) {
        switch preset {
        case .theatrical, .tightCloseUp:
            selectedRatio = .ratio4x5
        case .commercial:
            // Commercial is 3:4; map to .free so ImageFramer uses the 3:4 preset ratio cleanly.
            selectedRatio = .free
        case .cardSlotFit:
            selectedRatio = .free
        case .square:
            selectedRatio = .ratio1x1
        case .headAndShoulders:
            selectedRatio = .ratio2x3
        }
    }

    private func generateAutoCrop() {
        autoCropTask?.cancel()
        isProcessingCrop = true
        zoomScale = 1.0
        panOffset = .zero

        let source = originalImage
        let ratio = selectedRatio
        let preset = selectedPreset

        autoCropTask = Task {
            let cropped = await ImageFramer.autoCrop(
                image: source,
                aspectRatio: ratio,
                preset: preset
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.croppedPreviewImage = cropped
                self.isProcessingCrop = false
            }
        }
    }

    private func applyAndConfirmCrop() {
        guard let preview = croppedPreviewImage else { return }
        if zoomScale <= 1.001 && panOffset == .zero {
            Haptics.success()
            onCropConfirmed(preview, selectedRatio, selectedPreset)
            dismiss()
            return
        }

        isApplyingCrop = true
        let aspect = previewAspectRatio
        let container = previewContainerSize
        let scale = zoomScale
        let offset = panOffset
        let ratio = selectedRatio
        let preset = selectedPreset

        Task {
            let finalImage = await Task.detached(priority: .userInitiated) {
                HeadshotCropMath.renderCroppedImage(
                    preview,
                    containerSize: container,
                    targetAspect: aspect,
                    scale: scale,
                    offset: offset
                )
            }.value
            await MainActor.run {
                isApplyingCrop = false
                onCropConfirmed(finalImage, ratio, preset)
                dismiss()
            }
        }
    }
}
