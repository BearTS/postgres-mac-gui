import Foundation
import Observation
import ServiceKit
import SwiftUI

/// Which local service the user is looking at.
public enum ManagedService: String, CaseIterable, Identifiable, Hashable {
    case postgres
    case vault
    case kafka

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .vault:    return "Vault"
        case .kafka:    return "Kafka"
        }
    }

    public var symbol: String {
        switch self {
        case .postgres: return "cylinder.split.1x2"
        case .vault:    return "lock.shield"
        case .kafka:    return "arrow.left.arrow.right.circle"
        }
    }
}

/// A service's state boiled down to what the menu bar and sidebar need to show.
public struct ServiceSummary: Sendable, Equatable {
    public var isInstalled: Bool
    public var isRunning: Bool
    public var detail: String

    public init(isInstalled: Bool, isRunning: Bool, detail: String) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.detail = detail
    }

    public var tint: Color {
        if !isInstalled { return .orange }
        return isRunning ? .green : .secondary
    }
}

/// Root model. Each service keeps its own state; this owns them and answers questions that
/// span all three, such as what the menu bar icon should look like.
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    let postgres = PostgresModel.shared
    let vault = VaultModel()
    let kafka = KafkaModel()

    var selectedService: ManagedService = .postgres

    init() {
        AppPaths.ensureDirectories()
        Task { await vault.bootstrap() }
        Task { await kafka.bootstrap() }
    }

    func summary(for service: ManagedService) -> ServiceSummary {
        switch service {
        case .postgres:
            return ServiceSummary(
                isInstalled: !postgres.installations.isEmpty,
                isRunning: postgres.status.isRunning,
                detail: postgres.status.shortDescription
            )
        case .vault:  return vault.summary
        case .kafka:  return kafka.summary
        }
    }

    /// How many services are up — the number the menu bar shows at a glance.
    var runningCount: Int {
        ManagedService.allCases.count { summary(for: $0).isRunning }
    }

    /// Filled when any service is running, so status is readable without opening the menu.
    var menuBarSymbol: String {
        runningCount > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up"
    }

    func refreshAll() async {
        await postgres.refreshStatus()
        await vault.refresh()
        await kafka.refresh()
    }
}
