import PhotosUI
import SwiftData
import SwiftUI

struct HeadshotReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    var initialFront: UIImage? = nil
    var initialLeft: UIImage? = nil
    var initialRight: UIImage? = nil
    var assets: [HeadshotAsset] = []
    var onSaved: (() -> Void)? = nil

    @State private var selectedAngle: HeadshotAngle = .front

    // 3 Photo slots state
    @State private var frontImage: UIImage?
    @State private var leftImage: UIImage?
    @State private var rightImage: UIImage?

    @State private var frontRatio: HeadshotAspectRatio = .ratio4x5
    @State private var leftRatio: HeadshotAspectRatio = .ratio4x5
    @State private var rightRatio: HeadshotAspectRatio = .ratio4x5

    @State private var frontScale: CGFloat = 1.0
    @State private var leftScale: CGFloat = 1.0
    @State private var rightScale: CGFloat = 1.0

    // Resolution-independent pan offsets (fraction of crop container width/height)
    @State private var frontOffsetRatio: CGSize = .zero
    @State private var leftOffsetRatio: CGSize = .zero
    @State private var rightOffsetRatio: CGSize = .zero

    // Measured framing container size
    @State private var cropContainerSize: CGSize = CGSize(width: 300, height: 375)

    // Gesture tracking
    @State private var pinchScale: CGFloat = 1.0
    @State private var dragTranslation: CGSize = .zero
    @State private var isInteractingWithCrop = false

    // Retake & save states
    @State private var showingSingleRetakeCamera = false
    @State private var showingSingleRetakePicker = false
    @State private var singlePickerItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var showingSaveError = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        aspectRatioChipsBar
                            .padding(.top, 8)
                            .padding(.horizontal, 16)

                        cropFramingView
                            .padding(.horizontal, 20)

                        HStack {
                            if currentScale > 1.01 || currentOffsetRatio != .zero {
                                Button {
                                    resetFramingForCurrentAngle()
                                } label: {
                                    Label("Reset Framing", systemImage: "arrow.counterclockwise")
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Theme.Colors.surfaceElevated)
                                        .clipShape(Capsule())
                                }
                            }

                            Spacer()

                            Menu {
                                Button {
                                    showingSingleRetakeCamera = true
                                } label: {
                                    Label("Take New Photo", systemImage: "camera")
                                }

                                Button {
                                    showingSingleRetakePicker = true
                                } label: {
                                    Label("Choose from Photos", systemImage: "photo")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Retake \(selectedAngle.rawValue)")
                                }
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.Colors.lavenderSurface)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 24)

                        threeAngleMiniBar
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }
                }
                .scrollDisabled(isInteractingWithCrop)
                .scrollEdgeHaptics()
            }
            .navigationTitle("Review Headshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveAllHeadshots()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isSaving || savedReadyCount < 3)
                }
            }
            .onAppear {
                loadInitialHeadshots()
            }
            .alert("Unable to Save Headshots", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "An unexpected error occurred while saving.")
            }
            .sheet(isPresented: $showingSingleRetakeCamera) {
                HeadshotCaptureView(
                    audition: audition,
                    retakeAngle: selectedAngle,
                    onRetakeComplete: { captured in
                        showingSingleRetakeCamera = false
                        updateImageForCurrentAngle(HeadshotCropMath.normalizedImage(captured))
                    }
                )
            }
            .photosPicker(
                isPresented: $showingSingleRetakePicker,
                selection: $singlePickerItem,
                matching: .images
            )
            .onChange(of: singlePickerItem) { _, item in
                guard let item = item else { return }
                singlePickerItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let downsampled = await Task.detached(priority: .userInitiated) {
                        HeadshotCropMath.downsampledImage(from: data, maxPixelDimension: 2400)
                    }.value
                    guard let image = downsampled else { return }
                    await MainActor.run {
                        updateImageForCurrentAngle(image)
                    }
                }
            }
        }
    }

    // MARK: - Current & Per-Angle Helpers

    private var currentImage: UIImage? {
        imageForAngle(selectedAngle)
    }

    private var currentRatio: HeadshotAspectRatio {
        ratioForAngle(selectedAngle)
    }

    private var currentScale: CGFloat {
        scaleForAngle(selectedAngle)
    }

    private var currentOffsetRatio: CGSize {
        offsetRatioForAngle(selectedAngle)
    }

    private var frameAspectRatio: CGFloat {
        aspectRatioValue(for: selectedAngle)
    }

    private var savedReadyCount: Int {
        var count = 0
        if frontImage != nil { count += 1 }
        if leftImage != nil { count += 1 }
        if rightImage != nil { count += 1 }
        return count
    }

    private func imageForAngle(_ angle: HeadshotAngle) -> UIImage? {
        switch angle {
        case .front: return frontImage
        case .left: return leftImage
        case .right: return rightImage
        }
    }

    private func ratioForAngle(_ angle: HeadshotAngle) -> HeadshotAspectRatio {
        switch angle {
        case .front: return frontRatio
        case .left: return leftRatio
        case .right: return rightRatio
        }
    }

    private func scaleForAngle(_ angle: HeadshotAngle) -> CGFloat {
        switch angle {
        case .front: return frontScale
        case .left: return leftScale
        case .right: return rightScale
        }
    }

    private func offsetRatioForAngle(_ angle: HeadshotAngle) -> CGSize {
        switch angle {
        case .front: return frontOffsetRatio
        case .left: return leftOffsetRatio
        case .right: return rightOffsetRatio
        }
    }

    private func aspectRatioValue(for angle: HeadshotAngle) -> CGFloat {
        let ratio = ratioForAngle(angle)
        let img = imageForAngle(angle)
        let raw = HeadshotCropMath.targetAspect(for: ratio, imageSize: img?.size)
        return max(0.5, min(2.0, raw))
    }

    // MARK: - Inline Aspect Ratio Chips (4:5, 2:3, 1:1, Free)

    private var aspectRatioChipsBar: some View {
        HStack(spacing: 8) {
            Text("Ratio:")
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textSecondary)

            ForEach([HeadshotAspectRatio.ratio4x5, .ratio2x3, .ratio1x1, .free], id: \.self) { ratio in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        setRatioForCurrentAngle(ratio)
                    }
                } label: {
                    Text(ratio.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(currentRatio == ratio ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface)
                        .foregroundStyle(currentRatio == ratio ? Color.white : Theme.Colors.textPrimary)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }

    // MARK: - Crop Framing View with Pinch & Drag

    private var cropFramingView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.92))
                .aspectRatio(frameAspectRatio, contentMode: .fit)

            if let img = currentImage {
                GeometryReader { geo in
                    let effectiveScale = max(1.0, min(3.5, currentScale * pinchScale))
                    let liveClampedOffset = HeadshotCropMath.adjustedOffset(
                        baseRatio: currentOffsetRatio,
                        translation: dragTranslation,
                        imageSize: img.size,
                        containerSize: geo.size,
                        scale: effectiveScale
                    )

                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(effectiveScale)
                        .offset(x: liveClampedOffset.width, y: liveClampedOffset.height)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { scale in
                                        isInteractingWithCrop = true
                                        pinchScale = scale
                                    }
                                    .onEnded { scale in
                                        let finalScale = max(1.0, min(3.5, currentScale * scale))
                                        let clamped = HeadshotCropMath.adjustedOffset(
                                            baseRatio: currentOffsetRatio,
                                            translation: dragTranslation,
                                            imageSize: img.size,
                                            containerSize: geo.size,
                                            scale: finalScale
                                        )
                                        setScaleForCurrentAngle(finalScale)
                                        setOffsetRatioForCurrentAngle(CGSize(
                                            width: clamped.width / max(1, geo.size.width),
                                            height: clamped.height / max(1, geo.size.height)
                                        ))
                                        pinchScale = 1.0
                                        dragTranslation = .zero
                                        isInteractingWithCrop = false
                                    },
                                DragGesture(minimumDistance: 2)
                                    .onChanged { val in
                                        isInteractingWithCrop = true
                                        dragTranslation = val.translation
                                    }
                                    .onEnded { val in
                                        let activeScale = max(1.0, min(3.5, currentScale * pinchScale))
                                        let clamped = HeadshotCropMath.adjustedOffset(
                                            baseRatio: currentOffsetRatio,
                                            translation: val.translation,
                                            imageSize: img.size,
                                            containerSize: geo.size,
                                            scale: activeScale
                                        )
                                        setOffsetRatioForCurrentAngle(CGSize(
                                            width: clamped.width / max(1, geo.size.width),
                                            height: clamped.height / max(1, geo.size.height)
                                        ))
                                        dragTranslation = .zero
                                        isInteractingWithCrop = false
                                    }
                            )
                        )
                        .onTapGesture(count: 2) {
                            resetFramingForCurrentAngle()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onAppear {
                            cropContainerSize = geo.size
                        }
                        .onChange(of: geo.size) { _, newSize in
                            cropContainerSize = newSize
                        }
                }
                .aspectRatio(frameAspectRatio, contentMode: .fit)

                gridOverlay
                    .aspectRatio(frameAspectRatio, contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text("No \(selectedAngle.rawValue) Photo")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
        }
        .frame(maxHeight: 390)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        .animation(.snappy(duration: 0.25), value: currentRatio)
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: 2.0 * h / 3.0))
                path.addLine(to: CGPoint(x: w, y: 2.0 * h / 3.0))

                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: 2.0 * w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: 2.0 * w / 3.0, y: h))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - 3-Angle Fluid Live Mini Preview Bar

    private var threeAngleMiniBar: some View {
        HStack(spacing: 12) {
            miniSlotView(title: "Front", angle: .front)
            miniSlotView(title: "Left Profile", angle: .left)
            miniSlotView(title: "Right Profile", angle: .right)
        }
        .padding(10)
        .cardStyle()
    }

    private func miniSlotView(title: String, angle: HeadshotAngle) -> some View {
        let image = imageForAngle(angle)
        let isSelected = (selectedAngle == angle)
        let angleAspect = aspectRatioValue(for: angle)
        let baseScale = scaleForAngle(angle)
        let baseOffsetRatio = offsetRatioForAngle(angle)

        let liveScale = isSelected ? max(1.0, min(3.5, baseScale * pinchScale)) : baseScale
        let liveDragRatioX = isSelected ? (dragTranslation.width / max(1, cropContainerSize.width)) : 0
        let liveDragRatioY = isSelected ? (dragTranslation.height / max(1, cropContainerSize.height)) : 0

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                pinchScale = 1.0
                dragTranslation = .zero
                isInteractingWithCrop = false
                selectedAngle = angle
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.Colors.lavenderSurface)

                        if let img = image {
                            GeometryReader { miniGeo in
                                let proposed = CGSize(
                                    width: (baseOffsetRatio.width + liveDragRatioX) * miniGeo.size.width,
                                    height: (baseOffsetRatio.height + liveDragRatioY) * miniGeo.size.height
                                )
                                let clampedMiniOffset = HeadshotCropMath.clampedOffset(
                                    proposed,
                                    imageSize: img.size,
                                    containerSize: miniGeo.size,
                                    scale: liveScale
                                )

                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: miniGeo.size.width, height: miniGeo.size.height)
                                    .scaleEffect(liveScale)
                                    .offset(x: clampedMiniOffset.width, y: clampedMiniOffset.height)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "camera")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .aspectRatio(angleAspect, contentMode: .fit)
                    .frame(maxHeight: 112)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Theme.Colors.accent : Color.clear, lineWidth: 2)
                    )
                }

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - State Updaters

    private func setRatioForCurrentAngle(_ ratio: HeadshotAspectRatio) {
        switch selectedAngle {
        case .front: frontRatio = ratio
        case .left: leftRatio = ratio
        case .right: rightRatio = ratio
        }
    }

    private func setScaleForCurrentAngle(_ scale: CGFloat) {
        switch selectedAngle {
        case .front: frontScale = scale
        case .left: leftScale = scale
        case .right: rightScale = scale
        }
    }

    private func setOffsetRatioForCurrentAngle(_ offsetRatio: CGSize) {
        switch selectedAngle {
        case .front: frontOffsetRatio = offsetRatio
        case .left: leftOffsetRatio = offsetRatio
        case .right: rightOffsetRatio = offsetRatio
        }
    }

    private func resetFramingForCurrentAngle() {
        withAnimation(.snappy(duration: 0.25)) {
            setScaleForCurrentAngle(1.0)
            setOffsetRatioForCurrentAngle(.zero)
            pinchScale = 1.0
            dragTranslation = .zero
        }
    }

    private func updateImageForCurrentAngle(_ image: UIImage) {
        let normalized = HeadshotCropMath.normalizedImage(image)
        switch selectedAngle {
        case .front: frontImage = normalized
        case .left: leftImage = normalized
        case .right: rightImage = normalized
        }
        resetFramingForCurrentAngle()
    }

    // MARK: - Load & Save Logic

    private func loadInitialHeadshots() {
        let requiredRatio = audition.validationRules.requiredHeadshotRatio
        frontRatio = requiredRatio
        leftRatio = requiredRatio
        rightRatio = requiredRatio

        if let f = initialFront { frontImage = HeadshotCropMath.normalizedImage(f) }
        if let l = initialLeft { leftImage = HeadshotCropMath.normalizedImage(l) }
        if let r = initialRight { rightImage = HeadshotCropMath.normalizedImage(r) }

        let sourceAssets = !assets.isEmpty ? assets : audition.headshots

        if frontImage == nil, let asset = sourceAssets.first(where: { $0.angle == .front }) {
            frontImage = loadResolvedImage(for: asset)
            frontRatio = asset.aspectRatio
            frontScale = max(1.0, asset.cropScale)
            frontOffsetRatio = CGSize(width: asset.cropOffsetRatioX, height: asset.cropOffsetRatioY)
        }
        if leftImage == nil, let asset = sourceAssets.first(where: { $0.angle == .left }) {
            leftImage = loadResolvedImage(for: asset)
            leftRatio = asset.aspectRatio
            leftScale = max(1.0, asset.cropScale)
            leftOffsetRatio = CGSize(width: asset.cropOffsetRatioX, height: asset.cropOffsetRatioY)
        }
        if rightImage == nil, let asset = sourceAssets.first(where: { $0.angle == .right }) {
            rightImage = loadResolvedImage(for: asset)
            rightRatio = asset.aspectRatio
            rightScale = max(1.0, asset.cropScale)
            rightOffsetRatio = CGSize(width: asset.cropOffsetRatioX, height: asset.cropOffsetRatioY)
        }
    }

    private func loadResolvedImage(for asset: HeadshotAsset) -> UIImage? {
        let origPath = MediaStorage.resolvePath(for: asset.originalFilePath)
        if !origPath.isEmpty, let img = UIImage(contentsOfFile: origPath) {
            return HeadshotCropMath.normalizedImage(img)
        }
        let cropPath = MediaStorage.resolvePath(for: asset.croppedFilePath)
        if !cropPath.isEmpty, let img = UIImage(contentsOfFile: cropPath) {
            return HeadshotCropMath.normalizedImage(img)
        }
        return nil
    }

    private func saveAllHeadshots() {
        guard let front = frontImage, let left = leftImage, let right = rightImage else { return }
        isSaving = true

        let auditionID = audition.id
        let items: [(HeadshotAngle, UIImage, HeadshotAspectRatio, CGFloat, CGSize)] = [
            (.front, front, frontRatio, frontScale, frontOffsetRatio),
            (.left, left, leftRatio, leftScale, leftOffsetRatio),
            (.right, right, rightRatio, rightScale, rightOffsetRatio)
        ]

        Task {
            do {
                var newAssets: [HeadshotAsset] = []

                for (angle, orig, ratio, scale, offsetRatio) in items {
                    let evaluation = await HeadshotGuidanceService.shared.evaluateImage(orig, for: angle)

                    let (origRel, cropRel) = try await Task.detached(priority: .userInitiated) {
                        let uprightOrig = HeadshotCropMath.normalizedImage(orig)
                        let targetAspect = HeadshotCropMath.targetAspect(for: ratio, imageSize: uprightOrig.size)
                        let refWidth: CGFloat = 300.0
                        let targetContainer = CGSize(
                            width: refWidth,
                            height: refWidth / max(0.25, targetAspect)
                        )
                        let pixelOffset = CGSize(
                            width: offsetRatio.width * targetContainer.width,
                            height: offsetRatio.height * targetContainer.height
                        )
                        let cropped = HeadshotCropMath.renderCroppedImage(
                            uprightOrig,
                            containerSize: targetContainer,
                            targetAspect: targetAspect,
                            scale: scale,
                            offset: pixelOffset
                        )

                        guard let origData = uprightOrig.jpegData(compressionQuality: 0.9),
                              let cropData = cropped.jpegData(compressionQuality: 0.92) else {
                            throw CocoaError(.fileWriteUnknown)
                        }

                        let origSaved = try MediaStorage.saveData(
                            origData,
                            relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_orig.jpg"
                        )
                        let cropSaved = try MediaStorage.saveData(
                            cropData,
                            relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_crop.jpg"
                        )
                        return (origSaved, cropSaved)
                    }.value

                    let asset = HeadshotAsset(
                        angle: angle,
                        originalFilePath: origRel,
                        croppedFilePath: cropRel,
                        aspectRatio: ratio,
                        cropPreset: .theatrical,
                        cropScale: Double(scale),
                        cropOffsetRatioX: Double(offsetRatio.width),
                        cropOffsetRatioY: Double(offsetRatio.height),
                        lightingPassed: evaluation.lighting == .good,
                        backgroundPassed: evaluation.background == .clean,
                        alignmentPassed: evaluation.isFaceCentered && evaluation.isAngleCorrect,
                        eyeLevelPassed: evaluation.isEyeLevel,
                        capturedAt: Date()
                    )
                    newAssets.append(asset)
                }

                await MainActor.run {
                    audition.headshots = newAssets
                    for idx in audition.requirements.indices {
                        if audition.requirements[idx].title.lowercased().contains("headshot") {
                            audition.requirements[idx].isCompleted = true
                        }
                    }

                    appState.saveChanges()
                    isSaving = false
                    onSaved?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = "Could not save headshots to storage: \(error.localizedDescription)"
                    showingSaveError = true
                }
            }
        }
    }
}
