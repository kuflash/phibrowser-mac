// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// The service half of Folio: phi-agent, hosted by the Sentinel, serves
/// `/api/folio/v1/*` and captures pages over CDP in a hidden window. The
/// native app registers the one Folio folder with it, asks it for captures,
/// watches and imports, and turns its event stream into toasts. Nothing
/// here reads or writes an item; see `docs/folio-impl.md`.
///
/// The service runs only while the account is signed in with AI on — the
/// Sentinel's own run policy — so `serviceAvailable` is the one switch
/// between this half and the legacy extension pipeline in
/// `SaveForLaterService.swift`, kept for one release.
extension SaveForLaterService {

    // MARK: - Availability

    /// Whether Folio requests go to the service. True once `GET /library`
    /// answered — 2xx, or `503 folder_unavailable` (the service is up and
    /// waiting for a folder) — and the folder was registered. Flips back to
    /// false when the Sentinel's run policy says it should not run, or when
    /// the event stream drops and the service does not answer again.
    private(set) static var serviceAvailable = false

    /// The folder the service last accepted from `PUT /library`: the jail
    /// for `reveal { path }` and `openOriginal { path }`. Before the first
    /// registration the preference stands in, since that is what will be
    /// registered.
    private static var registeredFolderPath: String?

    static var registeredFolderURL: URL {
        URL(fileURLWithPath: registeredFolderPath
                ?? PhiPreferences.SaveForLater.globalFolderPath,
            isDirectory: true)
    }

    /// The one session with the service: probe, register, hold the event
    /// stream, repeat. Cancelled when the Sentinel should not run.
    private static var serviceSession: Task<Void, Never>?
    /// Bumped per session so a session that was cancelled and replaced
    /// cannot clear the replacement's bookkeeping as it winds down.
    private static var serviceSessionGeneration = 0

    /// Called from the Sentinel session lifecycle whenever it reconciles:
    /// `shouldRun` is its own decision (signed in, authenticated, AI on).
    /// Idempotent — a session already running is left alone.
    static func sentinelLifecycleDidReconcile(shouldRun: Bool) {
        guard featureEnabled else { return }
        guard shouldRun else {
            endServiceSession()
            return
        }
        guard serviceSession == nil else { return }
        AppLogDebug("[SaveForLater] service session starting")
        serviceSessionGeneration += 1
        let generation = serviceSessionGeneration
        serviceSession = Task { @MainActor in
            await runServiceSession()
            if serviceSessionGeneration == generation {
                serviceSession = nil
                serviceAvailable = false
            }
        }
    }

    private static func endServiceSession() {
        serviceSession?.cancel()
        serviceSession = nil
        if serviceAvailable {
            AppLogDebug("[SaveForLater] service session ended; legacy pipeline")
        }
        serviceAvailable = false
    }

    /// The General settings folder picker landed on a new folder. The
    /// service learns it at once when it is up; otherwise the next
    /// registration carries it.
    static func folderPreferenceDidChange() {
        guard featureEnabled, serviceAvailable else { return }
        Task { @MainActor in
            _ = await registerLibrary()
        }
    }

    /// Probe phase: `GET /library` until the service answers, with a
    /// backoff that is quick while the Sentinel is booting and settles to
    /// a minute. Then the folder is registered and the event stream held;
    /// when the stream ends and the service no longer answers, back to the
    /// probe. A `404` means this phi-agent has no Folio row at all, which
    /// no amount of probing changes: the session ends until the next
    /// lifecycle reconcile.
    private static func runServiceSession() async {
        var delay: TimeInterval = 2
        var elapsed: TimeInterval = 0
        while !Task.isCancelled {
            let outcome = await probe()
            guard !Task.isCancelled else { return }
            switch outcome {
            case .available:
                if await registerLibrary() {
                    guard !Task.isCancelled else { return }
                    if !serviceAvailable {
                        AppLogDebug("[SaveForLater] service available")
                    }
                    serviceAvailable = true
                    await holdEventStream()
                    guard !Task.isCancelled else { return }
                    serviceAvailable = false
                    delay = 2
                    elapsed = 0
                    continue
                }
                guard !Task.isCancelled else { return }
            case .notServed:
                AppLogDebug("[SaveForLater] phi-agent serves no Folio routes; giving up")
                serviceAvailable = false
                return
            case .unreachable:
                break
            }
            serviceAvailable = false
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            elapsed += delay
            delay = elapsed < 120 ? min(delay * 1.6, 30) : 60
        }
    }

