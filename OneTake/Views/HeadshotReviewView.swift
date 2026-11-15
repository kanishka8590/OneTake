import SwiftUI
import SwiftData
import PhotosUI

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

    // Gesture tracking
    @State private var pinchScale: CGFloat = 1.0
    @State private var dragTranslation: CGSize = .zero

    // Retake states
    @State private var showingSingleRetakeCamera = false
    @State private var showingSingleRetakePicker = false
    @State private var singlePickerItem: PhotosPickerItem?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        // Angle Selector Chips (Front -> Left -> Right)
                        angleSelectorChips
                            .padding(.top, 8)
                            .padding(.horizontal, 16)

                        // Inline Aspect Ratio Chips: 4:5, 2:3, 1:1, Free
                        aspectRatioChipsBar
                            .padding(.horizontal, 16)

                        // Interactive Pinch / Drag Crop Framing Box
                        cropFramingView
                            .padding(.horizontal, 20)

                        // Retake single angle button
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

                        // 3-Angle Summary Mini-Thumbnails
                        threeAngleMiniBar
                            .padding(.horizontal, 20)

                        Spacer(minLength: 20)

                        // Working "Save Headshots" Primary Button
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
            // Single Retake Camera Sheet
            .sheet(isPresented: $showingSingleRetakeCamera) {
                SingleAngleCameraSheet(targetAngle: selectedAngle) { captured in
                    showingSingleRetakeCamera = false
                    updateImageForCurrentAngle(captured)
                } onCancel: {
                    showingSingleRetakeCamera = false
                }
            }
            // Single Retake Photos Picker
            .photosPicker(
                isPresented: $showingSingleRetakePicker,
                selection: $singlePickerItem,
                matching: .images
            )
            .onChange(of: singlePickerItem) { _, item in
                guard let item = item else { return }
                singlePickerItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            updateImageForCurrentAngle(image)
                        }
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
        switch currentRatio {
        case .ratio4x5: return 4.0 / 5.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio1x1: return 1.0
        case .free:
            if let img = currentImage {
                return max(0.5, min(2.0, img.size.width / max(1.0, img.size.height)))
            }
            return 4.0 / 5.0
        }
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
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(max(1.0, currentScale * pinchScale))
                        .offset(
                            x: currentOffset.width + dragTranslation.width,
                            y: currentOffset.height + dragTranslation.height
                        )
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { scale in
                                        pinchScale = scale
                                    }
                                    .onEnded { scale in
                                        let final = max(1.0, min(3.5, currentScale * scale))
                                        setScaleForCurrentAngle(final)
                                        pinchScale = 1.0
                                    },
                                DragGesture()
                                    .onChanged { val in
                                        dragTranslation = val.translation
                                    }
                                    .onEnded { val in
                                        let finalOffset = CGSize(
                                            width: currentOffset.width + val.translation.width,
                                            height: currentOffset.height + val.translation.height
                                        )
                                        setOffsetForCurrentAngle(finalOffset)
                                        dragTranslation = .zero
                                    }
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .aspectRatio(frameAspectRatio, contentMode: .fit)

                // Rule-of-thirds grid overlay
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
                // Horizontal lines
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: 2.0 * h / 3.0))
                path.addLine(to: CGPoint(x: w, y: 2.0 * h / 3.0))

                // Vertical lines
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
        switch selectedAngle {
        case .front: frontImage = image
        case .left: leftImage = image
        case .right: rightImage = image
        }
        resetFramingForCurrentAngle()
    }

    // MARK: - Load & Save Logic

    private func loadInitialHeadshots() {
        if let f = initialFront { frontImage = f }
        if let l = initialLeft { leftImage = l }
        if let r = initialRight { rightImage = r }

        let sourceAssets = !assets.isEmpty ? assets : audition.headshots

        // Load existing saved audition headshots if inputs were nil
        if frontImage == nil, let asset = sourceAssets.first(where: { $0.angle == .front }) {
            frontImage = UIImage(contentsOfFile: asset.originalFilePath) ?? UIImage(contentsOfFile: asset.croppedFilePath)
            frontRatio = asset.aspectRatio
        }
        if leftImage == nil, let asset = sourceAssets.first(where: { $0.angle == .left }) {
            leftImage = UIImage(contentsOfFile: asset.originalFilePath) ?? UIImage(contentsOfFile: asset.croppedFilePath)
            leftRatio = asset.aspectRatio
        }
        if rightImage == nil, let asset = sourceAssets.first(where: { $0.angle == .right }) {
            rightImage = UIImage(contentsOfFile: asset.originalFilePath) ?? UIImage(contentsOfFile: asset.croppedFilePath)
            rightRatio = asset.aspectRatio
        }

        // Default ratio to audition's required ratio
        let defaultRatio = audition.validationRules.requiredHeadshotRatio
        if initialFront == nil && sourceAssets.isEmpty {
            frontRatio = defaultRatio
            leftRatio = defaultRatio
            rightRatio = defaultRatio
        }
    }

    private func saveAllHeadshots() {
        guard let front = frontImage, let left = leftImage, let right = rightImage else { return }
        isSaving = true

        Task {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let headshotsDir = docs.appendingPathComponent("Headshots_\(audition.id)", isDirectory: true)
            try? fm.createDirectory(at: headshotsDir, withIntermediateDirectories: true)

            let items: [(HeadshotAngle, UIImage, HeadshotAspectRatio, CGFloat, CGSize)] = [
                (.front, front, frontRatio, frontScale, frontOffset),
                (.left, left, leftRatio, leftScale, leftOffset),
                (.right, right, rightRatio, rightScale, rightOffset)
            ]

            var newAssets: [HeadshotAsset] = []

            for (angle, orig, ratio, scale, offset) in items {
                let origPath = headshotsDir.appendingPathComponent("\(angle.rawValue)_orig.jpg").path
                let cropPath = headshotsDir.appendingPathComponent("\(angle.rawValue)_crop.jpg").path

                // Render cropped version with scale & offset
                let cropped = renderCroppedImage(original: orig, ratio: ratio, scale: scale, offset: offset)

                if let origData = orig.jpegData(compressionQuality: 0.9) {
                    try? origData.write(to: URL(fileURLWithPath: origPath))
                }
                if let cropData = cropped.jpegData(compressionQuality: 0.9) {
                    try? cropData.write(to: URL(fileURLWithPath: cropPath))
                }

                let asset = HeadshotAsset(
                    angle: angle,
                    originalFilePath: origPath,
                    croppedFilePath: cropPath,
                    aspectRatio: ratio,
                    cropPreset: .theatrical,
                    lightingPassed: true,
                    backgroundPassed: true,
                    alignmentPassed: true,
                    eyeLevelPassed: true,
                    capturedAt: Date()
                )
                newAssets.append(asset)
            }

            await MainActor.run {
                audition.headshots = newAssets

                // Mark headshot requirement complete if present
                for idx in audition.requirements.indices {
                    if audition.requirements[idx].title.lowercased().contains("headshot") {
                        audition.requirements[idx].isCompleted = true
                    }
                }

                try? appState.modelContext?.save()
                appState.loadData()
                isSaving = false
                onSaved?()
                dismiss()
            }
        }
    }

    private func renderCroppedImage(original: UIImage, ratio: HeadshotAspectRatio, scale: CGFloat, offset: CGSize) -> UIImage {
        let targetAspect: CGFloat
        switch ratio {
        case .ratio4x5: targetAspect = 4.0 / 5.0
        case .ratio2x3: targetAspect = 2.0 / 3.0
        case .ratio1x1: targetAspect = 1.0
        case .free: targetAspect = original.size.width / max(1.0, original.size.height)
        }

        let origWidth = original.size.width
        let origHeight = original.size.height

        var cropWidth = origWidth / max(1.0, scale)
        var cropHeight = cropWidth / targetAspect

        if cropHeight > origHeight {
            cropHeight = origHeight / max(1.0, scale)
            cropWidth = cropHeight * targetAspect
        }

        let centerX = origWidth / 2.0 - (offset.width * (origWidth / 300.0))
        let centerY = origHeight / 2.0 - (offset.height * (origHeight / 380.0))

        let cropRect = CGRect(
            x: max(0, min(origWidth - cropWidth, centerX - cropWidth / 2.0)),
            y: max(0, min(origHeight - cropHeight, centerY - cropHeight / 2.0)),
            width: min(origWidth, cropWidth),
            height: min(origHeight, cropHeight)
        )

        UIGraphicsBeginImageContextWithOptions(cropRect.size, false, original.scale)
        original.draw(at: CGPoint(x: -cropRect.origin.x, y: -cropRect.origin.y))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result ?? original
    }
}

