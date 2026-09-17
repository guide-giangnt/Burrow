import SwiftUI

/// One labelled group in the body grid: section label on top, then a
/// single rounded card containing the group's category rows. Per the
/// design directions in CLAUDE_CODE_KICKOFF.md, rows share one card
/// background and the gap between them is the only divider.
struct CategoryGroupSection: View {
    let group: CategoryGroup
    let categories: [CleanCategory]
    @ObservedObject var vm: CleanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                SectionLabel(text: displayName(for: group))
                Spacer(minLength: Spacing.sm)
                HStack(spacing: Spacing.xs + 2) {
                    Text("Select all")
                        .font(.captionM)
                        .foregroundStyle(Color.fgSecondary)
                    BurrowCheckbox(isOn: groupBinding)
                }
                .tooltip("Select all in \(displayName(for: group))")
            }
            VStack(spacing: Spacing.xs) {
                ForEach(categories) { category in
                    CategoryRow(
                        category: category,
                        scanResult: vm.scanResults[category.id],
                        isSelected: binding(for: category.id),
                        onReveal: { vm.revealInFinder(category) }
                    )
                }
            }
            .cardStyle()
        }
    }

    /// Checkbox state for the whole group: on when every category is selected,
    /// and toggling selects all / clears all (a partial state selects the rest).
    private var groupBinding: Binding<Bool> {
        Binding(
            get: { vm.isGroupSelected(categories) },
            set: { _ in vm.toggleGroup(categories) }
        )
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedCategoryIds.contains(id) },
            set: { isOn in
                if isOn { vm.selectedCategoryIds.insert(id) }
                else    { vm.selectedCategoryIds.remove(id) }
            }
        )
    }

    private func displayName(for group: CategoryGroup) -> String {
        switch group.rawValue {
        case "system":    return "System Junk"
        case "browser":   return "Browsers"
        case "developer": return "Developer Tools"
        default:          return group.rawValue.capitalized
        }
    }
}
