import SwiftUI
import AppKit

/// Finder-style icon view with image thumbnails.
struct FileGridView: View {
    @Bindable var model: BrowserModel
    @Binding var showInspector: Bool
    @FocusState private var isFocused: Bool
    @State private var columnCount = 1

    private static let tileWidth: CGFloat = 108
    private static let columnSpacing: CGFloat = 6
    private static let padding: CGFloat = 20

    var body: some View {
        ScrollViewReader { proxy in
            grid
                .onChange(of: model.selectionCursor) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
                }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: 128), spacing: Self.columnSpacing, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(model.displayedItems) { item in
                    FileTile(
                        item: item,
                        isSelected: model.selection.contains(item.id),
                        model: model,
                        showInspector: $showInspector
                    )
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // Matches how an adaptive GridItem fits columns, so up and down move by one row.
            let available = width - Self.padding * 2 + Self.columnSpacing
            columnCount = max(1, Int(available / (Self.tileWidth + Self.columnSpacing)))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = []
            isFocused = true
        }
        .contextMenu {
            ItemContextMenu(model: model, ids: [], showInspector: $showInspector)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .browserKeyCommands(model)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                guard press.key == .downArrow else { return .ignored }
                model.openSelection()
                return .handled
            }
            let offset = switch press.key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -columnCount
            default: columnCount
            }
            model.moveSelection(by: offset, extend: press.modifiers.contains(.shift))
            return .handled
        }
    }
}

private struct FileTile: View {
    let item: BrowserItem
    let isSelected: Bool
    let model: BrowserModel
    @Binding var showInspector: Bool
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(item: item, model: model, size: 64)
                .frame(width: 76, height: 76)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.10 : 0))
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    }
                }
                .scaleEffect(isTargeted ? 1.08 : 1)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? Color.accentColor : .clear)
                }
                .frame(maxWidth: 112)

            if !item.isFolder {
                Text(Format.bytes(item.size))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .opacity(isSelected ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item) }
        .simultaneousGesture(
            TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                model.select(item, extend: flags.contains(.command), range: flags.contains(.shift))
            }
        )
        .contextMenu {
            ItemContextMenu(
                model: model,
                ids: isSelected ? model.selection : [item.id],
                showInspector: $showInspector
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls, into: item.isFolder ? item.key : model.prefix)
            return true
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.18)) { isTargeted = targeted && item.isFolder }
        }
        .help(item.displayPath)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .modifier(DragOut(item: item, model: model))
    }
}

/// Lets files be dragged to the Finder; folders stay put.
private struct DragOut: ViewModifier {
    let item: BrowserItem
    let model: BrowserModel

    func body(content: Content) -> some View {
        if item.isFolder {
            content
        } else {
            content.onDrag { model.dragItemProvider(for: item) ?? NSItemProvider() }
        }
    }
}
