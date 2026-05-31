import XCTest
import UIKit

@MainActor
final class PostLoginFreezeUITests: XCTestCase {
    private let baseURL = URL(string: "https://ubuntu-direct.tailc1d69d.ts.net:8444")!
    private let username = "ubuntu"
    private var token: String?
    private var createdSessionId: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPostLoginUIStaysResponsiveAndTerminalRendersLiveOutput() async throws {
        let password = try ubuntuPassword()
        let token = try await authenticate(password: password)
        self.token = token

        let marker = "VT_UI_MARKER_\(Int(Date().timeIntervalSince1970))"
        let sessionId = try await createLiveSession(marker: marker, token: token)
        createdSessionId = sessionId
        try await waitForSessionText(sessionId: sessionId, token: token, containing: marker, timeout: 20)

        let app = XCUIApplication()
        app.launchEnvironment["VT_UI_TESTING_RESET"] = "1"
        app.launch()

        let ubuntuConnect = app.buttons["server-profile-connect-Ubuntu (Tailscale)"]
        try require(ubuntuConnect.waitForExistence(timeout: 20), "Ubuntu profile connect button appears")
        ubuntuConnect.tap()

        let usernameField = app.textFields["login-username"]
        try require(usernameField.waitForExistence(timeout: 20), "Login sheet appears")
        usernameField.tap()
        usernameField.clearAndType(username)

        let passwordField = app.secureTextFields["login-password"]
        try require(passwordField.waitForExistence(timeout: 5), "Password field appears")
        passwordField.tap()
        UIPasteboard.general.string = password
        passwordField.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        try require(paste.waitForExistence(timeout: 5), "Paste menu appears for password field")
        paste.tap()

        app.buttons["login-submit-button"].tap()

        let sessionList = app.scrollViews["session-list"]
        try require(sessionList.waitForExistence(timeout: 30), "Session list appears after login")

        let createButton = app.buttons["session-list-create-session-button"]
        try require(createButton.waitForExistence(timeout: 10), "Create-session button exists")
        createButton.tap()
        try require(app.staticTexts["New Session"].waitForExistence(timeout: 5), "Create-session sheet opens, proving taps are not blocked")
        app.buttons["Cancel"].tap()

        try require(sessionList.waitForExistence(timeout: 10), "Session list is visible after closing create sheet")
        sessionList.swipeDown()

        let folderButton = app.buttons["session-list-folder-button"]
        try require(folderButton.waitForExistence(timeout: 10), "Folder button exists")
        folderButton.tap()
        try require(app.staticTexts["All Files"].waitForExistence(timeout: 10), "File browser opens from session list")
        app.buttons["cancel"].tap()

        let sessionCard = app.buttons["session-card-\(sessionId)"]
        try require(sessionCard.waitForExistence(timeout: 20), "Prepared live session appears")
        sessionCard.tap()

        let close = app.buttons["terminal-close-button"]
        try require(close.waitForExistence(timeout: 20), "Terminal opens")

        let fontIncrease = app.buttons["terminal-font-increase-button"]
        try require(fontIncrease.waitForExistence(timeout: 5), "Font increase button exists")
        fontIncrease.tap()

        let widthButton = app.buttons["terminal-width-button"]
        try require(widthButton.waitForExistence(timeout: 5), "Width selector button exists")
        widthButton.tap()
        try require(app.buttons["80"].waitForExistence(timeout: 5) || app.staticTexts["Terminal Width"].waitForExistence(timeout: 5), "Width control responds")
        if app.buttons["Done"].waitForExistence(timeout: 2) {
            app.buttons["Done"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        }

        try require(close.waitForExistence(timeout: 5), "Terminal close button exists")
        close.tap()
        try require(sessionList.waitForExistence(timeout: 10), "Back navigation returns to session list")

        deleteSession(sessionId, token: token)
        createdSessionId = nil
    }

    private func ubuntuPassword() throws -> String {
        if let password = ProcessInfo.processInfo.environment["VT_UBUNTU_PASSWORD"], !password.isEmpty {
            return password
        }

        let passwordURL = URL(fileURLWithPath: "/tmp/vt-ubuntu-password")
        if let password = try? String(contentsOf: passwordURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !password.isEmpty
        {
            return password
        }

        throw XCTSkip("VT_UBUNTU_PASSWORD or /tmp/vt-ubuntu-password is required for live Ubuntu UI verification")
    }

    private func authenticate(password: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/auth/password"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "userId": username,
            "password": password,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = payload?["token"] as? String else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private func createLiveSession(marker: String, token: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": ["bash", "-lc", "printf '\(marker)\\n'; while true; do sleep 5; done"],
            "workingDir": "/tmp",
            "name": "vt-ui-\(marker)",
            "spawn_terminal": true,
            "cols": 120,
            "rows": 30,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let sessionId = payload?["sessionId"] as? String else {
            throw URLError(.badServerResponse)
        }
        return sessionId
    }

    private func waitForSessionText(
        sessionId: String,
        token: String,
        containing text: String,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await sessionText(sessionId: sessionId, token: token).contains(text) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw UITestFailure()
    }

    private func sessionText(sessionId: String, token: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/sessions/\(sessionId)/text"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func deleteSession(_ sessionId: String, token: String) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/sessions/\(sessionId)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct UITestFailure: Error {}

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard condition() else {
            XCTFail(message, file: file, line: line)
            throw UITestFailure()
        }
    }

}

@MainActor
private extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let currentValue = value as? String, !currentValue.isEmpty else {
            typeText(text)
            return
        }
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
        typeText(deleteString)
        typeText(text)
    }
}
