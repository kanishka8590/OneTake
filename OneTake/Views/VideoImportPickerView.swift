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
                selectedVideoItem = nil
                importVideo(from: item)
            }
        }
    }

    private func importVideo(from item: PhotosPickerItem) {
        isImporting = true
        errorMessage = nil

        Task {
            do {
                guard let movie = try await item.loadTransferable(type: MovieTransferable.self) else {
                    await MainActor.run {
                        self.isImporting = false
                        self.errorMessage = "Could not load video file."
                    }
                    return
                }
                defer {
                    try? FileManager.default.removeItem(at: movie.url)
                }

                let ext = movie.url.pathExtension.isEmpty ? "mp4" : movie.url.pathExtension
                let filename = "Imported_\(isSlate ? "Slate" : "Audition")_\(UUID().uuidString.prefix(6)).\(ext)"
                let relativePath = "Takes_\(audition.id)/\(filename)"
                let storedPath = try MediaStorage.copyItem(from: movie.url, toRelativePath: relativePath)

                guard let targetURL = MediaStorage.resolveURL(for: storedPath) else {
                    await MainActor.run {
                        self.isImporting = false
                        self.errorMessage = "Could not resolve imported video destination."
                    }
                    return
                }

                let metadata = await VideoPostProcessingService.inspectTrackMetadata(at: targetURL)
                guard metadata.durationSeconds > 0 else {
                    MediaStorage.removeFile(at: storedPath)
                    await MainActor.run {
                        self.isImporting = false
                        self.errorMessage = "Imported video has no valid playable duration."
                    }
                    return
                }

                let takeCount = isSlate ? audition.slateTakes.count + 1 : audition.auditionTakes.count + 1
                let newTake = VideoTake(
                    title: "Imported Take \(takeCount)",
                    filePath: storedPath,
                    durationSeconds: metadata.durationSeconds,
                    fileSizeMB: metadata.fileSizeMB,
                    aspectRatioString: metadata.aspectRatioString,
                    isPortrait: metadata.isPortrait,
                    isMirrored: false,
                    noiseCleaned: false,
                    trimStartSeconds: 0,
                    trimEndSeconds: metadata.durationSeconds,
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
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return Self(url: copyURL)
        }
    }
}
