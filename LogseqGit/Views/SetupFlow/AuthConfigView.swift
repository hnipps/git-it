import SwiftUI

struct AuthConfigView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    @State private var patText: String = ""
    @State private var showError: Bool = false
    @State private var errorText: String = ""

    var body: some View {
        Form {
            Section {
                SecureField("ghp_xxxxxxxxxxxx", text: $patText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.patField)
            } header: {
                Text("Personal Access Token")
            } footer: {
                Text("Create a fine-grained token at GitHub → Settings → Developer settings → Personal access tokens. Grant \"Contents\" read & write access for your repository.")
            }
        }
        .navigationTitle("Authentication")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") {
                    storeCredentials()
                }
                .accessibilityIdentifier(AccessibilityID.authNextButton)
                .disabled(!canProceed)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText)
        }
    }

    // MARK: - Helpers

    private var canProceed: Bool {
        !patText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func storeCredentials() {
        do {
            let token = patText.trimmingCharacters(in: .whitespacesAndNewlines)
            try viewModel.keychainService.storePAT(token)
            viewModel.advanceToFolder()
        } catch {
            errorText = error.localizedDescription
            showError = true
        }
    }
}
