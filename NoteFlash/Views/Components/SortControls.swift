import SwiftUI

/// "A to Z" / "Z to A" choices, with the sort's usual direction first.
struct SortOrderPicker: View {
    @Binding var ascending: Bool
    let ascendingByDefault: Bool
    let label: (Bool) -> String

    var body: some View {
        Section("Order") {
            Picker("Order", selection: $ascending) {
                Text(label(ascendingByDefault)).tag(ascendingByDefault)
                Text(label(!ascendingByDefault)).tag(!ascendingByDefault)
            }
            .pickerStyle(.inline)
        }
    }
}

/// "Last modified ↓" — tap to flip the order, like a column header in Drive.
struct SortHeaderButton: View {
    let label: String
    @Binding var ascending: Bool
    let directionLabel: String

    var body: some View {
        Button {
            ascending.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.bold))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sorted by \(label), \(directionLabel)")
        .accessibilityHint("Double-tap to reverse the order")
    }
}
