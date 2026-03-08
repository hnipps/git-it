import SwiftUI

struct SetupFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = SetupFlowViewModel()

    var body: some View {
        NavigationStack {
            stepView
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch viewModel.currentStep {
        case .remote:
            RemoteConfigView(viewModel: viewModel)

        case .auth:
            AuthConfigView(viewModel: viewModel)

        case .clone:
            CloneProgressView(viewModel: viewModel)

        case .instructions:
            InstructionsView(viewModel: viewModel) {
                Task {
                    await appState.checkSetupState()
                }
            }
        }
    }
}