// MARK: - Single Angle Camera Sheet (For Quick Retake)

private struct SingleAngleCameraSheet: View {
    @Environment(\.dismiss) private var dismiss

    let targetAngle: HeadshotAngle
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var guidanceService = HeadshotGuidanceService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let session = guidanceService.captureSession {
                    LiveCameraPreview(session: session)
                        .ignoresSafeArea()
                }

                // Silhouette Guide
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height

                    ZStack {
                        Ellipse()
                            .stroke(Color.white.opacity(0.8), lineWidth: 2.5)
                            .frame(width: w * 0.64, height: h * 0.46)
                            .position(x: w / 2.0, y: h * 0.45)

                        Text("Align \(targetAngle.rawValue) Angle")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .position(x: w / 2.0, y: h * 0.16)
                    }
                }

                // Shutter Button
                VStack {
                    Spacer()
                    Button {
                        guidanceService.startCountdown(seconds: 3) { captured in
                            if let img = captured {
                                guidanceService.stopSession()
                                onCaptured(img)
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                            Circle().fill(Color.white).frame(width: 60, height: 60)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Retake \(targetAngle.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        guidanceService.stopSession()
                        onCancel()
                    }
                    .foregroundStyle(.white)
                }
            }
            .onAppear {
                guidanceService.startSession(for: targetAngle)
                guidanceService.announceAngle(targetAngle)
            }
            .onDisappear {
                guidanceService.stopSession()
            }
        }
    }
}
