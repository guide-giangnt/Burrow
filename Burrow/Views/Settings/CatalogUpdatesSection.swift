import SwiftUI

/// The "Cleaning Rules" section of Settings. Rule catalogs (Clean + Uninstall)
/// update independently of the app binary, so this mirrors the app-update
/// "Updates" section: current versions, last-checked, and a manual check.
struct CatalogUpdatesSection: View {
    @ObservedObject var vm: CatalogUpdateViewModel

    var body: some View {
        Section("Cleaning Rules") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rule catalogs update on their own, between app releases.")
                        .font(.bodyS)
                        .foregroundStyle(Color.fgSecondary)
                    Text(versionLine)
                        .font(.captionM)
                        .foregroundStyle(Color.fgMuted)
                        .monospacedDigit()
                }
                Spacer(minLength: Spacing.md)
                if vm.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { Task { await vm.checkNow() } }
                }
            }

            if let status = vm.statusMessage {
                Text(status)
                    .font(.captionM)
                    .foregroundStyle(Color.fgSecondary)
            }
        }
    }

    private var versionLine: String {
        var parts = ["Clean v\(vm.cleanRulesVersion)", "Uninstall v\(vm.appLeftoversVersion)"]
        if let last = vm.lastChecked {
            parts.append("checked \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
