import SwiftUI

struct RemoteConfigView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    var body: some View {
        Form {
            Section {
                TextField("git@github.com:user/repo.git", text: $viewModel.remoteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: viewModel.remoteURL) { _ in
                        viewModel.updateGraphNameIfNeeded()
                    }
            } header: {
                Text("Remote URL")
            } footer: {
                Text("The SSH or HTTPS URL of your Logseq git repository.")
            }

            Section {
                TextField("main", text: $viewModel.branch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Branch")
            } footer: {
                Text("The branch to sync with. Usually \"main\" or \"master\".")
            }

            Section {
                TextField("my-graph", text: $viewModel.graphName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Graph Name")
            } footer: {
                Text("A name for your Logseq graph. Auto-derived from the repository URL.")
            }
        }
        .navigationTitle("Remote")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") {
                    viewModel.advanceToAuth()
                }
                .disabled(viewModel.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
