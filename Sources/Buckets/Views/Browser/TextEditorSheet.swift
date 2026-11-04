import SwiftUI
import AppKit

struct TextEditorSheet: View {
    let document: TextDocument
    let model: BrowserModel

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var savedText: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmDiscard = false
    @State private var justSaved = false

    init(document: TextDocument, model: BrowserModel) {
        self.document = document
        self.model = model
        _text = State(initialValue: document.original)
        _savedText = State(initialValue: document.original)
    }

    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CodeTextView(text: $text)
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 480, idealHeight: 640)
        .confirmationDialog(
            "Discard changes to “\(document.item.name)”?",
            isPresented: $confirmDiscard
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved to the bucket.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            FileIconView(item: document.item, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(document.item.name)
                        .font(.system(size: 13, weight: .semibold))
                    if isDirty {
                        Text("Edited")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if justSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                Text("\(model.connection.bucket)/\(document.item.key)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(stats)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .animation(.snappy, value: isDirty)
        .animation(.snappy, value: justSaved)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(document.contentType)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Close") {
                if isDirty { confirmDiscard = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.glass)

            Button {
                save(thenClose: false)
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Save")
                }
                .frame(minWidth: 56)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.glassProminent)
            .disabled(!isDirty || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stats: String {
        let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        let bytes = Int64(text.lengthOfBytes(using: document.encoding))
        return "\(lines.formatted()) \(lines == 1 ? "line" : "lines") · \(Format.bytes(bytes))"
    }

    private func save(thenClose: Bool) {
        let snapshot = text
        isSaving = true
        saveError = nil
        Task {
            do {
                try await model.save(document, text: snapshot)
                savedText = snapshot
                justSaved = true
                if thenClose { dismiss() }
                try? await Task.sleep(for: .seconds(2))
                justSaved = false
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// Plain-text editor tuned for code and config: no smart quotes or autocorrect.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
