import AuthenticationServices
import SwiftUI

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.snappy, value: progress)
    }
}

struct StatPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 16))
    }
}

struct SyncBadgeView: View {
    let badge: SyncBadge

    var body: some View {
        Text(badge.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(badge == .new ? Color.green : Color.blue)
            .background((badge == .new ? Color.green : Color.blue).opacity(0.15), in: .capsule)
    }
}

/// One-line status for a deck linked to a Google Doc.
struct SyncStatusLabel: View {
    let deck: Deck
    @Environment(DocSyncService.self) private var sync

    var body: some View {
        if sync.isBusy(deck) {
            Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
        } else if deck.lastSyncError != nil {
            Label("Sync issue", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if !deck.autoSync {
            Label("Sync paused", systemImage: "pause.circle")
        } else if let checked = deck.lastCheckedAt {
            Label {
                Text("Checked \(checked, format: .relative(presentation: .named))")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        } else {
            Label("Linked", systemImage: "link")
        }
    }
}

struct WorkingOverlay: View {
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
        .transition(.opacity)
    }
}

/// Sign-in controls for reading private Google Docs.
struct GoogleAccountSection: View {
    @Environment(GoogleAuth.self) private var googleAuth
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if !googleAuth.isConfigured {
                Label("Google sign-in isn't set up", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if googleAuth.isSignedIn {
                LabeledContent("Signed in", value: googleAuth.email ?? "Google account")
                Button("Sign Out", role: .destructive) {
                    googleAuth.signOut()
                }
            } else {
                Button {
                    signIn()
                } label: {
                    HStack {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        if isSigningIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningIn)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Google Account")
        } footer: {
            if googleAuth.isConfigured {
                Text("Signing in lets NoteFlash read your private Google Docs (read-only). Docs shared as “Anyone with the link” work without signing in.")
            } else {
                Text("Add your OAuth client ID in AppConfig.swift to read private docs (see README). Until then, share docs as “Anyone with the link can view”.")
            }
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await googleAuth.signIn(using: webAuthenticationSession)
            } catch GoogleAuth.AuthError.cancelled {
                // User backed out; nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
