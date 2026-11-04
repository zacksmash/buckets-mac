import SwiftUI

struct ConnectionEditorView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let onSaved: (Connection) -> Void

    @State private var draft: Connection
    @State private var secret: String
    @State private var revealSecret = false
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var testTask: Task<Void, Never>?
    @State private var showSymbolPicker = false
    private let existingID: UUID?
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case name, account, endpoint, region, bucket, accessKey, secret }

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    init(connection: Connection?, onSaved: @escaping (Connection) -> Void = { _ in }) {
        isNew = connection == nil
        self.onSaved = onSaved
        _draft = State(initialValue: connection ?? Connection())
        existingID = connection?.id
        _secret = State(initialValue: "")
    }

    private var isValid: Bool {
        draft.endpointURL != nil
            && !draft.bucket.trimmed.isEmpty
            && !draft.accessKeyID.trimmed.isEmpty
            && !secret.trimmed.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    identityHeader
                }

                Section {
                    Picker("Service", selection: $draft.provider) {
                        ForEach(StorageProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.provider == .cloudflareR2 {
                        LabeledContent("Account ID") {
                            TextField("Account ID", text: $draft.accountID, prompt: Text("32-character ID"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .font(.system(.body, design: .monospaced))
                                .focused($focusedField, equals: .account)
                        }
                        Picker("Jurisdiction", selection: $draft.jurisdiction) {
                            ForEach(R2Jurisdiction.allCases) { jurisdiction in
                                Text(jurisdiction.displayName).tag(jurisdiction)
                            }
                        }
                    } else {
                        TextField("Endpoint", text: $draft.customEndpoint, prompt: Text("https://s3.us-east-1.amazonaws.com"))
                            .focused($focusedField, equals: .endpoint)
                        TextField("Region", text: $draft.region, prompt: Text("us-east-1"))
                            .focused($focusedField, equals: .region)
                    }

                    TextField("Bucket", text: $draft.bucket, prompt: Text("my-bucket"))
                        .focused($focusedField, equals: .bucket)

                    LabeledContent("Endpoint URL") {
                        Text(draft.endpointURL?.absoluteString ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    if draft.provider == .cloudflareR2 {
                        Text("Find your Account ID in the Cloudflare dashboard under **R2 Object Storage**. You can also paste the full S3 API URL.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Access Key ID") {
                        TextField("Access Key ID", text: $draft.accessKeyID, prompt: Text("Required"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .focused($focusedField, equals: .accessKey)
                    }
                    LabeledContent("Secret Access Key") {
                        HStack(spacing: 6) {
                            Group {
                                if revealSecret {
                                    TextField("Secret Access Key", text: $secret, prompt: Text("Required"))
                                } else {
                                    SecureField("Secret Access Key", text: $secret, prompt: Text("Required"))
                                }
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .focused($focusedField, equals: .secret)

                            Button {
                                revealSecret.toggle()
                            } label: {
                                Image(systemName: revealSecret ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                            }
                            .buttonStyle(.borderless)
                            .help(revealSecret ? "Hide Secret" : "Show Secret")
                        }
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    Label("Your secret access key is stored securely in your Mac's Keychain.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.accountID) { _, value in absorbPastedEndpoint(value) }
            .onChange(of: draft.provider) { _, _ in testState = .idle }

            footer
        }
        .frame(width: 540)
        .frame(minHeight: 460, idealHeight: 640, maxHeight: 660)
        .onAppear {
            focusedField = isNew ? .name : nil
        }
        .onDisappear { testTask?.cancel() }
        .task {
            // Read the Keychain off the main thread: it may show a system prompt.
            guard let id = existingID, secret.isEmpty else { return }
            let stored = await Task.detached(priority: .userInitiated) { Keychain.secret(for: id) }.value
            if secret.isEmpty, let stored { secret = stored }
        }
    }

    // MARK: - Identity

    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            Button {
                showSymbolPicker.toggle()
            } label: {
                ConnectionIcon(tint: draft.tint, symbol: draft.symbol, size: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(nsColor: .darkGray))
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                            .offset(x: 5, y: 5)
                    }
                    .animation(.snappy, value: draft.tint)
                    .animation(.snappy, value: draft.symbol)
            }
            .buttonStyle(.plain)
            .help("Choose an Icon")
            .accessibilityLabel("Choose an Icon")
            .popover(isPresented: $showSymbolPicker, arrowEdge: .bottom) {
                symbolPicker
            }

            VStack(alignment: .leading, spacing: 11) {
                TextField(
                    "Name",
                    text: $draft.name,
                    prompt: Text(draft.bucket.trimmed.isEmpty ? "Connection Name" : draft.bucket)
                )
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focusedField, equals: .name)

                HStack(spacing: 5) {
                    ForEach(ConnectionTint.allCases) { tint in
                        Button {
                            draft.tint = tint
                        } label: {
                            Circle()
                                .fill(tint.gradient)
                                .frame(width: 19, height: 19)
                                .padding(3)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.secondary.opacity(draft.tint == tint ? 0.55 : 0), lineWidth: 2)
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(tint.displayName)
                        .accessibilityLabel(tint.displayName)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbolPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 10), count: 4), spacing: 10) {
            ForEach(Connection.symbols, id: \.self) { symbol in
                let selected = draft.symbol == symbol
                Button {
                    draft.symbol = symbol
                    showSymbolPicker = false
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(
                    Circle().fill(selected ? AnyShapeStyle(draft.tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                )
            }
        }
        .padding(14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                runTest()
            } label: {
                Text("Test Connection")
            }
            .buttonStyle(.glass)
            .disabled(!isValid || testState == .testing)

            testStatus

            Spacer(minLength: 8)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)

            Button(isNew ? "Add Connection" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var testStatus: some View {
        switch testState {
        case .idle:
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case let .success(message):
            Label {
                Text(message).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case let .failure(message):
            Label {
                Text(message).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .font(.system(size: 11))
            .lineLimit(2)
            .help(message)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    // MARK: - Actions

    private func normalizedDraft() -> Connection {
        var connection = draft
        connection.accountID = connection.accountID.trimmed
        connection.customEndpoint = connection.customEndpoint.trimmed
        connection.region = connection.region.trimmed
        connection.bucket = connection.bucket.trimmed
        connection.accessKeyID = connection.accessKeyID.trimmed
        connection.name = connection.name.trimmed
        return connection
    }

    private func runTest() {
        testTask?.cancel()
        let connection = normalizedDraft()
        let secret = self.secret.trimmed
        withAnimation(.snappy) { testState = .testing }
        testTask = Task {
            do {
                let client = try S3Client(connection: connection, secret: secret)
                let result = try await client.testConnection()
                let count = result.hasMore ? "\(result.count)+" : "\(result.count)"
                let noun = result.count == 1 && !result.hasMore ? "item" : "items"
                withAnimation(.snappy) { testState = .success("Connected · \(count) \(noun) at the top level") }
            } catch {
                guard !isCancellation(error) else { return }
                withAnimation(.snappy) { testState = .failure(error.localizedDescription) }
            }
        }
    }

    private func save() {
        let connection = normalizedDraft()
        do {
            try store.save(connection, secret: secret.trimmed)
            onSaved(connection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Accepts a pasted R2 S3 API URL (with or without bucket) in the Account ID field.
    private func absorbPastedEndpoint(_ value: String) {
        testState = .idle
        let trimmed = value.trimmed
        guard trimmed.contains("r2.cloudflarestorage.com") else { return }
        let raw = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: raw), let host = url.host else { return }
        let labels = host.split(separator: ".")
        guard let account = labels.first else { return }
        if labels.count > 1, labels[1] == "eu" { draft.jurisdiction = .eu }
        if labels.count > 1, labels[1] == "fedramp" { draft.jurisdiction = .fedramp }
        let bucket = url.path.split(separator: "/").first.map(String.init)
        DispatchQueue.main.async {
            draft.accountID = String(account)
            if let bucket, draft.bucket.trimmed.isEmpty { draft.bucket = bucket }
        }
    }
}
