import SwiftUI

/// Always-visible header with row count, selection count, Mark Read/Unread,
/// and Clear. Shared by the threads list and search results — both have the
/// same shape, only the data behind it differs.
struct BulkActionHeader: View {
    let totalCount: Int
    /// Singular/plural label for `totalCount` — e.g. `{ "\($0) threads" }`.
    let totalLabel: (Int) -> String
    let selectedCount: Int
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onClearSelection: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(totalLabel(totalCount))
                .font(.callout)
                .foregroundStyle(.secondary)
            if selectedCount > 1 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(selectedCount) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onMarkRead) {
                Label("Mark Read", systemImage: "envelope.open")
            }
            .disabled(selectedCount == 0)
            Button(action: onMarkUnread) {
                Label("Mark Unread", systemImage: "envelope.badge")
            }
            .disabled(selectedCount == 0)
            if selectedCount > 1 {
                Button("Clear", action: onClearSelection)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }
}
