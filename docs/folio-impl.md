# Folio implementation

How the three design layers ([storage](folio-storage.md),
[backend API](folio-api.md), [UI](folio-ui.md)) are built when the backend
is an HTTP service hosted by the Sentinel that drives the browser over CDP.
This document replaces the "App broker" half of the backend API, which
assumed the native app served bytes to Mirage over the extension bridge.
The storage layer and the UI are unchanged by it; the UI simply calls HTTP.

## Decision: a row inside phi-agent, not a new component

The service is a plugin row in `phi-agent-dsh`, `phi-folio`, serving
`/phi-agent/api/folio/v1/…` through the Service Broker. Not a standalone
Sentinel component. Three facts decide it:

1. **CDP consent.** The browser admits a CDP peer without prompting only
   when the process is Phi-signed, its argv names the `phi-agent`
   component, and it descends from this browser's Sentinel
   (`AgentPeerIdentity.firstPartyAgent`). Any other process gets the
   consent prompt, with a 180 s wait and a 403 on refusal. A Folio process
   of its own would prompt the user on every cold start.
2. **One CDP connection per process.** The `phi-cdp` row owns the
   process's single shared connection, lazily opened, and every consumer
   goes through `ctx.phiCdp`. Shadow windows, tab targeting and the
   dialog-recovery helpers are already there.
3. **Reach and auth are hard-coded per service.** A new service id has to
   be added to the browser's `BrokerService` enum, the SDK's
   `LocalServiceID`, the broker's `knownService`, the runner's
   `nodeServiceIDs`, the signed `ServiceBrokerPolicy.json`, and the
   registry's `runtime_config`, across four repositories. A path prefix
   under phi-agent needs one policy entry.

The cost is coupling Folio's availability to phi-agent's. The Sentinel
runs only when the user is signed in, authenticated and has AI enabled
(`AuthenticatedSentinelSessionPolicy.shouldRun`). **Folio captures, watches,
feeds and imports therefore need a signed-in account with AI on.** Today's
Folio works signed out. This is a product change that comes with the
architecture the user chose; the library page still opens signed out and
reads the folder through the one native call kept for it (below), but
nothing is captured or polled until the Sentinel is up.

What stays native is the way in and the way out: menus, the open panel,
toasts, the per-Profile folder preference, and the Mirage extension's
place on the broker allowlist. No native code reads or writes an item any
more.

## Topology

```
Mirage library page ──serviceFetch("phi-agent", "/api/folio/v1/…")──┐
Mirage worker (highlights, site-action triggers) ────────────────────┤
Phi native (menus, open panel, folder prefs, toasts) ─PhiAgentTransport┤
                                                                     ▼
                                   service-broker.sock ──► phi-agent.sock
                                                                     │
                                                          phi-agent-dsh
                                                          ┌─ phi-folio row ─────────────┐
                                                          │ routes  /api/folio/v1/*     │
                                                          │ store   the Folio folder(s) │
                                                          │ jobs    capture/import/poll │
                                                          │ sched   15-min sweep        │
                                                          │ events  SSE                 │
                                                          └──────┬──────────────────────┘
                                                                 │ ctx.phiCdp
                                                                 ▼
                                                   Phi CDP over CDPAgentSocket
                                                   agentSpace.shadow.* + standard CDP
```

- Requests arrive through the broker with `X-Phi-Broker-Capability`
  checked by the transport row, then the Auth0 bearer checked by the
  user-auth chain; the row reads the caller with `requireUser(req)`.
- Mirage is not on the broker allowlist today (only Sidecar, Lexington,
  Kensington are). Two browser changes are required: Mirage's pinned id in
  `ServiceBrokerExtensionProtocol`, and a `ServiceBrokerPolicy.json` entry
  giving Mirage `phi-agent` with path prefix `/api/folio`. The policy is
  Ed25519-signed at build time, so this is a release change, not a config
  flip.
- Native callers use `PhiAgentTransport` with the bearer and no extension
  id, as the chat transport already does.
