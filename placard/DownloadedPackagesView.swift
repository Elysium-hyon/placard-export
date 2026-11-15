import SwiftUI

/// Packages kept from earlier downloads. These are the original `.tendies`
/// files, so exporting one is a straight copy — no repacking.
struct DownloadedPackagesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var packages: [StoredWallpaperPackage] = []
    @State private var exporter = WallpaperExportManager()
    @State private var pendingDeletion: StoredWallpaperPackage?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Downloaded Packages")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Export All", systemImage: "square.and.arrow.up") {
                            exporter.export(stored: packages)
                        }
                        .disabled(packages.isEmpty || exporter.state.isWorking)
                    }
                }
        }
        .task { reload() }
        .overlay {
            if case .working(let message) = exporter.state {
                ProgressView(message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
        .background {
            Color.clear
                .sheet(isPresented: sharingBinding) {
                    ActivityShareSheet(items: exporter.sharedURLs)
                }
                .alert(
                    "Unable to Export",
                    isPresented: failureBinding
                ) {
                    Button("OK", role: .cancel) { exporter.reset() }
                } message: {
                    Text(exporter.failureMessage ?? "")
                }
        }
        .alert(
            "Delete Package?",
            isPresented: deletionBinding,
            presenting: pendingDeletion
        ) { package in
            Button("Delete", role: .destructive) {
                try? WallpaperPackageStore.remove(package)
                pendingDeletion = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { package in
            Text("“\(package.name)” will be removed from the app. Wallpapers already installed are unaffected.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if packages.isEmpty {
            ContentUnavailableView(
                "No Downloaded Packages",
                systemImage: "shippingbox",
                description: Text("Packages downloaded from the catalog are kept here as .tendies files.")
            )
        } else {
            List {
                Section("\(packages.count) packages") {
                    ForEach(packages) { package in
                        row(package)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = package
                                }
                            }
                            .contextMenu {
                                Button("Export", systemImage: "square.and.arrow.up") {
                                    exporter.export(stored: [package])
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = package
                                }
                            }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(_ package: StoredWallpaperPackage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(package.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: package.bytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var sharingBinding: Binding<Bool> {
        Binding(
            get: { exporter.isSharing },
            set: { if !$0 { exporter.reset() } }
        )
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { exporter.failureMessage != nil },
            set: { if !$0 { exporter.reset() } }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func reload() {
        packages = WallpaperPackageStore.all()
    }
}

#Preview("Downloaded packages") {
    DownloadedPackagesView()
}
