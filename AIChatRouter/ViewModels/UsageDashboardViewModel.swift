import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class UsageDashboardViewModel {
    enum Period: String, CaseIterable, Identifiable {
        case day = "Today"
        case week = "This Week"
        case month = "This Month"
        var id: String { rawValue }
    }

    var selectedPeriod: Period = .day
    private(set) var totals: [UsageStore.PeriodTotal] = []
    private(set) var totalSpendUSD: Double = 0

    private let usageStore: UsageStore

    init(usageStore: UsageStore) {
        self.usageStore = usageStore
    }

    func refresh() async {
        let (start, end) = Self.bounds(for: selectedPeriod)
        totals = (try? await usageStore.totals(from: start, to: end)) ?? []
        totalSpendUSD = (try? await usageStore.totalSpend(from: start, to: end)) ?? 0
    }

    static func bounds(for period: Period) -> (Date, Date) {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .day:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return (start, end)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
            return (start, end)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            return (start, end)
        }
    }
}
