import SwiftUI
import AIChatRouterKit

struct UsageDashboardView: View {
    @State private var viewModel: UsageDashboardViewModel

    init(environment: AppEnvironment) {
        _viewModel = State(initialValue: UsageDashboardViewModel(usageStore: environment.usageStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $viewModel.selectedPeriod) {
                ForEach(UsageDashboardViewModel.Period.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.selectedPeriod) { Task { await viewModel.refresh() } }

            Text("Total spend: \(viewModel.totalSpendUSD, format: .currency(code: "USD"))")
                .font(.headline)

            if viewModel.totals.isEmpty {
                Text("No usage recorded for this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Provider").bold()
                        Text("Tier").bold()
                        Text("Input").bold()
                        Text("Output").bold()
                        Text("Cost").bold()
                    }
                    Divider().gridCellColumns(5)
                    ForEach(Array(viewModel.totals.enumerated()), id: \.offset) { _, total in
                        GridRow {
                            Text(total.providerID.rawValue)
                            Text(total.tier.rawValue)
                            Text("\(total.inputTokens)")
                            Text("\(total.outputTokens)")
                            Text(total.costUSD, format: .currency(code: "USD"))
                        }
                    }
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding()
        .task { await viewModel.refresh() }
    }
}
