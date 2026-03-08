import SwiftUI

struct CloneProgressView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    @State private var statusText: String = "Connecting..."
    @State private var cloneError: String?
    @State private var isCloning: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if let error = cloneError {
                errorContent(error)
            } else {
                progressContent
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Clone")
        .navigationBarBackButtonHidden(isCloning)
        .task {
            await startClone()
        }
    }

    // MARK: - Progress Content

    @ViewBuilder
    private var progressContent: some View {
        ProgressView()
            .scaleEffect(1.5)
            .padding(.bottom, 8)

        Text(statusText)
            .font(.headline)
            .foregroundColor(.secondary)
    }

    // MARK: - Error Content

    @ViewBuilder
    private func errorContent(_ error: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 48))
            .foregroundColor(.red)
            .padding(.bottom, 8)

        Text("Clone Failed")
            .font(.headline)

        Text(error)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

        Button {
            Task {
                await startClone()
            }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 40)
        .padding(.top, 8)
    }

    // MARK: - Clone Logic

    private func startClone() async {
        cloneError = nil
        isCloning = true
        statusText = "Connecting..."

        do {
            // Brief delay so the user sees the "Connecting" state.
            try await Task.sleep(nanoseconds: 500_000_000)
            statusText = "Cloning repository..."

            try await viewModel.gitService.clone(
                remoteURL: viewModel.remoteURL,
                branch: viewModel.branch
            )

            statusText = "Done!"

            // Save configuration after successful clone.
            try await viewModel.saveConfig()

            isCloning = false

            // Short pause so "Done!" is visible before advancing.
            try await Task.sleep(nanoseconds: 600_000_000)
            viewModel.advanceToInstructions()
        } catch {
            isCloning = false
            cloneError = error.localizedDescription
        }
    }
}
