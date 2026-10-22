// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Folio's routes on the local phi-agent (`/phi-agent/api/folio/v1/*` on
/// the broker, so `/api/folio/v1/...` through `PhiAgentTransport`). The
/// same shape as `IMChannelAPIClient`: the transport owns the route and the
/// retry, the bearer comes from `AuthManager`, and this file knows only the
/// paths and bodies. See `docs/folio-impl.md`.
final class FolioServiceClient: Sendable {
    static let shared = FolioServiceClient()

    private static let basePath = "/api/folio/v1"

    private let transport: PhiAgentTransport

    init(transport: PhiAgentTransport = .shared) {
        self.transport = transport
    }

    // MARK: - Shapes

    struct LibraryStatus: Decodable, Sendable {
        let folderPath: String
        /// `ready`, or `unavailable` when the folder cannot be read (a
        /// volume that is not mounted).
        let status: String
    }

    /// One capture, watch check, import or poll the service runs on its
    /// own time. Terminal statuses are `done`, `failed` and `cancelled`.
    struct Job: Decodable, Sendable {
        struct Result: Decodable, Sendable {
            let location: String?
            let basename: String?
        }

        let id: String
        let kind: String?
        let status: String
        let result: Result?
        let error: String?

        var isTerminal: Bool {
            ["done", "failed", "cancelled"].contains(status)
        }
    }

    struct ImportAccepted: Decodable, Sendable {
        let job: Job?
        let location: String?
        let basename: String?
    }

    enum ImportKind: String, Sendable {
        /// A .pdf or .epub, copied into the inbox and text-extracted.
        case file
        /// A service export (.csv/.html/.json/.zip); the service name is a
        /// hint the app derives from the file name.
        case export
        case opml
    }

    enum Failure: Error, Sendable {
        /// No bearer: the account is signed out or in a grace session.
        case unauthorized
        /// `503 folder_unavailable`: the service is up but no folder is
        /// registered yet, or the registered one cannot be read.
        case folderUnavailable
        case httpError(statusCode: Int, code: String?)
        case invalidResponse
    }

    // MARK: - Library registration

    func library() async throws -> LibraryStatus {
        let response = try await send("/library")
        return try decode(LibraryStatus.self, from: response)
    }

    func registerLibrary(folderPath: String) async throws -> LibraryStatus {
        let body = try JSONSerialization.data(withJSONObject: ["folderPath": folderPath])
        let response = try await send("/library", method: "PUT", body: body)
        return try decode(LibraryStatus.self, from: response)
    }

    // MARK: - Capture

    /// `POST /capture`. `location` is nil for the inbox or `watch` for a
    /// watched page; `trigger` is `manual`, `watch` or a site-action rule
    /// id; `key` de-duplicates a page already being captured (the service
    /// answers 200 with the running job instead of 202 with a new one).
    func capture(url: String, profileId: String, trigger: String,
                 title: String?, location: String?, key: String?,
                 locale: String?) async throws -> Job {
        var payload: [String: Any] = [
            "url": url,
            "profileId": profileId,
            "trigger": trigger,
        ]
        if let title, !title.isEmpty { payload["title"] = title }
        if let location { payload["location"] = location }
        if let key { payload["key"] = key }
        if let locale { payload["locale"] = locale }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await send("/capture", method: "POST", body: body)
        return try decode(Job.self, from: response)
    }

    func job(id: String) async throws -> Job {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await send("/jobs/\(encoded)")
        return try decode(Job.self, from: response)
    }

    // MARK: - Imports

    /// `POST /imports` with the absolute path the user chose in the open
    /// panel. The native app is the one trusted caller of this shape: the
    /// service copies the file into its import store at once and never
    /// stores the path.
    func importFile(path: String, kind: ImportKind, service: String?,
                    profileId: String?) async throws -> ImportAccepted {
        var payload: [String: Any] = [
            "kind": kind.rawValue,
            "path": path,
        ]
        if let service { payload["service"] = service }
        if let profileId, !profileId.isEmpty { payload["profileId"] = profileId }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await send("/imports", method: "POST", body: body)
        return try decode(ImportAccepted.self, from: response)
    }

