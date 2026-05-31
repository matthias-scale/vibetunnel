import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(category: "ContentView")

/// Root content view that manages the main app navigation.
/// Displays either the connection view or session list based on
/// connection state, and handles opening cast files.
struct ContentView: View {
    @Environment(ConnectionManager.self)
    var connectionManager
    @State private var showingFilePicker = false
    @State private var showingCastPlayer = false
    @State private var selectedCastFile: URL?
    @State private var isValidatingConnection = true
    @State private var showingWelcome = false
    @AppStorage("welcomeCompleted")
    private var welcomeCompleted = false

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.environment["VT_AUTOCONNECT"] == "1" {
                AutoconnectTerminalHost()
            } else {
                self.connectionContent
            }
            #else
            self.connectionContent
            #endif
        }
        .animation(.default, value: self.connectionManager.isConnected)
        .onAppear {
            #if DEBUG
            let isAutoconnectRun = ProcessInfo.processInfo.environment["VT_AUTOCONNECT"] == "1"
            if isAutoconnectRun {
                self.isValidatingConnection = false
                self.showingWelcome = false
                self.welcomeCompleted = true
            } else if !self.welcomeCompleted {
                self.validateRestoredConnection()
                self.showingWelcome = true
            } else {
                self.validateRestoredConnection()
            }
            #else
            self.validateRestoredConnection()
            // Show welcome on first launch
            if !self.welcomeCompleted {
                self.showingWelcome = true
            }
            #endif
        }
        .fullScreenCover(isPresented: self.$showingWelcome) {
            WelcomeView()
        }
        .onOpenURL { url in
            // Handle cast file opening
            if url.pathExtension == "cast" {
                self.selectedCastFile = url
                self.showingCastPlayer = true
            }
        }
        .sheet(isPresented: self.$showingCastPlayer) {
            if let castFile = selectedCastFile {
                CastPlayerView(castFileURL: castFile)
            }
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        if self.isValidatingConnection, self.connectionManager.isConnected {
            // Show loading while validating restored connection
            VStack(spacing: Theme.Spacing.large) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primaryAccent))
                    .scaleEffect(1.5)

                Text("Restoring connection...")
                    .font(Theme.Typography.terminalSystem(size: 14))
                    .foregroundColor(Theme.Colors.terminalForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.terminalBackground)
        } else if self.connectionManager.isConnected, self.connectionManager.serverConfig != nil {
            SessionListView()
        } else {
            ServerListView()
        }
    }

    private func validateRestoredConnection() {
        guard self.connectionManager.isConnected,
              self.connectionManager.serverConfig != nil
        else {
            self.isValidatingConnection = false
            return
        }

        // Test the restored connection
        Task {
            do {
                // Try to fetch sessions to validate connection
                _ = try await APIClient.shared.getSessions()
                // Connection is valid
                await MainActor.run {
                    self.isValidatingConnection = false
                }
            } catch {
                // Connection failed, reset state
                await MainActor.run {
                    Task {
                        await self.connectionManager.disconnect()
                    }
                    self.isValidatingConnection = false
                }
            }
        }
    }
}

#if DEBUG
private struct AutoconnectTerminalHost: View {
    @Environment(ConnectionManager.self)
    var connectionManager
    @AppStorage("welcomeCompleted")
    private var welcomeCompleted = false
    @StateObject private var model = AutoconnectTerminalModel.shared

    var body: some View {
        Group {
            if let session = model.session {
                TerminalView(session: session)
            } else if let errorMessage = model.errorMessage {
                VStack(spacing: Theme.Spacing.medium) {
                    Text("Autoconnect failed")
                        .font(.headline)
                    Text(errorMessage)
                        .font(Theme.Typography.terminalSystem(size: 12))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Opening terminal...")
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primaryAccent))
                    .font(Theme.Typography.terminalSystem(size: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            self.welcomeCompleted = true
            await self.model.run(connectionManager: self.connectionManager)
        }
    }
}

private final class AutoconnectTerminalModel: ObservableObject {
    @MainActor
    static let shared = AutoconnectTerminalModel()

    @Published var session: Session?
    @Published var errorMessage: String?
    private var didRun = false

    private init() {}

    @MainActor
    func run(connectionManager: ConnectionManager) async {
        guard !self.didRun else { return }
        self.didRun = true

        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["VT_AUTOCONNECT_HOST"],
              let portString = environment["VT_AUTOCONNECT_PORT"],
              let port = Int(portString),
              let httpsString = environment["VT_AUTOCONNECT_HTTPS"],
              let username = environment["VT_AUTOCONNECT_USER"],
              let password = environment["VT_AUTOCONNECT_PASSWORD"]
        else {
            self.errorMessage = "Missing VT_AUTOCONNECT environment."
            return
        }

        logger.info("DEBUG autoconnect harness enabled for \(host):\(port)")
        await connectionManager.disconnect()

        let httpsAvailable = httpsString == "1" || httpsString.lowercased() == "true"
        let config = ServerConfig(
            host: host,
            port: port,
            name: host,
            tailscaleHostname: host,
            isTailscaleEnabled: true,
            httpsAvailable: httpsAvailable,
            preferSSL: httpsAvailable
        )

        connectionManager.saveConnection(config)

        guard let authService = connectionManager.authenticationService else {
            self.errorMessage = "Authentication service was not initialized."
            return
        }

        do {
            try await authService.authenticateWithPassword(username: username, password: password)
            let sessions = try await APIClient.shared.getSessions()
            logger.info("DEBUG autoconnect fetched \(sessions.count) sessions")
            guard let targetSession = sessions.first(where: \.isRunning) ?? sessions.first else {
                logger.error("DEBUG autoconnect found no sessions to open")
                self.errorMessage = "No sessions available."
                return
            }

            // Drive the in-tree AutoconnectTerminalHost via published session so the
            // rendered TerminalView keeps its SwiftUI @Environment (ConnectionManager etc.).
            // (An imperative window.rootViewController swap would strip that environment and
            // strand the renderer — which is what stuck the harness on "Opening terminal…".)
            connectionManager.isConnected = true
            self.session = targetSession
            logger.info("DEBUG autoconnect opening session \(targetSession.id)")
        } catch {
            logger.error("DEBUG autoconnect failed: \(error)")
            self.errorMessage = error.localizedDescription
            await connectionManager.disconnect()
        }
    }
}
#endif
