import SwiftUI
import AVKit

struct TakesListView: View {
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    let isSlate: Bool
    @Binding var takes: [VideoTake]
    @Binding var selectedTakeID: UUID?

    @State private var showingRenameAlert = false
    @State private var takeToRename: VideoTake?
    @State private var renameBuffer: String = ""
    @State private var showingVideoImporter = false
    @State private var previewTake: VideoTake?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                if takes.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text("No takes recorded yet.")
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                } else {
                    List {
                        Section("All Takes (\(takes.count))") {
                            ForEach(takes) { take in
                                HStack(spacing: 12) {
                                    // Radio selection for final take
                                    Button {
                                        withAnimation {
                                            selectedTakeID = take.id
                                        }
                                    } label: {
                                        Image(systemName: selectedTakeID == take.id ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(selectedTakeID == take.id ? Theme.Colors.successGreen : Theme.Colors.textSecondary)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(take.title)
                                                .font(Theme.Typography.cardTitle)
                                                .foregroundStyle(Theme.Colors.textPrimary)

                                            if selectedTakeID == take.id {
                                                Text("FINAL TAKE")
                                                    .statusBadge(color: Theme.Colors.successGreen)
                                            }
                                        }

                                        HStack(spacing: 8) {
                                            Text(String(format: "%.1fs", take.durationSeconds))
                                            Text("•")
                                            Text(String(format: "%.1f MB", take.fileSizeMB))
                                            if take.noiseCleaned {
                                                Text("• Clean Audio")
                                                    .foregroundStyle(Theme.Colors.primaryPlum)
                                            }
                                        }
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    }

                                    Spacer()

                                    // Preview button
                                    Button {
                                        previewTake = take
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(Theme.Colors.primaryPlum)
                                    }
                                    .buttonStyle(.plain)

                                    // 3-dots native menu: Rename, Delete
                                    Menu {
                                        Button {
                                            takeToRename = take
                                            renameBuffer = take.title
                                            showingRenameAlert = true
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }

                                        Button(role: .destructive) {
                                            deleteTake(take)
                                        } label: {
                                            Label("Delete Take", systemImage: "trash")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 18))
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                            .frame(width: 32, height: 32)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .onDelete(perform: deleteTakes)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(isSlate ? "Slate Takes" : "Audition Takes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingVideoImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .alert("Rename Take", isPresented: $showingRenameAlert) {
                TextField("Take Title", text: $renameBuffer)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let toRename = takeToRename, let idx = takes.firstIndex(where: { $0.id == toRename.id }) {
                        takes[idx].title = renameBuffer.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            .sheet(item: $previewTake) { take in
                VideoTakePlayerSheet(take: take)
            }
            .sheet(isPresented: $showingVideoImporter) {
                VideoImportPickerView(audition: audition, isSlate: isSlate) { importedTake in
                    takes.append(importedTake)
                    selectedTakeID = importedTake.id
                }
            }
        }
    }

    private func deleteTake(_ take: VideoTake) {
        if let idx = takes.firstIndex(where: { $0.id == take.id }) {
            takes.remove(at: idx)
            try? FileManager.default.removeItem(atPath: take.filePath)
            if selectedTakeID == take.id {
                selectedTakeID = takes.first?.id
            }
        }
    }

    private func deleteTakes(at offsets: IndexSet) {
        for idx in offsets {
            let take = takes[idx]
            try? FileManager.default.removeItem(atPath: take.filePath)
        }
        takes.remove(atOffsets: offsets)
        if !takes.contains(where: { $0.id == selectedTakeID }) {
            selectedTakeID = takes.first?.id
        }
    }
}

// Simple playback sheet for a take
struct VideoTakePlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let take: VideoTake

    var body: some View {
        NavigationStack {
            let url = URL(fileURLWithPath: take.filePath)
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationTitle(take.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
