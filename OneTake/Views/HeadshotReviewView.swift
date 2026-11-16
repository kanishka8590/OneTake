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

    @State private var frontOffset: CGSize = .zero
    @State private var leftOffset: CGSize = .zero
    @State private var rightOffset: CGSize = .zero

    // Measured framing container size from GeometryReader
    @State private var cropContainerSize: CGSize = CGSize(width: 300, height: 375)

    // Gesture tracking
    @State private var pinchScale: CGFloat = 1.0
    @State private var dragTranslation: CGSize = .zero

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
                    VStack(spacing: 18) {
                        angleSelectorChips
                            .padding(.top, 8)
                            .padding(.horizontal, 16)

                        aspectRatioChipsBar
                            .padding(.horizontal, 16)

                        cropFramingView
                            .padding(.horizontal, 20)

                        HStack {
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

                        Spacer(minLength: 20)

                        Button {
                            saveAllHeadshots()
                        } label: {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Save Headshots (\(savedReadyCount)/3 Ready)")
                                }
                                .primaryCapsuleButton()
                            }
                        }
                        .disabled(isSaving || savedReadyCount < 3)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Review Headshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
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

    // MARK: - Current Angle Helpers

    private var currentImage: UIImage? {
        switch selectedAngle {
        case .front: return frontImage
        case .left: return leftImage
        case .right: return rightImage
        }
    }

    private var currentRatio: HeadshotAspectRatio {
        switch selectedAngle {
        case .front: return frontRatio
        case .left: return leftRatio
        case .right: return rightRatio
        }
    }

    private var currentScale: CGFloat {
        switch selectedAngle {
        case .front: return frontScale
        case .left: return leftScale
        case .right: return rightScale
        }
    }

    private var currentOffset: CGSize {
        switch selectedAngle {
        case .front: return frontOffset
        case .left: return leftOffset
        case .right: return rightOffset
        }
    }

    private var frameAspectRatio: CGFloat {
        let raw = HeadshotCropMath.targetAspect(for: currentRatio, imageSize: currentImage?.size)
        return max(0.5, min(2.0, raw))
    }

    private var savedReadyCount: Int {
        var count = 0
        if frontImage != nil { count += 1 }
        if leftImage != nil { count += 1 }
        if rightImage != nil { count += 1 }
        return count
    }

    // MARK: - Angle Selector Chips

    private var angleSelectorChips: some View {
        HStack(spacing: 8) {
            ForEach(HeadshotAngle.allCases, id: \.self) { angle in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedAngle = angle
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: imageForAngle(angle) != nil ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 13))
                            .foregroundStyle(selectedAngle == angle ? Color.white : (imageForAngle(angle) != nil ? Theme.Colors.successGreen : Theme.Colors.textSecondary))

                        Text(angleTitle(angle))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(selectedAngle == angle ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface)
                    .foregroundStyle(selectedAngle == angle ? Color.white : Theme.Colors.textPrimary)
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func angleTitle(_ angle: HeadshotAngle) -> String {
        switch angle {
        case .front: return "Front"
        case .left: return "Left Profile"
        case .right: return "Right Profile"
        }
    }

    private func imageForAngle(_ angle: HeadshotAngle) -> UIImage? {
        switch angle {
        case .front: return frontImage
        case .left: return leftImage
        case .right: return rightImage
        }
    }

    // MARK: - Inline Aspect Ratio Chips (4:5, 2:3, 1:1, Free)

    private var aspectRatioChipsBar: some View {
        HStack(spacing: 8) {
            Text("Ratio:")
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textSecondary)

            ForEach([HeadshotAspectRatio.ratio4x5, .ratio2x3, .ratio1x1, .free], id: \.self) { ratio in
                Button {
                    withAnimation {
                        setRatioForCurrentAngle(ratio)
                        resetFramingForCurrentAngle()
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
                    let proposedOffset = CGSize(
                        width: currentOffset.width + dragTranslation.width,
                        height: currentOffset.height + dragTranslation.height
                    )
                    let liveClampedOffset = HeadshotCropMath.clampedOffset(
                        proposedOffset,
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
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { scale in
                                        pinchScale = scale
                                    }
                                    .onEnded { scale in
                                        let finalScale = max(1.0, min(3.5, currentScale * scale))
                                        setScaleForCurrentAngle(finalScale)
                                        let clamped = HeadshotCropMath.clampedOffset(
                                            currentOffset,
                                            imageSize: img.size,
                                            containerSize: geo.size,
                                            scale: finalScale
                                        )
                                        setOffsetForCurrentAngle(clamped)
                                        pinchScale = 1.0
                                    },
                                DragGesture()
                                    .onChanged { val in
                                        dragTranslation = val.translation
                                    }
                                    .onEnded { val in
                                        let rawOffset = CGSize(
                                            width: currentOffset.width + val.translation.width,
                                            height: currentOffset.height + val.translation.height
                                        )
                                        let clamped = HeadshotCropMath.clampedOffset(
                                            rawOffset,
                                            imageSize: img.size,
                                            containerSize: geo.size,
                                            scale: currentScale
                                        )
                                        setOffsetForCurrentAngle(clamped)
                                        dragTranslation = .zero
                                    }
                            )
                        )
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
        .frame(maxHeight: 370)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
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

    // MARK: - 3-Angle Mini Preview Bar

    private var threeAngleMiniBar: some View {
        HStack(spacing: 12) {
            miniSlotView(title: "Front", angle: .front, image: frontImage)
            miniSlotView(title: "Left", angle: .left, image: leftImage)
            miniSlotView(title: "Right", angle: .right, image: rightImage)
        }
        .padding(10)
        .cardStyle()
    }

    private func miniSlotView(title: String, angle: HeadshotAngle, image: UIImage?) -> some View {
        Button {
            withAnimation { selectedAngle = angle }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.Colors.lavenderSurface)
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)

                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "camera")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selectedAngle == angle ? Theme.Colors.accent : Color.clear, lineWidth: 2)
                )

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selectedAngle == angle ? Theme.Colors.accent : Theme.Colors.textSecondary)
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

    private func setOffsetForCurrentAngle(_ offset: CGSize) {
        switch selectedAngle {
        case .front: frontOffset = offset
        case .left: leftOffset = offset
        case .right: rightOffset = offset
        }
    }

    private func resetFramingForCurrentAngle() {
        withAnimation {
            setScaleForCurrentAngle(1.0)
            setOffsetForCurrentAngle(.zero)
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
        }
        if leftImage == nil, let asset = sourceAssets.first(where: { $0.angle == .left }) {
            leftImage = loadResolvedImage(for: asset)
            leftRatio = asset.aspectRatio
        }
        if rightImage == nil, let asset = sourceAssets.first(where: { $0.angle == .right }) {
            rightImage = loadResolvedImage(for: asset)
            rightRatio = asset.aspectRatio
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
        let containerSize = cropContainerSize
        let items: [(HeadshotAngle, UIImage, HeadshotAspectRatio, CGFloat, CGSize)] = [
            (.front, front, frontRatio, frontScale, frontOffset),
            (.left, left, leftRatio, leftScale, leftOffset),
            (.right, right, rightRatio, rightScale, rightOffset)
        ]

        Task {
            do {
                var newAssets: [HeadshotAsset] = []

                for (angle, orig, ratio, scale, offset) in items {
                    let evaluation = await HeadshotGuidanceService.shared.evaluateImage(orig, for: angle)

                    let (origRel, cropRel) = try await Task.detached(priority: .userInitiated) {
                        let uprightOrig = HeadshotCropMath.normalizedImage(orig)
                        let targetAspect = HeadshotCropMath.targetAspect(for: ratio, imageSize: uprightOrig.size)
                        let targetContainer = CGSize(
                            width: containerSize.width > 0 ? containerSize.width : 300,
                            height: (containerSize.width > 0 ? containerSize.width : 300) / max(0.25, targetAspect)
                        )
                        let cropped = HeadshotCropMath.renderCroppedImage(
                            uprightOrig,
                            containerSize: targetContainer,
                            targetAspect: targetAspect,
                            scale: scale,
                            offset: offset
                        )

                        guard let origData = uprightOrig.jpegData(compressionQuality: 0.9),
                              let cropData = cropped.jpegData(compressionQuality: 0.9) else {
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