- The library page is an extension page, so it has the bridge and uses
  `serviceFetch` from `@phi-ai/api-base`, with `requireNative` so a
  `legacy` transport never falls back to loopback for file data.

## The library folder and Profiles

There is one Folio folder for the account; Profiles do not have folders of
their own. The native app owns the preference and **registers** the folder
with the service; the service never guesses a path.

```
PUT  /api/folio/v1/library      { folderPath }   -> { folderPath, status }
GET  /api/folio/v1/library                       -> { folderPath, status } | 503 folder_unavailable
```

Native calls `PUT` at Sentinel readiness and whenever the preference
changes. The service persists it under its data dir
(`<FOLIO_DATA_DIR>/library.json`, default `<ARTIFACTS_STORAGE_PATH>/folio`)
so a restart serves the library before the browser registers again. Until a
folder is registered every library call answers `503 folder_unavailable`.

A browser Profile appears only where a hidden window is opened. A capture
names the Profile whose cookies the page should load with (`profileId` in
the request body, `Default` when absent), the item records it as
`profile:` in its frontmatter, and a later watch check or re-capture uses
the same one. A subscription may carry `profile:` for `fetch: page`.

The **path jail** is the registered folder. Every location, basename,
folder path, id, version name and import name is validated by the same
grammar the storage design states, and the service builds every path
itself. The one exception is `POST /imports` from the native open panel,
which carries an absolute path to the chosen file: the native app is a
trusted caller, the file is copied into the hidden import store at once,
and the path is never stored.

A folder on a volume that is not mounted answers `503 folder_unavailable`
on every call until it is; the library page shows the folder-unreadable
state it has today.

## HTTP API

Base: `/phi-agent/api/folio/v1`. JSON unless stated. Every request carries
the bearer. Items and folders are addressed by **query**
(`?location=…&basename=…`), not by path segments: a location is a
variable-length path of its own and a basename may hold anything but a
slash, so a path form cannot say where one ends and the other begins. The
listing below is the shape as built (`phi-agent-dsh/plugins/folio/src/lib/routes.ts`).
Errors are
`{ "error": code, "detail"?: string }` with the codes from the backend
API doc (`bad_name`, `bad_location`, `not_found`, `exists`, `conflict`,
`too_large`, `io`) plus `profile_unknown`, `folder_unavailable`,
`browser_unavailable`, `job_running`.

### Locations, folders, items

```
GET    /locations                                  -> [{ location, count }]
GET    /list?location=inbox[/folder][&recursive=1] -> { location, entries: [Entry] }
GET    /list?location=all                          -> { entries: [Entry & {location}] }
POST   /folders           { location, name }       -> { location }
PATCH  /folders           { location, name?, to? }   rename, then move
DELETE /folders?location=                          -> { trashed }

GET    /item?location=&basename=                   -> { fields, tags, highlights, siblings, etag, size, modified, birth }
GET    /file?location=&name=                       bytes; Range; ETag "size-modified"
PUT    /file?location=&name=                       bytes; If-Match when the file exists;
                                                   X-Folio-Snapshot: edit|capture|rebuild|restore
POST   /items             { location?, basename, text }   create a .md (inbox default) -> 201
PATCH  /item?location=&basename=   { to?: location, rename?: basename, only?: ext }
DELETE /item?location=&basename=                   -> { trashed }
POST   /migrate-root                               the one-time move of root items into _inbox
```

`reveal` and `open-original` are not routes: the page asks the native app
for them with the absolute path, since only the app can show Finder or
open a tab.

`Entry` is the listing shape from the backend API doc (`name, size,
modified, birth, head?, kind?`), with heads served under the same budget.
`PUT …/file/{name}` is the one write path: `If-Match` carries the ETag the
caller read, a mismatch is `412 conflict`, and the `X-Folio-Snapshot`
header is required when the target exists, which keeps the
snapshot-before-overwrite invariant on the server. An `external` snapshot
is taken by the service on its own when the file's stat differs from what
it last wrote or listed.

