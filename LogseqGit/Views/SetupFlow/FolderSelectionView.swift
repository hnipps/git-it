import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectionView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    @State private var isImporterPresented = false
    @State private var showError = false

    var body: some View {
        Form {
            Section {
                if viewModel.selectedGraphFolderDisplayName.isEmpty {
                    Text("No folder selected")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.folderSelectionLabel)
                } else {
                    Text(viewModel.selectedGraphFolderDisplayName)
                        .accessibilityIdentifier(AccessibilityID.folderSelectionLabel)
                }

                Button("Choose Folder") {
                    isImporterPresented = true
                }
                .accessibilityIdentifier(AccessibilityID.folderChooseButton)

                Button("Use App Storage (Legacy - Logseq can't open)") {
                    viewModel.useLegacyProviderStorage()
                }
                .accessibilityIdentifier(AccessibilityID.folderUseLegacyButton)
            } header: {
                Text("Graph Folder")
            } footer: {
                Text("Choose a folder inside Files > Logseq (Logseq logo).")
            }
        }
        .navigationTitle("Graph Folder")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") {
                    viewModel.advanceToClone()
                }
                .accessibilityIdentifier(AccessibilityID.folderContinueButton)
                .disabled(viewModel.selectedGraphFolderURL == nil)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folderURL = urls.first {
                    viewModel.selectGraphFolder(folderURL)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
            showError = viewModel.errorMessage != nil
        }
        .onChange(of: viewModel.errorMessage) { newValue in
            showError = newValue != nil
        }
        .alert("Invalid Folder", isPresented: $showError) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please choose a different folder.")
        }
    }
}
