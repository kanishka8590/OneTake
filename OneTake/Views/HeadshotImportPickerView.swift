import SwiftUI
import PhotosUI

struct HeadshotImportPickerView: View {
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

                        // 3 Slot Pickers
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

                        Spacer(minLength: 30)

                        Button {
                            saveImportedHeadshots()
                        } label: {
                            if isAutoCropping {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Save Imported Headshots")
                            }
                        }
                        .primaryCapsuleButton()
                        .disabled(!isReadyToSave || isAutoCropping)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 36)
                    }
                }
            }
            .navigationTitle("Photo Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
                        .foregroundStyle(Theme.Colors.primaryPlum)
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
                    .foregroundStyle(Theme.Colors.primaryPlum)
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
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                await MainActor.run {
                    completion(img)
                }
            }
        }
    }

    private func saveImportedHeadshots() {
        guard let front = frontImage, let left = leftImage, let right = rightImage else { return }
        isAutoCropping = true

        Task {
            let ratio = audition.validationRules.requiredHeadshotRatio
            let frontCrop = await ImageFramer.autoCrop(image: front, aspectRatio: ratio)
            let leftCrop = await ImageFramer.autoCrop(image: left, aspectRatio: ratio)
            let rightCrop = await ImageFramer.autoCrop(image: right, aspectRatio: ratio)

            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("Headshots_\(audition.id)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var assets: [HeadshotAsset] = []
            let items: [(HeadshotAngle, UIImage, UIImage)] = [
                (.front, frontCrop, front),
                (.left, leftCrop, left),
                (.right, rightCrop, right)
            ]

            for (angle, cropped, orig) in items {
                let origPath = dir.appendingPathComponent("\(angle.rawValue)_orig.jpg").path
                let cropPath = dir.appendingPathComponent("\(angle.rawValue)_crop.jpg").path

                if let d1 = orig.jpegData(compressionQuality: 0.9) { try? d1.write(to: URL(fileURLWithPath: origPath)) }
                if let d2 = cropped.jpegData(compressionQuality: 0.9) { try? d2.write(to: URL(fileURLWithPath: cropPath)) }

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
                assets.append(asset)
            }

            await MainActor.run {
                audition.headshots = assets
                if let idx = audition.requirements.firstIndex(where: { $0.title.lowercased().contains("headshot") }) {
                    audition.requirements[idx].isCompleted = true
                }
                isAutoCropping = false
                onImportSaved()
                dismiss()
            }
        }
    }
}