Large bodies: the broker caps non-streaming responses at 64 MiB and the
in-app client at 16 MiB, and the extension bridge bounds request bodies.
Reads of a webpage copy use `Range` in 8 MiB steps from the page; uploads
of a dropped PDF or EPUB go through an upload session:

```
POST   /uploads                 { location?, basename, ext, size }  -> { uploadId }
PUT    /uploads/{uploadId}/parts/{index}   bytes, ≤ 8 MiB each
POST   /uploads/{uploadId}/complete         -> { location, basename }   then the extract job starts
DELETE /uploads/{uploadId}
```

An upload idle for ten minutes is swept, the same way the native
chunked write's tokens are today.

### Versions, records, state

```
GET    /versions?location=&basename=               -> { versions: [{ name, stamp, kind, ext, size }] }
GET    /version?location=&basename=&name=          bytes
POST   /versions/restore  { location, basename, name } -> { ok, etag }

GET    /records?kind=feed|import                   -> { records: [RecordHead & { fields, state }] }
GET    /record?kind=&path=                         -> { text, fields, tags, etag, state }
PUT    /record            { kind, path, text }, If-Match
PATCH  /record            { kind, path, rename }
DELETE /record?kind=&path=

GET    /state?kind=&id=                            -> { state }
PUT    /state             { kind, id, state }      written atomically
```

Versions are addressed by item, not by id, so the page never spells an id
in a URL; the service reads the id from the head and refuses an item
without one on every versions call except `restore`-free listing, which
answers empty.

### Jobs: capture, import, watch, poll

Everything that opens a browser window or outlives a request is a job:
`202 Accepted` with a job, then `GET /jobs/{id}` or the event stream.

```
POST   /capture        { url, profileId?, location?, trigger, title?, key?, locale? } -> 202 Job
POST   /recapture      { location, basename }                               -> 202 Job
POST   /watch/check    { location, basename }                               -> 202 Job
POST   /feeds          { url, folder?, title?, schedule?, fetch?, keep?, tags?, profileId? } -> 201 record + first poll Job
POST   /feeds/poll     { path } | /feeds/poll-all                           -> 202 Job(s)
POST   /feeds/discover { pageUrl }                                          -> { feeds: [{url,title}] }
POST   /feeds/unsubscribe { paths }
POST   /feeds/mark-read { path, guids }
GET    /jobs?active=1 | /jobs/{id}                                          -> Job
POST   /jobs/{id}/cancel

POST   /extract        { location, basename }                               -> 202 Job (PDF/EPUB text, a `rebuild` version)
POST   /imports        { kind: export|opml|site|file, path?, service?, source?, folder?, profileId?, title? } -> 202 { job, record? | location, basename }
POST   /imports/resume { path } ; POST /imports/stop { path }
POST   /feeds/bulk     { paths, schedule?, fetch?, keep?, folder?, paused? }
GET    /feeds/opml                                                          application/xml
POST   /uploads        { basename, ext, size, purpose?: item|import, location?, service?, folder?, profileId? } -> 201 { uploadId, partBytes }
PUT    /uploads/{id}/parts/{index}   raw bytes ≤ 8 MiB ; POST /uploads/{id}/complete -> 202 ; DELETE /uploads/{id}
POST   /repair                                                              -> { paired, duplicates, orphans }

Job = { id, kind, profileId, status: queued|running|done|failed|cancelled,
        progress?: { phase, found, saved, skipped, failed, current? },
        result?: { location, basename } | { changed, versions } | …, error?, startedAt, finishedAt }
```

A capture is a background task in the service, not work the request
waits on. The request records the capture under the row's data dir
(`pending-captures/<id>.json`) and queues a job on the browser lane; the
job opens the hidden window and writes the item. A capture the browser
channel cannot take yet (`browser_unavailable`) stays recorded and runs
when the channel connects; a capture queued when the process stops is
reloaded at the next start. A capture that fails for its own reason (the
page is gone) is dropped and the job carries the error.