    private enum ProbeOutcome {
        case available
        case unreachable
        case notServed
    }

    private static func probe() async -> ProbeOutcome {
        do {
            _ = try await FolioServiceClient.shared.library()
            return .available
        } catch FolioServiceClient.Failure.folderUnavailable {
            return .available
        } catch FolioServiceClient.Failure.httpError(let statusCode, _) where statusCode == 404 {
            return .notServed
        } catch {
            AppLogDebug("[SaveForLater] service probe: \(error)")
            return .unreachable
        }
    }

    /// `PUT /library` with the one global folder. True when the service
    /// took it; a folder it cannot read right now still counts (the
    /// library page shows that state itself).
    private static func registerLibrary() async -> Bool {
        let folder = PhiPreferences.SaveForLater.globalFolderPath
        do {
            let status = try await FolioServiceClient.shared.registerLibrary(folderPath: folder)
            registeredFolderPath = status.folderPath.isEmpty ? folder : status.folderPath
            if status.status != "ready" {
                AppLogWarn("[SaveForLater] Folio folder registered but \(status.status)")
            }
            return true
        } catch {
            AppLogWarn("[SaveForLater] folder registration failed: \(error)")
            return false
        }
    }

    // MARK: - Events

    /// Reads `GET /events` until it ends. `watch` events become the change
    /// toast; `job` events settle captures this app started whose poll
    /// gave up before the job finished (a video gist can take minutes).
    private static func holdEventStream() async {
        do {
            let (events, _) = try await FolioServiceClient.shared.events()
            for try await event in events {
                guard !Task.isCancelled else { return }
                handle(event)
            }
            AppLogDebug("[SaveForLater] event stream ended")
        } catch {
            AppLogDebug("[SaveForLater] event stream failed: \(error)")
        }
    }

    private struct WatchEvent: Decodable {
        let id: String?
        let location: String?
        let basename: String?
        let changed: Bool?
        let error: String?
    }

    private static func handle(_ event: FolioServiceClient.Event) {
        switch event.name {
        case "watch":
            guard let watch = try? JSONDecoder().decode(WatchEvent.self, from: event.data),
                  watch.changed == true, let basename = watch.basename else { return }
            showChangeToast(basename: basename)
        case "job":
            guard let job = try? JSONDecoder().decode(FolioServiceClient.Job.self,
                                                      from: event.data),
                  job.isTerminal,
                  let pending = pendingServiceJobs.removeValue(forKey: job.id) else { return }
            finish(job, pending: pending)
        case "library":
            // The service re-announces the folder (its restart, or a volume
            // that came back); nothing to do here but note it.
            AppLogDebug("[SaveForLater] library event")
        default:
            break
        }
    }

    private static func showChangeToast(basename: String) {
        guard let windowId = SpaceSessionControllersManager.shared
                .getActiveWindowState()?.windowId else { return }
        let title = String(
            format: NSLocalizedString(
                "browser.folio.changedToast",
                value: "%@ changed",
                comment: "Folio - Toast shown when a watched page's content changed since its last check; the placeholder is the saved item's name"),
            basename)
        OverlayToastCenter.shared.show(
            title: title, message: "", duration: 6, in: .windowId(windowId),
            action: OverlayToastAction(
                title: NSLocalizedString(
                    "browser.folio.openFolioAction",
                    value: "Open Folio",
                    comment: "Folio - Button on the change toast that opens the Folio library page"),
                handler: { openLibrary() }))
    }

    // MARK: - Captures through the service

    /// What a capture this app asked for still owes the user, by job id:
    /// the toast on its outcome, in the window it came from.
    private struct PendingServiceJob {
        let windowId: Int
        let title: String
        let isWatch: Bool
    }

    private static var pendingServiceJobs: [String: PendingServiceJob] = [:]

    /// How long a native-initiated capture is polled before the event
    /// stream is left to report it.
    private static let jobPollBudget: TimeInterval = 180
    private static let jobPollInterval: TimeInterval = 1.5

    /// The app's UI language, the locale the service writes the item's
    /// user-facing fields in.
    private static var captureLocale: String {
        PhiPreferences.GeneralSettings.activeProcessAppLanguage().rawValue
    }

    /// `POST /capture` for Save to Folio and the site-action trigger. The
    /// tab's Profile names the cookies the hidden window loads with; the
    /// URL is the de-duplication key, so a second Save while the first is
    /// running joins it instead of writing twice.
    static func captureThroughService(context: JobContext) async {
        if !context.highlightBlocks.isEmpty {
            AppLogDebug("[SaveForLater] highlight blocks are not carried by a service capture")
        }
        await requestCapture(
            url: context.sourceURL, profileId: context.profileId,
            title: context.pageTitle, windowId: context.windowId,
            trigger: context.trigger.frontmatterValue, isWatch: false)
    }

