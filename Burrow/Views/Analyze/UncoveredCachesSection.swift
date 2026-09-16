import SwiftUI

/// Analyze-tab section listing large cache/log folders that no Clean rule
/// covers yet. Lets the user reclaim the space directly, or suggest a rule so
/// Burrow learns to clean it for everyone. Hidden when there's nothing to show.
struct UncoveredCachesSection: View {
    @ObservedObject var vm: AnalyzeViewModel

    var body: some View {
        if !vm.uncovered.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                VStack(spacing: Spacing.sm + 2) {
                    ForEach(vm.uncovered, id: \.url) { entry in
                        UncoveredRow(vm: vm, entry: entry)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Cleanable space without a rule")
                .font(.titleM)
                .foregroundStyle(Color.fgPrimary)
            Text("Large caches and logs no cleanup rule covers yet. Safe to clear — apps recreate them — or suggest a rule so Burrow cleans them automatically.")
                .font(.captionM)
                .foregroundStyle(Color.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UncoveredRow: View {
    @ObservedObject var vm: AnalyzeViewModel
    let entry: DiskEntry
    @State private var showDeleteConfirm = false

    private var style: (icon: String, tint: Color) { FolderIconStyle.style(for: entry) }

    var body: some View {
        HStack(spacing: Spacing.sm + 2) {
            iconBox
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.bodyM.weight(.medium))
                    .foregroundStyle(Color.fgPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(abbreviatedPath)
                    .font(.captionM)
                    .foregroundStyle(Color.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.sm)
            Text(entry.humanSize)
                .font(.bodyM.weight(.semibold))
                .foregroundStyle(Color.fgPrimary)
                .monospacedDigit()
            actionButton("arrow.up.forward.app", help: "Reveal in Finder") {
                vm.revealInFinder(entry)
            }
            actionButton("trash", help: "Move to Trash") {
                Task { await vm.moveToTrash(entry) }
            }
        }
        .padding(.vertical, Spacing.md + 2)
        .padding(.horizontal, Spacing.lg + 2)
        .borderedCard()
        .contextMenu {
            Button("Reveal in Finder") { vm.revealInFinder(entry) }
            Button("Move to Trash", role: .destructive) { Task { await vm.moveToTrash(entry) } }
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
            Divider()
            Button("Suggest a cleanup rule…") {
                IssueReporter.open(.feature, context: "Add a cleanup rule for `\(abbreviatedPath)` (\(entry.humanSize)).")
            }
        }
        .alert("Delete \(entry.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await vm.deletePermanently(entry) } }
        } message: {
            Text("\(entry.humanSize) will be deleted immediately, bypassing the Trash. This cannot be undone.")
        }
    }

    private var iconBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(style.tint.opacity(0.12))
            Image(systemName: style.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(style.tint)
        }
        .frame(width: 36, height: 36)
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.fgMuted)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Path with the home directory abbreviated to `~`.
    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = entry.url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
        return path
    }
}
