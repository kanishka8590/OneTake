import SwiftUI

struct HeadshotPackageGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    var frontCropped: UIImage?
    var leftCropped: UIImage?
    var rightCropped: UIImage?

    var frontOriginal: UIImage?
    var leftOriginal: UIImage?
    var rightOriginal: UIImage?

    let onRetakeAngle: (HeadshotAngle) -> Void
    let onSaveCompleted: () -> Void

    @State private var showingImportPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false

    private var requiredRatio: HeadshotAspectRatio {
        audition.validationRules.requiredHeadshotRatio
    }

    private var cardAspectRatio: CGFloat {
        switch requiredRatio {
        case .ratio4x5: return 4.0 / 5.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio1x1: return 1.0
        case .free: return 4.0 / 5.0
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text("3-Angle Headshot Package")
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)

                            Text("Review your 3-photo package before saving to your audition.")
                                .font(Theme.Typography.bodyRegular)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .padding(.top, 16)

                        HStack(spacing: 12) {
                            headshotCard(title: "Front", angle: .front, image: frontCropped)
                            headshotCard(title: "Left Profile", angle: .left, image: leftCropped)
                            headshotCard(title: "Right Profile", angle: .right, image: rightCropped)
                        }
                        .padding(.horizontal, 16)

                        HStack(spacing: 8) {
                            Image(systemName: "aspectratio")
                                .foregroundStyle(Theme.Colors.accent)
                            Text("Required Casting Format: \(requiredRatio.rawValue)")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Theme.Colors.lavenderSurface)
                        .clipShape(Capsule())

                        Button {
                            showingImportPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("Import angle from Photos instead")
                            }
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.accent)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                }
            }
            .scrollEdgeHaptics()
            .navigationTitle("Headshot Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            savePackageToAudition()
                        }
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.accent)
                        .disabled(frontCropped == nil || leftCropped == nil || rightCropped == nil)
                        .accessibilityLabel("Save Headshots to Audition")
                    }
                }
            }
            .alert("Unable to Save Headshots", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unexpected error occurred while saving.")
            }
            .sheet(isPresented: $showingImportPicker) {
                HeadshotImportPickerView(audition: audition) {
                    dismiss()
                    onSaveCompleted()
                }
            }
        }
    }

    private func headshotCard(title: String, angle: HeadshotAngle, image: UIImage?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.Colors.lavenderTint)
                    .aspectRatio(cardAspectRatio, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.Colors.accent.opacity(0.28), lineWidth: 1))

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(cardAspectRatio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.rectangle.badge.plus")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.Colors.accent)
                        Text("Not captured")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }

            Text(title)
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textPrimary)

            Button {
                onRetakeAngle(angle)
            } label: {
                Text(image == nil ? "Capture" : "Retake")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
    }

    private func savePackageToAudition() {
        guard let front = frontCropped, let left = leftCropped, let right = rightCropped else { return }
        isSaving = true

        let auditionID = audition.id
        let ratio = requiredRatio
        let existingHeadshots = audition.headshots
        let items: [(HeadshotAngle, UIImage, UIImage?)] = [
            (.front, front, frontOriginal),
            (.left, left, leftOriginal),
            (.right, right, rightOriginal)
        ]

        Task {
            do {
                var newAssets: [HeadshotAsset] = []

                for (angle, cropped, orig) in items {
                    let evaluationTarget = orig ?? cropped
                    let evaluation = await HeadshotGuidanceService.shared.evaluateImage(evaluationTarget, for: angle)
                    let existingOrigPath = existingHeadshots.first(where: { $0.angle == angle })?.originalFilePath

                    let (origRel, cropRel) = try await Task.detached(priority: .userInitiated) {
                        let uprightCrop = HeadshotCropMath.normalizedImage(cropped)
                        guard let cropData = uprightCrop.jpegData(compressionQuality: 0.9) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        let savedCrop = try MediaStorage.saveData(
                            cropData,
                            relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_crop.jpg"
                        )

                        let savedOrig: String
                        if let orig {
                            let uprightOrig = HeadshotCropMath.normalizedImage(orig)
                            guard let origData = uprightOrig.jpegData(compressionQuality: 0.9) else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            savedOrig = try MediaStorage.saveData(
                                origData,
                                relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_orig.jpg"
                            )
                        } else if let existingOrigPath,
                                  !existingOrigPath.isEmpty,
                                  MediaStorage.fileExists(at: existingOrigPath) {
                            savedOrig = MediaStorage.storedRelativePath(for: existingOrigPath)
                        } else {
                            savedOrig = savedCrop
                        }

                        return (savedOrig, savedCrop)
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
                    onSaveCompleted()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Could not save headshot package: \(error.localizedDescription)"
                    showingErrorAlert = true
                }
            }
        }
    }
}
