import SwiftUI

/// Shows a spinner, an error with a retry button, or the loaded content.
struct PhaseView<Content: View>: View {
    let phase: LoadPhase
    let retry: @MainActor @Sendable () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorView(message: message, retry: retry)
        case .loaded:
            content()
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: @MainActor @Sendable () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Placed at the end of a paginated list; loads the next page when it scrolls
/// into view, and again whenever the page token changes while it is visible.
struct LoadMoreView: View {
    let token: String?
    let load: @MainActor @Sendable () async -> Void

    var body: some View {
        if let token {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
                .task(id: token) { await load() }
        }
    }
}
