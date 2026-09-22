import Foundation

/// Where the server is in its lifecycle, as far as the app can tell.
public enum ServerStatus: Sendable, Equatable {
    /// No Postgres server binaries found anywhere on this machine.
    case notInstalled
    /// Binaries exist, but the data directory has not been initialised yet.
    case noCluster
    /// Cluster exists, nothing running.
    case stopped
    /// A postmaster.pid exists but the server is not accepting connections yet.
    case starting(pid: Int32)
    case running(pid: Int32, port: Int)
    /// A postmaster.pid exists but its process is gone — a crash left it behind.
    case stalePidFile
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var canStart: Bool {
        switch self {
        case .stopped, .stalePidFile, .failed: return true
        default: return false
        }
    }

    public var canStop: Bool {
        switch self {
        case .running, .starting: return true
        default: return false
        }
    }

    public var port: Int? {
        if case .running(_, let port) = self { return port }
        return nil
    }

    public var shortDescription: String {
        switch self {
        case .notInstalled:      return "Not installed"
        case .noCluster:         return "No data directory"
        case .stopped:           return "Stopped"
        case .starting:          return "Starting…"
        case .running(_, let p): return "Running on port \(p)"
        case .stalePidFile:      return "Stale PID file"
        case .failed(let m):     return "Failed: \(m)"
        }
    }
}

/// Who currently owns the server's lifecycle. Having both would make start/stop fight.
public enum ServerOwnership: Sendable, Equatable {
    /// We manage it directly with pg_ctl.
    case app
    /// `brew services` has it registered; it will also start at login.
    case brewServices(formula: String)

    public var isBrewServices: Bool {
        if case .brewServices = self { return true }
        return false
    }
}
