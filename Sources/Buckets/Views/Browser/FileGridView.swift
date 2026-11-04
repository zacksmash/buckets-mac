import SwiftUI
import AppKit

/// Finder-style icon view with image thumbnails.
struct FileGridView: View {
    @Bindable var model: BrowserModel
    @Binding var showInspector: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108, maximum: 128), spacing: 6, alignment: .top)],
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
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard model.selection.count == 1 else { return .ignored }
            model.openSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            model.selection = []
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard press.modifiers.contains(.command) || press.key == .deleteForward else { return .ignored }
            model.requestDelete(model.selection)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAll()
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
    }
}