Idempotency: `POST /capture` takes an optional `Idempotency-Key`; a key
seen in the last ten minutes returns the existing job. A site-action
trigger from Mirage uses the trigger URL plus the ten-minute window as the
key, which keeps the native handler's duplicate rule. One job per
(kind, target) at a time; a second request returns the running job with
`job_running`.

### Highlights and notes

```
POST   /highlights     { source, text, markdown?, fragmentUrl, pageTitle?, location?, profileId? }
                       -> { location, basename, block, created: bool }
POST   /notes          { location, basename, block, note }
```

The service finds the item by normalized `source` across every location,
appends under the last `## Highlights` with the numbering rules from
`document.ts`, writes `highlights: true`, and creates the item with a
link-stub body when there is none, then queues a capture for it.

### Events

```
GET    /events          text/event-stream
  event: library  data: { folderPath, status }
  event: folder   data: { dirs: [relative dir] }
  event: job      data: Job
  event: watch    data: { id, location, basename, changed, error? }
  event: feed     data: { recordPath, status, added, expired, error? }
```

The service watches each registered folder with `fs.watch` (recursive on
macOS), coalesced to 300 ms, and ignores its own writes by path and stat.
The library page holds one stream through `broker.stream.*`, which the
broker streams without a size cap. The native app holds one through
`PhiAgentTransport` and turns `watch` events into the change toast and
`job` completions for native-initiated captures into the save toast. The
`LIBRARY_CHANGED` runtime message and the app's FSEvents watcher from the
backend API doc are both replaced by this stream.

### Cleanup

```
GET    /cleanup         -> { orphans: [{ kind, id, size, source? }] }
POST   /cleanup/trash   { entries }
```

## Capture over CDP

The pipeline that replaces Mirage's `save.ts`, `capture.ts` and
`shadow-copy.ts`, running in the row with `ctx.phiCdp`.

1. **Window.** `agentSpace.shadow.create { taskId: "folio:" + jobId,
   profileId }` on the private channel, then `agentSpace.shadow.openTab
   { taskId, url }`. The seed tab the window spawns with is ignored: the
   target is the page target in that `windowId` (via
   `Browser.getWindowForTarget`) whose URL is the requested one. A
   `shadow.ping` every 60 s keeps the window alive for a slow page or a
   video gist; the window is closed with `shadow.close` in a `finally`,
   and a boot sweep closes any `shadow.list` entries prefixed `folio:`.
   At most two Folio windows at once, shared with phi-agent's own slot
   discipline so a feed poll cannot starve a chat task.
2. **Attach and ready.** `Target.attachToTarget { flatten: true }`,
   `Page.enable`, `Runtime.enable`, `Inspector.enable` (a crashed-target
   event means a renderer-less tab; `Page.reload` wakes it). A hidden
   window is still an audio source, so the tab is muted through the
   private channel's tab update before the page gets a chance to play,
   and the page function below pauses media as well. Wait for
   `Page.loadEventFired` or 20 s, then
   apply `Emulation.setDeviceMetricsOverride` from the window bounds, since
   a never-foregrounded tab has a 0×0 viewport and lazy content never
   mounts. The dialog guard from `PhiAgentSpace.getJavaScriptDialogState`
   runs on every timeout.
3. **Settle and expand.** Inject the same page functions Mirage's content
   script runs today (pause media, the settle walk, expander clicks) with
   `Runtime.evaluate`; nobody is looking, so the clicks that are refused on
   a watched page are fine here. The site's readiness selector from the
   reader rules decides when the item is on the page.