    /// Whether Watch This Page is offered for this tab: a saveable page and
    /// a service to watch it, since only the service runs the checks.
    static func canWatch(_ tab: Tab?) -> Bool {
        serviceAvailable && canSave(tab)
    }

    /// Watch This Page: `POST /capture` with `location: watch`. The first
    /// capture lands under `_watch/` and the service's sweep re-checks it.
    static func watch(tab: Tab, in state: BrowserState) {
        guard canWatch(tab), let url = tab.url else { return }
        let tabGuid = tab.guid
        let profileId = state.profileId
        let windowId = state.windowId
        let title = tab.title
        inFlightTabGuids.insert(tabGuid)
        Task { @MainActor in
            await requestCapture(url: url, profileId: profileId, title: title,
                                 windowId: windowId, trigger: "watch", isWatch: true)
            inFlightTabGuids.remove(tabGuid)
        }
    }

    private static func requestCapture(url: String, profileId: String, title: String,
                                       windowId: Int, trigger: String, isWatch: Bool) async {
        let job: FolioServiceClient.Job
        do {
            job = try await FolioServiceClient.shared.capture(
                url: url, profileId: profileId, trigger: trigger,
                title: title, location: isWatch ? "watch" : nil,
                key: url, locale: captureLocale)
        } catch {
            AppLogWarn("[SaveForLater] capture request failed: \(error)")
            showToast(title: failedToastTitle, message: "", windowId: windowId)
            return
        }
        if isWatch {
            showToast(
                title: String(
                    format: NSLocalizedString(
                        "browser.folio.watchingToast",
                        value: "Watching %@",
                        comment: "Folio - Toast shown when a page was put under watch so Folio re-checks it for changes; the placeholder is the page title"),
                    title),
                message: "", windowId: windowId)
        }
        let pending = PendingServiceJob(windowId: windowId, title: title, isWatch: isWatch)
        if job.isTerminal {
            finish(job, pending: pending)
            return
        }
        pendingServiceJobs[job.id] = pending
        await poll(jobId: job.id)
    }

    /// `GET /jobs/{id}` every second and a half for up to three minutes.
    /// Whoever sees the terminal job first — this loop or the event
    /// stream — takes it out of `pendingServiceJobs` and toasts; a job
    /// still running when the budget runs out is left to the stream.
    private static func poll(jobId: String) async {
        let deadline = Date().addingTimeInterval(jobPollBudget)
        var consecutiveFailures = 0
        while Date() < deadline, pendingServiceJobs[jobId] != nil {
            try? await Task.sleep(nanoseconds: UInt64(jobPollInterval * 1_000_000_000))
            let job: FolioServiceClient.Job
            do {
                job = try await FolioServiceClient.shared.job(id: jobId)
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                AppLogDebug("[SaveForLater] job poll failed: \(error)")
                // The service went away mid-job: say so rather than wait
                // out the budget on a dead socket.
                guard consecutiveFailures < 5 else {
                    if let pending = pendingServiceJobs.removeValue(forKey: jobId) {
                        showToast(title: failedToastTitle, message: "",
                                  windowId: pending.windowId)
                    }
                    return
                }
                continue
            }
            guard job.isTerminal else { continue }
            if let pending = pendingServiceJobs.removeValue(forKey: jobId) {
                finish(job, pending: pending)
            }
            return
        }
    }

    private static func finish(_ job: FolioServiceClient.Job, pending: PendingServiceJob) {
        switch job.status {
        case "done":
            // A watch already toasted when it was accepted.
            guard !pending.isWatch else { return }
            showToast(
                title: NSLocalizedString(
                    "browser.folio.savedToInboxToast",
                    value: "Saved to Inbox",
                    comment: "Folio - Toast shown when the Folio service finished saving a page into the library's Inbox"),
                message: job.result?.basename ?? "",
                windowId: pending.windowId)
        case "failed":
            AppLogWarn("[SaveForLater] service capture failed: \(job.error ?? "unknown")")
            showToast(title: failedToastTitle,
                      message: job.error.map { toastReason($0) } ?? "",
                      windowId: pending.windowId)
        default:
            // Cancelled: the user did it from the library page, so no toast.
            break
        }
    }

    // MARK: - Imports

