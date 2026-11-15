import SwiftUI
import PhotosUI
import AVFoundation

struct VideoImportPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    let isSlate: Bool
    let onImportCompleted: (VideoTake) -> Void

    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 54))
                        .foregroundStyle(Theme.Colors.accent)
                        .padding(.top, 36)

                    VStack(spacing: 8) {
                        Text("Import \(isSlate ? "Slate" : "Audition") Video")
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text("Select a previously recorded video from your Photo Library.")
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if isImporting {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Processing video import...")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding()
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.errorCrimson)
                            .padding(.horizontal, 24)
                    }

                    Spacer()

                    PhotosPicker(
                        selection: $selectedVideoItem,
                        matching: .videos,
                        preferredItemEncoding: .current
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle")
                            Text("Choose from Photos")
                        }
                        .primaryCapsuleButton()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                    .disabled(isImporting)
                }
            }
            .navigationTitle("Import Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedVideoItem) { _, item in
                guard let item = item else { return }
                importVideo(from: item)
            }
        }
    }

    private func importVideo(from item: PhotosPickerItem) {
        isImporting = true
        errorMessage = nil

        Task {
            do {
                if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let dir = docs.appendingPathComponent("Takes_\(audition.id)", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                    let filename = "Imported_\(isSlate ? "Slate" : "Audition")_\(UUID().uuidString.prefix(6)).mp4"
                    let targetURL = dir.appendingPathComponent(filename)

                    try? FileManager.default.removeItem(at: targetURL)
                    try FileManager.default.copyItem(at: movie.url, to: targetURL)

                    let asset = AVURLAsset(url: targetURL)
                    let duration = (try? await asset.load(.duration).seconds) ?? 15.0
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Double) ?? 10_000_000.0
                    let sizeMB = fileSize / (1024.0 * 1024.0)

                    let takeCount = isSlate ? audition.slateTakes.count + 1 : audition.auditionTakes.count + 1
                    let newTake = VideoTake(
                        title: "Imported Take \(takeCount)",
                        filePath: targetURL.path,
                        durationSeconds: duration,
                        fileSizeMB: sizeMB,
                        aspectRatioString: "16:9",
                        isPortrait: false,
                        isMirrored: false,
                        noiseCleaned: false,
                        trimStartSeconds: 0,
                        trimEndSeconds: duration,
                        lightingPassed: true,
                        framingPassed: true,
                        soundPassed: true,
                        createdAt: Date()
                    )

                    await MainActor.run {
                        self.isImporting = false
                        self.onImportCompleted(newTake)
                        self.dismiss()
                    }
                } else {
                    await MainActor.run {
                        self.isImporting = false
                        self.errorMessage = "Could not load video file."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.errorMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// Transferable helper for video file imports
struct MovieTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return Self(url: copyURL)
        }
    }
}