4. **Extract.** As built: the article is first asked of one of our
   extensions in the shadow window's profile (`phiCdp.extractPage`, the
   same path chat uses for a user tab), which carries the site rules. When
   no extension answers there (`extract_unavailable`: the worker asleep,
   the AI switch off — the measured case for a fresh shadow window), the
   row runs the same ladder itself: `Readability.js` and `ReaderExtract.js`
   evaluated in the page as `EXTRACT_SOURCE`, the winner picked by Mirage's
   rule (a `rule` rung, or coverage ≥ 0.15). A clean `no_article` from the
   extension is final. Either way the content HTML is rendered in the page
   by `MARKDOWN_SOURCE` (`turndown.js` + `ReaderMarkdown.js`, with the
   winner's code blocks). Both sources are generated verbatim from Mirage's
   `public/extraction/` by `phi-agent-dsh/scripts/generate-folio-markdown-source.mjs`
   (`--check` in review), so one extractor exists and the artifact stays a
   single file. The result is the markdown, byline and site
   `document.ts` expects.
5. **Webpage copy.** `Page.captureSnapshot { format: "mhtml" }` on the
   session; the reply is the archive as a string, written straight to
   `<basename>.mhtml` through the same snapshot-before-overwrite path. No
   base64 chunking: the file never crosses the bridge.
6. **Document.** `articleDocument` / `videoDocument` from `document.ts`,
   which also moves to the shared package with its tests, write the `.md`
   with a fresh id. A video gets its gist from phi-agent's existing video
   pipeline in-process, with the `rebuild` snapshot rule when it lands.
7. **Report.** The job finishes with `{ location, basename }`; the
   `job` event reaches the page and the native toast.

A PDF open in a tab is captured by fetching the response body in the
page (`fetch(url)` under the page's origin through `Runtime.evaluate` with
`returnByValue` on a base64 string, in 8 MiB slices) or, when the URL is
plain, by the service fetching it with the profile's cookies read through
`Network.getCookies`; the first is the default, the second the fallback.

Watch checks and feed polls (`fetch: page`, the default) are this pipeline with a
different landing location and the hash comparison from the storage
design in front of the write. `fetch: entry` polls never open a window:
the service fetches the feed URL with the profile's cookies for that host
and writes entries from the feed body.

Site-list imports (X bookmarks, Reddit saved, YouTube liked) keep the
collect-by-scrolling logic from `import-history.ts`, ported to CDP on a
shadow window: the list page in one tab, each item through the capture
pipeline. The measurement that X mounts nothing in an off-screen window
is real; the port keeps the collector tab in the user's last-focused
window as `agentSpace.spaces.openTab { activate: false }` and only the
item captures in shadow windows.

## Scheduler

One timer in `ctx.effect`, 15 minutes, first tick a minute after boot.
Each tick lists `_watch/` recursively and the feed records, computes what
is due from each item's schedule and the hidden state's last-run stamp,
and queues jobs oldest-first with a cap per tick (eight checks, four
polls). A late tick runs what is due once; nothing is replayed. Runner's
`jobs.*` are not used; the architecture says phi-agent owns scheduled
work. The `feature/folio-feeds-phase2` branch carries a `phi-cron` row
with the same tick and a sleep clock; when that lands, the sweep moves
onto it.

## What is built (2026-10-21)

`phi-agent-dsh/plugins/folio`, row `phi-folio`, mounted after the chat
rows: the grammar, frontmatter and document model (moved from Mirage's
`document.ts`, with a message catalog); the store with
snapshot-before-overwrite, folders, moves, versions, records, hidden state,
orphan listing and the root migration; jobs with per-lane caps and key
de-duplication; the SSE hub; the CDP capture (`shadow.create`, the sonic
tab scope and session, `extractPage` with the in-page Readability ladder
as its fallback, the in-page markdown pass, both generated from Mirage's
`public/extraction/` scripts, `Page.captureSnapshot`); watch checks; feed polling with the fetcher and
parser from the feeds branch; the scheduler; imports (Pocket, Instapaper,
Raindrop, Omnivore, bookmarks HTML, markdown zips, OPML, and the X, Reddit
and YouTube site lists collected over CDP in the user's window) with a run
record, a hidden export copy and a resume ledger; PDF text through pdf.js
and EPUB through its spine; upload sessions; feed bulk changes, pausing
and OPML export; the repair pass; the routes above. The package tests, the
bundle gate, the repository type-check and the boot check pass. The
Mirage page and the browser changes (allowlist, policy, registration,
menus, toasts) are built in their own repositories; see their docs.

## What each repository changes

**phi-ai**

- `phi-agent-dsh/plugins/folio/`: the row. Routes through `ctx.phiRoutes`
  (`kind: "prefix"`, user tier), the store (grammar, snapshots, listing
  with head budget, folders, records, state, hidden area), jobs, the
  scheduler, the SSE hub, the CDP pipeline through `ctx.phiCdp`. Added to
  `bundle/cordis.patch.yml`, `rows.generated.ts` regenerated, and
  `structure-gate.test.ts` updated with the row and package and the
  reason.
- `packages/folio-document/` (name to settle): `document.ts`, the
  extraction scripts, the reader rules loader; browser-safe, consumed by
  Mirage and the row. Mirage's copies become imports.
- Mirage: the library page is rewritten to the UI design against
  `serviceFetch`; the worker keeps the highlight content script and the
  site-action triggers and turns them into `POST /highlights` and
  `POST /capture`; `save.ts`, `capture.ts`, `shadow-copy.ts`,
  `import-history.ts`, `library-data.ts`'s broker calls and the
  `saveForLater.fs.*` vocabulary are deleted once the row ships, not kept
  as a fallback (one pipeline, as the capture doc insists).
- `@phi-ai/api-base`: nothing; the prefix is under `phi-agent`.

**phibrowser-mac**

- `ServiceBrokerExtensionProtocol`: Mirage's pinned extension id joins the
  allowlist. `Resources/ServiceBrokerPolicy.json`: Mirage → `phi-agent`,
  methods GET/POST/PUT/PATCH/DELETE, prefix `/api/folio`.
- `SaveForLaterService` shrinks to: folder registration (`PUT /library`
  on readiness and preference change, through `PhiAgentTransport`), the
  File and context menu actions (`POST /capture`, with `location: watch`
  for Watch This Page), the Import open panel (`POST /imports` with the
  chosen path; the service reads it, so no upload session is needed from
  native), `openLibrary`, toasts driven by the `/events` stream, and two
  item-level messages that only the app can act on: `saveForLater.reveal
  { path }` and `saveForLater.openOriginal { path }`. The service cannot
  call into the app, so `reveal` and `open-original` answer the page with
  the absolute path, the page sends that message, and the app checks the
  path lies inside a registered folder before showing it in Finder,
  opening a PDF in a tab, or handing an EPUB to `NSWorkspace`.
- `saveForLater.fs.*`, `fs.write*`, `delete`, `rename`, the path jail,
  the renamed-archive bookkeeping and the listing head budget are deleted
  with the cutover. `SaveForLaterPathJailTests` and
  `SaveForLaterListingTests` go with them; their cases are re-stated as
  row tests.
- Settings: the Folio section's folder picker stays; a line says Folio
  needs the account signed in for captures.

**sentinel / sentinel-registry**: nothing for the row itself. phi-agent's
`runtime_config` gains no new param; the row reads its data dir from the
existing `paths.data_dir`. If the reader-rules bundle is to update
independently of phi-agent releases, it becomes a `third_party` asset the
registry ships and the row loads from `AppGroup/bins/…`; the first version
bundles it.

**phi-reader-rules**: a build target that emits the rules as one JSON the
shared package imports.

## Cutover

1. Ship the row behind a remote-config flag (`folio_service`), with the
   routes live and the scheduler off. Mirage keeps today's pipeline.
2. Ship the browser changes (allowlist, policy, folder registration,
   `/events` toasts). Verify `serviceFetch("phi-agent", "/api/folio/v1/locations")`
   from the library page in canary.
3. Switch the library page and the save paths to the service when the flag
   is on; the native `saveForLater.fs.*` handlers stay for one release as
   the fallback the flag selects, then are deleted. The flag never selects
   per request; it selects the pipeline at Mirage worker boot, the way the
   broker's `legacy` handshake works.
4. Turn the scheduler on. Items at the root of existing folders are offered
   the one-time move into `_inbox/` from the page.

### Top-level folders

Location kind `folder`: `folder/<path>` is `<root>/<path>`, a directory the
person made beside Folio's underscore sections (grammar `kindDir`, depth
up to eight). `folder` alone is the root: `GET /list?location=folder`
answers its folders only (root files stay Inbox items), writes and moves
into it are refused with `bad_location`, and `POST /folders` on it makes a
top-level folder. `GET /locations` counts it beside `inbox` and `watch`.
The page shows these under a Folders heading with a + and a drop target,
lists them in Move to… after the Inbox tree, and titles the scope
"Folders".

### Feed entries as pages

A subscription defaults to `fetch: page`: every poll lists the feed's
entries without a `captured` stamp, newest by `published` first, and
sends up to `PAGE_CAPTURES_PER_POLL` (10) of them to the capture queue,
new or not, so a feed switched to page mode fills in on its next poll and
a first poll of a busy feed does not open dozens of windows at once. The
captures are the ordinary durable background jobs (retried when the
browser is away), landing on the entry file by `source`: the body becomes
the article, the `.mhtml` is written beside it, and `extraction` flips
from `feed` to `page`. `fetch: entry` keeps the feed's text only.

### Library page mode and the development loopback

- Mirage's boot probe (`GET /library`) treats a **404 as legacy mode**: a
  phi-agent without the Folio row answers 404 for every Folio path, which
  the native client reads as `notServed`; any other answer (a 503
  `folder_unavailable`, a 401) is service mode, and only a transport failure
  (a broker that does not admit Mirage) is legacy by error. Before this, a
  Sentinel whose phi-agent predates Folio showed "Folio is not reachable"
  instead of the legacy page.
- A development build of Mirage can bypass the broker:
  `VITE_FOLIO_SERVICE_BASE_URL=http://127.0.0.1:8799 pnpm build` makes the
  Folio client call that base URL directly (the bearer still goes along),
  mirroring the native app's `PhiAgentLoopbackOverride` default. Packaged
  builds never set it, so the broker stays the only transport there.

## Verification

- Row tests: grammar (every location, folder, id, version and import
  name, including the underscore rule), snapshot-before-overwrite with an
  externally modified head, `If-Match` conflicts, the re-pairing pass,
  duplicate-id resolution by birth time, listing head budget, folder
  delete removing hidden state by the ids read from heads, upload session
  sweep, job idempotency.
- CDP tests against a running canary, not mocked: shadow window create,
  seed-tab avoidance, viewport override before any capture, `captureSnapshot`
  size on a heavy page, ping keep-alive across a 3-minute job, dialog
  recovery, renderer-less tab wake, boot sweep of `folio:` windows.
- Broker tests: Mirage's policy entry admits `/api/folio` and refuses
  `/api/…` elsewhere; a request from the page with a stale token gets the
  401 through as a response.
- Product check before the flag goes on: a signed-out profile sees the
  library page with its folder and a clear line about captures needing
  sign-in; no silent failure.

## Open points

- The local Sentinel checkout is behind the shipped broker (`full_uds`,
  the native-caller rule, `X-Phi-Service-Capability`). The policy entry
  and the native registration call must be checked against the current
  `main` on GitHub before the browser change is written.
- Whether site-action captures should still fire while the Sentinel is
  down. The design queues them in the Mirage worker (`chrome.storage.local`,
  bounded, URL-keyed) and flushes when `/locations` answers, so a like
  made offline is still saved; the alternative, dropping them with a
  toast, is simpler. Decide at cutover.
- The upload part size and the broker's request-body bound need one
  measured number; 8 MiB is a guess inside the known 16 MiB client cap.
