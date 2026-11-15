import SwiftUI

struct HeadshotPackageGridView: View {
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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
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

                        // 3-photo collage grid
                        HStack(spacing: 12) {
                            headshotCard(title: "Front", angle: .front, image: frontCropped)
                            headshotCard(title: "Left Profile", angle: .left, image: leftCropped)
                            headshotCard(title: "Right Profile", angle: .right, image: rightCropped)
                        }
                        .padding(.horizontal, 16)

                        // Ratio info banner
                        HStack(spacing: 8) {
                            Image(systemName: "aspectratio")
                                .foregroundStyle(Theme.Colors.accent)
                            Text("Standard Casting Format: \(audition.validationRules.requiredHeadshotRatio.rawValue) Theatrical Ratio")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Theme.Colors.lavenderSurface)
                        .clipShape(Capsule())

                        // Import alternative
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

                        Spacer(minLength: 40)

                        // Confirm & Save
                        Button {
                            savePackageToAudition()
                        } label: {
                            Text("Save Headshots to Audition")
                                .primaryCapsuleButton()
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 36)
                        .disabled(frontCropped == nil || leftCropped == nil || rightCropped == nil)
                    }
                }
            }
            .navigationTitle("Headshot Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
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
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.Colors.accent.opacity(0.28), lineWidth: 1))

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
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

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let headshotsDir = docs.appendingPathComponent("Headshots_\(audition.id)", isDirectory: true)
        try? fm.createDirectory(at: headshotsDir, withIntermediateDirectories: true)

        var newAssets: [HeadshotAsset] = []

        let items: [(HeadshotAngle, UIImage, UIImage?)] = [
            (.front, front, frontOriginal),
            (.left, left, leftOriginal),
            (.right, right, rightOriginal)
        ]

        for (angle, cropped, orig) in items {
            let origPath = headshotsDir.appendingPathComponent("\(angle.rawValue)_orig.jpg").path
            let cropPath = headshotsDir.appendingPathComponent("\(angle.rawValue)_crop.jpg").path

            if let origData = (orig ?? cropped).jpegData(compressionQuality: 0.9) {
                try? origData.write(to: URL(fileURLWithPath: origPath))
            }
            if let cropData = cropped.jpegData(compressionQuality: 0.9) {
                try? cropData.write(to: URL(fileURLWithPath: cropPath))
            }

            let asset = HeadshotAsset(
                angle: angle,
                originalFilePath: origPath,
                croppedFilePath: cropPath,
                aspectRatio: audition.validationRules.requiredHeadshotRatio,
                cropPreset: .theatrical,
                lightingPassed: true,
                backgroundPassed: true,
                alignmentPassed: true,
                eyeLevelPassed: true,
                capturedAt: Date()
            )
            newAssets.append(asset)
        }

        audition.headshots = newAssets

        // Update requirements checklist
        if let idx = audition.requirements.firstIndex(where: { $0.title.lowercased().contains("headshot") }) {
            audition.requirements[idx].isCompleted = true
        }

        onSaveCompleted()
        dismiss()
    }
}
