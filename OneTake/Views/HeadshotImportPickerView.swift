import PhotosUI
import SwiftUI

struct HeadshotImportPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    let onImportSaved: () -> Void

    @State private var frontItem: PhotosPickerItem?
    @State private var leftItem: PhotosPickerItem?
    @State private var rightItem: PhotosPickerItem?

    @State private var frontImage: UIImage?
    @State private var leftImage: UIImage?
    @State private var rightImage: UIImage?

    @State private var isAutoCropping = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false

    var isReadyToSave: Bool {
        frontImage != nil && leftImage != nil && rightImage != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text("Import Headshots")
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)

                            Text("Select photos from your library for each required angle. They will be auto-cropped to \(audition.validationRules.requiredHeadshotRatio.rawValue).")
                                .font(Theme.Typography.bodyRegular)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .padding(.top, 16)

                        VStack(spacing: 14) {
                            slotRow(
                                title: "Front Shot",
                                angle: .front,
                                image: frontImage,
                                item: $frontItem
                            )
                            slotRow(
                                title: "Left Profile",
                                angle: .left,
                                image: leftImage,
                                item: $leftItem
                            )
                            slotRow(
                                title: "Right Profile",
                                angle: .right,
                                image: rightImage,
                                item: $rightItem
                            )
                        }
                        .padding(.horizontal, Theme.Layout.screenHPadding)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Photo Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isAutoCropping {
                        ProgressView()
                    } else {
                        Button("Save") {
                            saveImportedHeadshots()
                        }
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.accent)
                        .disabled(!isReadyToSave)
                        .accessibilityLabel("Save Imported Headshots")
                    }
                }
            }
            .alert("Unable to Import Headshots", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unexpected error occurred while saving.")
            }
            .onChange(of: frontItem) { _, item in
                loadImage(from: item) { self.frontImage = $0 }
            }
            .onChange(of: leftItem) { _, item in
                loadImage(from: item) { self.leftImage = $0 }
            }
            .onChange(of: rightItem) { _, item in
                loadImage(from: item) { self.rightImage = $0 }
            }
        }
    }

    private func slotRow(
        title: String,
        angle: HeadshotAngle,
        image: UIImage?,
        item: Binding<PhotosPickerItem?>
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 64, height: 80)

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(image == nil ? "Not selected" : "Selected & Ready")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(image == nil ? Theme.Colors.textSecondary : Theme.Colors.successGreen)
            }

            Spacer()

            PhotosPicker(selection: item, matching: .images) {
                Text(image == nil ? "Choose" : "Change")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.Colors.lavenderTint)
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func loadImage(from item: PhotosPickerItem?, completion: @escaping (UIImage?) -> Void) {
        guard let item = item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    errorMessage = "Could not load the selected photo."
                    showingErrorAlert = true
                }
                return
            }
            let img = await Task.detached(priority: .userInitiated) {
                HeadshotCropMath.downsampledImage(from: data, maxPixelDimension: 2400)
            }.value
            await MainActor.run {
                if let img {
                    completion(img)
                } else {
                    errorMessage = "Unsupported image format."
                    showingErrorAlert = true
                }
            }
        }
    }

    private func saveImportedHeadshots() {
        guard let front = frontImage, let left = leftImage, let right = rightImage else { return }
        isAutoCropping = true

        let auditionID = audition.id
        let ratio = audition.validationRules.requiredHeadshotRatio

        Task {
            do {
                let items: [(HeadshotAngle, UIImage)] = [
                    (.front, front),
                    (.left, left),
                    (.right, right)
                ]

                var assets: [HeadshotAsset] = []

                for (angle, orig) in items {
                    let uprightOrig = await Task.detached(priority: .userInitiated) {
                        HeadshotCropMath.normalizedImage(orig)
                    }.value
                    let cropped = await ImageFramer.autoCrop(image: uprightOrig, aspectRatio: ratio)
                    let evaluation = await HeadshotGuidanceService.shared.evaluateImage(uprightOrig, for: angle)

                    let (origRel, cropRel) = try await Task.detached(priority: .userInitiated) {
                        guard let d1 = uprightOrig.jpegData(compressionQuality: 0.9),
                              let d2 = cropped.jpegData(compressionQuality: 0.9) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        let savedOrig = try MediaStorage.saveData(
                            d1,
                            relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_orig.jpg"
                        )
                        let savedCrop = try MediaStorage.saveData(
                            d2,
                            relativePath: "Headshots_\(auditionID)/\(angle.rawValue)_crop.jpg"
                        )
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
                    assets.append(asset)
                }

                await MainActor.run {
                    audition.headshots = assets
                    for idx in audition.requirements.indices {
                        if audition.requirements[idx].title.lowercased().contains("headshot") {
                            audition.requirements[idx].isCompleted = true
                        }
                    }
                    appState.saveChanges()
                    isAutoCropping = false
                    onImportSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isAutoCropping = false
                    errorMessage = "Could not save imported headshots: \(error.localizedDescription)"
                    showingErrorAlert = true
                }
            }
        }
    }
}
