import Foundation

/// Manages our own LaunchAgent so the server can start at login without `brew services`.
///
/// Only one of this agent and a brew services registration may be active; ``ServerController.ownership``
/// decides which, and the UI refuses to enable both.
public struct LaunchAgentManager: Sendable {

    public static let label = "dev.anujp.devservices.server"

    public let installation: PostgresInstallation
    public let dataDirectory: String
    public let logPath: String

    public init(installation: PostgresInstallation, dataDirectory: String, logPath: String) {
        self.installation = installation
        self.dataDirectory = dataDirectory
        self.logPath = logPath
    }

    public static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
    }

    public func plistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(Self.label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(installation.postgres)</string>
        \t\t<string>-D</string>
        \t\t<string>\(dataDirectory)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<false/>
        \t<key>WorkingDirectory</key>
        \t<string>\(dataDirectory)</string>
        \t<key>StandardOutPath</key>
        \t<string>\(logPath)</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    /// Write the plist and load it. `RunAtLoad` means this also starts the server now.
    public func enable() async throws {
        let directory = (Self.plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try plistContents().write(toFile: Self.plistPath, atomically: true, encoding: .utf8)
        _ = try? await ProcessRunner.run("/bin/launchctl", ["unload", Self.plistPath])
        _ = try await ProcessRunner.runChecked("/bin/launchctl", ["load", "-w", Self.plistPath])
    }

    public func disable() async throws {
        guard isInstalled else { return }
        _ = try? await ProcessRunner.run("/bin/launchctl", ["unload", "-w", Self.plistPath])
        try? FileManager.default.removeItem(atPath: Self.plistPath)
    }

    /// Whether launchd currently knows about our agent.
    public static func isLoaded() async -> Bool {
        guard let result = try? await ProcessRunner.run("/bin/launchctl", ["list"]) else { return false }
        return result.stdout.contains(label)
    }
}
