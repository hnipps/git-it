import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AuthConfigView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    @State private var privateKeyText: String = ""
    @State private var detectedKeyType: SSHKeyType?
    @State private var derivedPublicKey: String?
    @State private var patText: String = ""
    @State private var showFileImporter: Bool = false
    @State private var showError: Bool = false
    @State private var errorText: String = ""
    @State private var isImported: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $viewModel.authMethod) {
                    Text("SSH").tag(AuthMethod.ssh)
                    Text("HTTPS").tag(AuthMethod.https)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Authentication Method")
            }

            if viewModel.authMethod == .ssh {
                sshSection
            } else {
                httpsSection
            }
        }
        .navigationTitle("Authentication")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") {
                    storeCredentials()
                }
                .disabled(!canProceed)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText)
        }
    }

    // MARK: - SSH Section

    @ViewBuilder
    private var sshSection: some View {
        Section {
            TextEditor(text: $privateKeyText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 120)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: privateKeyText) { _ in
                    validateKey()
                }

            Button {
                showFileImporter = true
            } label: {
                Label("Import from Files", systemImage: "doc")
            }
        } header: {
            Text("SSH Private Key")
        } footer: {
            Text("Paste your private key or import a key file (e.g. id_ed25519).")
        }

        if let keyType = detectedKeyType {
            Section {
                HStack {
                    Label("Key Type", systemImage: "checkmark.shield")
                    Spacer()
                    Text(keyType.rawValue)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Validation")
            }
        }

        if let publicKey = derivedPublicKey, !publicKey.isEmpty {
            Section {
                HStack {
                    Text(publicKey)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(3)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = publicKey
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Public Key")
            } footer: {
                Text("Add this public key to your Git hosting provider.")
            }
        }
    }

    // MARK: - HTTPS Section

    @ViewBuilder
    private var httpsSection: some View {
        Section {
            SecureField("ghp_xxxxxxxxxxxx", text: $patText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Personal Access Token")
        } footer: {
            Text("A token with repository read/write access from your Git hosting provider.")
        }
    }

    // MARK: - Helpers

    private var canProceed: Bool {
        switch viewModel.authMethod {
        case .ssh:
            return detectedKeyType != nil
        case .https:
            return !patText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func validateKey() {
        let trimmed = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            detectedKeyType = nil
            derivedPublicKey = nil
            return
        }
        detectedKeyType = viewModel.keychainService.validateSSHKey(data)
        derivedPublicKey = viewModel.keychainService.derivePublicKey(fromPrivateKey: data)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                showErrorAlert("Unable to access the selected file.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    showErrorAlert("The file does not contain valid text data.")
                    return
                }
                privateKeyText = text
                validateKey()
            } catch {
                showErrorAlert("Failed to read file: \(error.localizedDescription)")
            }

        case .failure(let error):
            showErrorAlert("File import failed: \(error.localizedDescription)")
        }
    }

    private func storeCredentials() {
        do {
            switch viewModel.authMethod {
            case .ssh:
                try viewModel.keychainService.importSSHKey(fromText: privateKeyText)
                isImported = true
            case .https:
                let token = patText.trimmingCharacters(in: .whitespacesAndNewlines)
                try viewModel.keychainService.storePAT(token)
                isImported = true
            }
            viewModel.advanceToClone()
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    private func showErrorAlert(_ message: String) {
        errorText = message
        showError = true
    }
}
