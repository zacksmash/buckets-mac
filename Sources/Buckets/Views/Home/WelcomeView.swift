import SwiftUI

/// First-run experience, in the spirit of Apple's "Welcome to…" sheets.
struct WelcomeView: View {
    let onAdd: () -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AppIconView(size: 116)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 24)

                Text("Welcome to Buckets")
                    .font(.system(size: 34, weight: .bold))

                Text("Browse and manage Cloudflare R2 and S3‑compatible storage\nwith the ease of the Finder.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 22) {
                    FeatureRow(
                        symbol: "square.stack.3d.up.fill",
                        color: .blue,
                        title: "All Your Buckets",
                        detail: "Save connections to as many buckets and accounts as you like, each with its own credentials."
                    )
                    FeatureRow(
                        symbol: "tray.and.arrow.down.fill",
                        color: .green,
                        title: "Drag and Drop",
                        detail: "Drop files and whole folders anywhere to upload. Large files are uploaded in parts automatically."
                    )
                    FeatureRow(
                        symbol: "doc.text.magnifyingglass",
                        color: .purple,
                        title: "Preview and Edit",
                        detail: "Quick Look any file, and edit text and config files right in the bucket."
                    )
                    FeatureRow(
                        symbol: "lock.shield.fill",
                        color: .orange,
                        title: "Secure by Design",
                        detail: "Secret keys are stored in your Mac's Keychain and never leave this device."
                    )
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.vertical, 40)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)

                Button(action: onAdd) {
                    Text("Add Your First Connection")
                        .frame(minWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 56)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.3).delay(0.05)) { appeared = true }
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(color.gradient)
                .frame(width: 44, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