    /// The export service a file name betrays, for `kind: export`. Nil
    /// leaves the guess to the service.
    static func exportService(forFileName name: String) -> String? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if lower.contains("pocket") || lower.hasPrefix("ril_export") { return "pocket" }
        if lower.contains("instapaper") { return "instapaper" }
        if lower.contains("raindrop") { return "raindrop" }
        if lower.contains("omnivore") { return "omnivore" }
        if lower.hasPrefix("bookmarks") && ext == "html" { return "bookmarks-html" }
        return nil
    }

    // MARK: - Events

    /// One server-sent event from `GET /events`.
    struct Event: Sendable {
        let name: String
        let data: Data
    }

    /// Opens `GET /events` and parses the `text/event-stream` body into
    /// events. The stream ends when the service closes it; the caller
    /// reconnects. A non-2xx head is a `Failure`, read before any event.
    func events() async throws -> (events: AsyncThrowingStream<Event, Error>,
                                   cancel: @Sendable () -> Void) {
        let token = bearer()
        guard !token.isEmpty else { throw Failure.unauthorized }
        let stream = try await transport.openStream(PhiAgentHTTPRequest(
            path: Self.basePath + "/events",
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "text/event-stream",
            ]
        ))
        guard (200...299).contains(stream.statusCode) else {
            stream.cancel()
            throw Failure.httpError(statusCode: stream.statusCode, code: nil)
        }
        let events = AsyncThrowingStream<Event, Error> { continuation in
            let reader = Task {
                var parser = EventStreamParser()
                do {
                    for try await chunk in stream.body {
                        for event in parser.feed(chunk) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                stream.cancel()
            }
        }
        return (events, stream.cancel)
    }

    /// The `text/event-stream` framing: `event:` and `data:` lines, an
    /// event per blank line, `:` comment lines ignored. Multi-line data is
    /// joined with newlines, as the format specifies.
    struct EventStreamParser {
        private var pending = Data()
        private var name = ""
        private var dataLines: [String] = []

        init() {}

        mutating func feed(_ chunk: Data) -> [Event] {
            pending.append(chunk)
            var events: [Event] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                pending.removeSubrange(pending.startIndex...newline)
                if line.isEmpty {
                    if let event = flush() { events.append(event) }
                    continue
                }
                let text = String(decoding: line, as: UTF8.self)
                if text.hasPrefix(":") { continue }
                let field: String
                let value: String
                if let colon = text.firstIndex(of: ":") {
                    field = String(text[text.startIndex..<colon])
                    var rest = text[text.index(after: colon)...]
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    value = String(rest)
                } else {
                    field = text
                    value = ""
                }
                switch field {
                case "event": name = value
                case "data": dataLines.append(value)
                default: break
                }
            }
            return events
        }

        private mutating func flush() -> Event? {
            defer {
                name = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return Event(name: name.isEmpty ? "message" : name,
                         data: Data(dataLines.joined(separator: "\n").utf8))
        }
    }

    // MARK: - Helpers

    private func bearer() -> String {
        AuthManager.shared.getAccessTokenSyncly() ?? ""
    }

    private func send(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> PhiAgentHTTPResponse {
        let token = bearer()
        guard !token.isEmpty else { throw Failure.unauthorized }
        return try await transport.send(PhiAgentHTTPRequest(
            path: Self.basePath + path,
            method: method,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: body,
            timeout: 15
        ))
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    private func decode<T: Decodable>(_ type: T.Type,
                                      from response: PhiAgentHTTPResponse) throws -> T {
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw Failure.unauthorized }
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: response.body))?.error
            if response.statusCode == 503, code == "folder_unavailable" {
                throw Failure.folderUnavailable
            }
            throw Failure.httpError(statusCode: response.statusCode, code: code)
        }
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            AppLogDebug("[FolioService] undecodable reply: \(error)")
            throw Failure.invalidResponse
        }
    }
}
