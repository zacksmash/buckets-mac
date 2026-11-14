import SwiftUI

extension View {
    /// Finder's keys shared by the list and icon views: Space, Return, ⌘⌫, Escape and ⌘A.
    func browserKeyCommands(_ model: BrowserModel) -> some View {
        self
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
