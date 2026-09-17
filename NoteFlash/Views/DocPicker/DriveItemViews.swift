import SwiftUI

// MARK: - Rows (list layout)

struct DriveFolderRow: View {
    let item: DriveItem
    /// Shows the sort's date line when folders are mixed in with files.
    let sort: DriveSort?
    let showsLocation: Bool
    let context: DrivePickerContext

    var body: some View {
        HStack(spacing: 14) {
            DriveFolderIcon(shared: item.shared)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let sort {
                    Text(DriveText.activity(for: item, sort: sort))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DriveItemFootnote(item: item, showsLocation: showsLocation, context: context)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DriveDocRow: View {
    let item: DriveItem
    let sort: DriveSort
    let showsLocation: Bool
    let context: DrivePickerContext

    var body: some View {
        HStack(spacing: 14) {
            DriveThumbnailView(item: item, context: context, compact: true)
                .frame(width: 40, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(DriveText.activity(for: item, sort: sort))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DriveItemFootnote(item: item, showsLocation: showsLocation, context: context)
            }
            Spacer(minLength: 0)
            if context.linkedDocIDs.contains(item.id) {
                DeckBadge()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Cards (grid layout)

struct DriveFolderTile: View {
    let item: DriveItem

    var body: some View {
        HStack(spacing: 10) {
            DriveFolderIcon(shared: item.shared)
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}

struct DriveDocCard: View {
    let item: DriveItem
    let sort: DriveSort
    let showsLocation: Bool
    let context: DrivePickerContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DriveThumbnailView(item: item, context: context, compact: false)
                .frame(height: 130)
                .overlay(alignment: .topTrailing) {
                    if context.linkedDocIDs.contains(item.id) {
                        DeckBadge().padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FileGlyph(kind: item.kind)
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(DriveText.activity(for: item, sort: sort))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DriveItemFootnote(item: item, showsLocation: showsLocation, context: context)
            }
            .padding(10)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .contentShape(.rect)
    }
}

// MARK: - Shared pieces

/// "in Biology" / "Shared by Ms. Rivera" — helps tell same-named docs apart.
struct DriveItemFootnote: View {
    let item: DriveItem
    let showsLocation: Bool
    let context: DrivePickerContext
    @Environment(GoogleAuth.self) private var googleAuth

    var body: some View {
        let folder = showsLocation ? context.folderNames.name(for: item.parentID) : nil
        let owner = item.ownedByMe ? nil : item.ownerName
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 0, height: 0)
            if folder != nil || owner != nil {
                HStack(spacing: 10) {
                    if let folder {
                        Label(folder, systemImage: "folder")
                    }
                    if let owner {
                        Label(owner, systemImage: "person.2")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
                .lineLimit(1)
            }
        }
        .task(id: showsLocation ? item.parentID : nil) {
            guard showsLocation else { return }
            await context.folderNames.resolve(item.parentID, source: context.source, auth: googleAuth)
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

struct DriveThumbnailView: View {
    let item: DriveItem
    let context: DrivePickerContext
    /// Small list icons show the whole page; grid cards show its top part.
    let compact: Bool

    @Environment(GoogleAuth.self) private var googleAuth
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Color.clear
                    .overlay(alignment: .top) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                PagePlaceholder(kind: item.kind, compact: compact)
            }
        }
        .clipShape(.rect(cornerRadius: compact ? 5 : 0))
        .overlay {
            if compact {
                RoundedRectangle(cornerRadius: 5).stroke(.quaternary)
            }
        }
        .task(id: item.id) {
            image = await context.source.thumbnail(for: item, auth: googleAuth)
        }
        .accessibilityHidden(true)
    }
}

/// A blank page with text lines, shown until (or instead of) Drive's thumbnail.
private struct PagePlaceholder: View {
    let kind: DriveFileKind?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            ForEach(0..<(compact ? 5 : 7), id: \.self) { index in
                Capsule()
                    .fill(index == 0 ? Color.driveKind(kind).opacity(0.5) : Color.gray.opacity(0.22))
                    .frame(height: compact ? 2.5 : 5)
                    .frame(maxWidth: index == 0 ? (compact ? 16 : 70) : (index % 3 == 2 ? (compact ? 18 : 90) : .infinity),
                           alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 7 : 16)
        .overlay(alignment: .bottomTrailing) {
            if !compact {
                FileGlyph(kind: kind).padding(10)
            } else if kind != .document {
                FileGlyph(kind: kind)
                    .font(.system(size: 9))
                    .padding(3)
            }
        }
    }
}

/// The file type's icon in its Google Drive color.
struct FileGlyph: View {
    let kind: DriveFileKind?

    var body: some View {
        Image(systemName: kind?.systemImage ?? "doc.fill")
            .font(.caption)
            .foregroundStyle(Color.driveKind(kind))
            .accessibilityLabel(kind?.label ?? "File")
    }
}

struct DriveFolderIcon: View {
    let shared: Bool

    var body: some View {
        Image(systemName: shared ? "folder.fill.badge.person.crop" : "folder.fill")
            .font(.title2)
            .foregroundStyle(.gray)
            .accessibilityHidden(true)
    }
}

struct DeckBadge: View {
    var body: some View {
        Label("Deck", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.green.opacity(0.12), in: .capsule)
            .accessibilityLabel("Already a deck")
    }
}

/// Sort, order, folder, and layout options, like Drive's view menu.
struct DriveViewOptionsMenu: View {
    @Binding var sortRaw: String
    @Binding var ascending: Bool
    @Binding var layoutRaw: String
    @Binding var foldersOnTop: Bool
    /// The sorts offered here; empty where the order is fixed (Recent).
    let sortOptions: [DriveSort]
    let currentSort: DriveSort

    private var isList: Bool { layoutRaw != DriveLayout.grid.rawValue }

    var body: some View {
        Menu {
            if !sortOptions.isEmpty {
                Section("Sort By") {
                    Picker("Sort By", selection: Binding(
                        get: { currentSort },
                        set: { sortRaw = $0.rawValue }
                    )) {
                        ForEach(sortOptions) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
                SortOrderPicker(ascending: $ascending, ascendingByDefault: currentSort.ascendingByDefault) {
                    currentSort.directionLabel(ascending: $0)
                }
            }
            if isList && !sortOptions.isEmpty {
                Section("Folders") {
                    Picker("Folders", selection: $foldersOnTop) {
                        Text("On top").tag(true)
                        Text("Mixed with files").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
            Section("View") {
                Picker("View", selection: $layoutRaw) {
                    Label("List", systemImage: "list.bullet").tag(DriveLayout.list.rawValue)
                    Label("Grid", systemImage: "square.grid.2x2").tag(DriveLayout.grid.rawValue)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Sort and View", systemImage: "arrow.up.arrow.down")
        }
        .onChange(of: sortRaw) {
            ascending = currentSort.ascendingByDefault
        }
    }
}

enum DriveText {
    /// The date line that matches the current sort, as Drive shows it.
    static func activity(for item: DriveItem, sort: DriveSort) -> String {
        switch sort {
        case .opened:
            item.viewedByMeTime.map { "You opened \(short($0))" } ?? "You haven't opened this"
        case .modifiedByMe:
            item.modifiedByMeTime.map { "You modified \(short($0))" } ?? "You haven't edited this"
        case .shared:
            item.sharedWithMeTime.map { "Shared with you \(short($0))" } ?? "Not shared with you"
        case .storage:
            item.isFolder ? "Folder" : size(item.size)
        case .name, .modified:
            modified(item)
        }
    }

    static func modified(_ item: DriveItem) -> String {
        guard let date = item.modifiedTime else { return item.kind?.label ?? "Google Drive" }
        if item.lastModifiedByMe { return "Modified \(short(date)) by you" }
        if let name = item.lastModifierName { return "Modified \(short(date)) by \(name)" }
        return "Modified \(short(date))"
    }

    /// "2.4 MB", as Drive shows storage used.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "Size unknown" }
        return bytes.formatted(.byteCount(style: .file))
    }

    /// "3:04 PM", "yesterday", "Sep 3", or "Sep 3, 2024".
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday"
        }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

extension Color {
    static let docBlue = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let slidesYellow = Color(red: 0.96, green: 0.67, blue: 0.0)
    static let pdfRed = Color(red: 0.86, green: 0.2, blue: 0.18)
    static let powerPointOrange = Color(red: 0.82, green: 0.33, blue: 0.16)

    /// The color Google Drive uses for each file type.
    static func driveKind(_ kind: DriveFileKind?) -> Color {
        switch kind {
        case .document, nil: docBlue
        case .presentation: slidesYellow
        case .pdf: pdfRed
        case .powerPoint: powerPointOrange
        }
    }
}