    /// Whether Import into Folio… is offered: the service does the reading
    /// and copying, so there is nothing to import into without it.
    static var canImport: Bool {
        featureEnabled && serviceAvailable
    }

    private static let importExtensions = ["pdf", "epub", "csv", "html", "json", "opml", "xml", "zip"]

    /// File > Import into Folio…: the open panel, then `POST /imports` per
    /// chosen file with the absolute path — the service copies it at once —
    /// and the library opens to show the result arriving.
    ///
    /// The panel runs its own modal loop; it is entered from the menu
    /// action, never from inside a main-actor task (see `AGENTS.md`).
    static func importIntoFolio() {
        guard canImport,
              let state = SpaceSessionControllersManager.shared
                  .activeWindowController?.browserState else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = importExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = NSLocalizedString(
            "browser.folio.importPanelButton",
            value: "Import",
            comment: "Folio - Confirm button of the open panel that picks files to import into Folio")
        panel.message = NSLocalizedString(
            "browser.folio.importPanelMessage",
            value: "Choose PDFs, EPUBs, reading-list exports or OPML files to import into Folio.",
            comment: "Folio - Message of the open panel that picks files to import into Folio, naming the accepted kinds")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls
        let profileId = state.profileId
        let windowId = state.windowId
        Task { @MainActor in
            var failed: [String] = []
            for file in files {
                let name = file.lastPathComponent
                let kind: FolioServiceClient.ImportKind
                switch file.pathExtension.lowercased() {
                case "pdf", "epub": kind = .file
                case "opml", "xml": kind = .opml
                default: kind = .export
                }
                do {
                    _ = try await FolioServiceClient.shared.importFile(
                        path: file.path, kind: kind,
                        service: kind == .export
                            ? FolioServiceClient.exportService(forFileName: name) : nil,
                        profileId: profileId)
                } catch {
                    AppLogWarn("[SaveForLater] import of \(name) refused: \(error)")
                    failed.append(name)
                }
            }
            if let first = failed.first {
                showToast(
                    title: String(
                        format: NSLocalizedString(
                            "browser.folio.importFailedToast",
                            value: "Couldn't import %@",
                            comment: "Folio - Toast shown when a file chosen for import was refused by the Folio service; the placeholder is the file name"),
                        first),
                    message: "", windowId: windowId)
            }
            guard failed.count < files.count else { return }
            openLibrary(in: state)
        }
    }

    // MARK: - Reveal and open-original by path

    /// The jail for an absolute path the library page hands back: after
    /// standardizing and resolving symlinks it must lie inside the
    /// registered folder (resolved the same way), name no hidden component
    /// under it, and be either a directory or a `.md`/`.mhtml`/`.pdf`/
    /// `.epub` file that exists. Anything else is refused, never mapped.
    nonisolated static func libraryPathURL(_ path: String, folder: URL) -> URL? {
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let candidatePath = candidate.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard candidatePath == root || candidatePath.hasPrefix(rootPrefix) else { return nil }
        let relative = candidatePath.dropFirst(rootPrefix.count).split(separator: "/")
        guard !relative.contains(where: { $0.hasPrefix(".") }) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return candidate }
        guard ["md", "mhtml", "pdf", "epub"].contains(candidate.pathExtension.lowercased()) else {
            return nil
        }
        return candidate
    }

    private struct OpenOriginalPayload: Decodable {
        let path: String
        let tabId: Int?
    }

    /// `saveForLater.openOriginal { path }`: the original the page cannot
    /// open itself. A PDF (and a webpage copy) opens as a tab of the
    /// page's own window — the active Profile's — and an EPUB goes to
    /// whatever the Mac opens EPUBs with. The path is jailed as above.
    nonisolated static func handleOpenOriginal(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(OpenOriginalPayload.self, from: data) else {
            return
        }
        Task { @MainActor in
            guard let url = libraryPathURL(payload.path, folder: registeredFolderURL) else {
                AppLogDebug("[SaveForLater] openOriginal refused")
                return
            }
            switch url.pathExtension.lowercased() {
            case "pdf", "mhtml":
                let state = payload.tabId.flatMap { findTab($0)?.state }
                    ?? SpaceSessionControllersManager.shared.activeWindowController?.browserState
                state?.createTab(url.absoluteString, customGuid: nil, focusAfterCreate: true)
            case "epub":
                NSWorkspace.shared.open(url)
            default:
                AppLogDebug("[SaveForLater] openOriginal: not an original")
            }
        }
    }
}
