# Folio backend API

> The [implementation](folio-impl.md) hosts this layer as an HTTP service
> inside phi-agent in the Sentinel, driving the browser over CDP. The
> "App broker" section below describes the contract as a native broker
> would serve it; the implementation maps every call to an HTTP route and
> keeps the semantics, and is the authoritative shape for building.

The second of Folio's three layers: [storage](folio-storage.md) is what is
on disk, this is the contract that reads and writes it, and the
[UI](folio-ui.md) is built on this. It covers the broker between the
native app and Mirage, the messages between Mirage's library page and its
worker, and the data layer the page reads.

Ownership does not move. The native app owns preferences, gates, the path
jail, open panels, menus and toasts. Mirage owns everything that means
something: extraction, document construction, frontmatter, the library
page, and every long-running run (save, import, watch, feed poll). The
broker serves bytes and names and never interprets them, with one
exception it already has: it reads a frontmatter head so the listing can
carry it.

## Conventions

Every message is a JSON object. Replies are a JSON object with either the
result fields or `{ "error": <code> }`.

- Every call carries `tabId`, the tab it acts for, so the folder resolves
  to the Profile that owns that tab. The library page passes its own.
- Every call that names an item carries `location` and `basename`.
  `location` is `inbox`, `watch`, `folder/<path>` (a top-level folder of
  the person's own), `feed/<record path>` or
  `import/<record path>`, optionally followed by `/<folder path>` for a
  folder the person made inside it (`inbox/rust`, `inbox/to read on the
  train`, `feed/Tech/Rust Notes/older`); omitted means `inbox`. The broker
  maps each to its underscore-prefixed directory; the extension never
  spells an underscore. For reading, `inbox` also covers the root of the
  folder, where versions before this layout saved, so today's callers,
  which name root items with no `location`, stay valid; a write with no
  `location` lands in `_inbox/`. A file inside an item is named by `name`
  (`<basename>.<ext>`) where the call needs an extension.
- The gate is unchanged: the sender must be Mirage and the feature on.
  Every refusal is a reply, never a dropped message.
- Error codes: `unavailable` (gate), `bad_name`, `bad_location`,
  `not_found`, `exists`, `conflict` (precondition failed), `unknown_token`
  (chunked write), `too_large`, `io`.
- Bytes travel base64 in chunks of 512 KiB, inside the bridge's 1 MiB
  message cap, in both directions, as today.
- Timestamps are ISO 8601 UTC seconds, the `timestamp()` dialect the
  documents use. File times in listings are epoch seconds.

## App broker: `saveForLater.*` (extension to app)

### Listing

```
fs.list        { tabId, location? }
            -> { folder, location, entries: [Entry] }
fs.list        { tabId, location, recursive: true }
            -> { folder, location, entries: [Entry & { location }] }
fs.list        { tabId, location: "all" }
            -> { folder, entries: [Entry & { location }] }

Entry = { name, size, modified, birth, head?, kind? }
```

A listing names the folders the person made inside the location as
entries with `kind: "folder"` and no size; a record's underscore directory
is never listed as a folder, it is the record's. `recursive` walks one
location's folders for a scope's "all items" view and for the watch
scheduler; `all` walks every location.

`head` is the first bytes of a `.md`, frontmatter first, within the
listing's shared budget; the extension fills missing heads with reads as
it does today. `birth` is new: the file's creation time, which the
duplicate-id rule needs. The listing reports every file of the location,
so an original with no `.md` beside it is visible to the re-pairing pass
rather than dropped. The `all` form walks every location in one reply,
newest heads first across locations, for the lookups that must find an
item wherever it is: already saved, the import duplicate check, the
highlight match. It never descends into `.folio.noindex`.

### Reading

```
fs.read        { tabId, location, name, offset, length }
            -> { data, eof }
```

Accepts `.md`, `.mhtml`, `.pdf` and `.epub`.

### Writing

```
fs.writeText   { tabId, location, name, text, expect?, snapshot? }
            -> { ok: true, size, modified }
            -> { error: "conflict", size, modified }

fs.writeBegin  { tabId, location, name, snapshot? }   -> { token }
fs.writeChunk  { token, data }                        -> { ok }
fs.writeEnd    { token }                              -> { ok, name, size, modified }
```

- `expect: { size, modified }` is the precondition the editor sends. A head
  that no longer matches gets `conflict` and nothing is written.
- `snapshot` is the reason tag for the version the broker takes before
  overwriting an existing `.md`: `edit`, `capture`, `rebuild` or `restore`.
  It is required when the target exists; the broker refuses an overwrite
  without one, so no caller can replace a head unversioned by accident. The
  broker adds an `external` snapshot of its own first when the head's
  `size`/`modified` differ from what it last wrote or listed.
- A write that creates an item defaults `location` to `inbox`. A write to
  `_watch/` or a feed or import directory is only ever an overwrite or a
  run's own output; the worker names those explicitly.
- The reply's `size`/`modified` seed the next `expect`.

### Folders

```
fs.folders.create  { tabId, location, name }        -> { location }
fs.folders.rename  { tabId, location, name }        -> { location }
fs.folders.move    { tabId, location, to }          -> { location }
fs.folders.delete  { tabId, location }              -> { ok, trashed }
```

`location` names the folder; `name` is one component under the same
rules as a basename, refused when it starts with `_` or `.`. `move` takes
the folder, items and all, to another folder or location root. `delete`
trashes the directory whole after reading the ids from the heads inside
it, so their hidden entries go with it; the reply counts what went. A
Folio directory (`_inbox` and the rest, a record's `_` directory) is
refused by every one of these.

### Item operations

```
fs.rename      { tabId, location, from, to, only?, toLocation? } -> { basename }
fs.move        { tabId, from: { location, basename }, to }       -> { basename }
delete         { tabId, location, basename }                     -> { ok }
reveal         { tabId, location, basename }                     -> { ok }
openOriginal   { tabId, location, basename }                     -> { ok }
```

- `rename` moves every sibling, as today, and bumps to the first free
  basename. With `only: "mhtml" | "pdf" | "epub"` it moves that one file,
  and with `toLocation` across locations: this is the re-pairing pass
  bringing an orphan back beside its `.md`.
- `move` is the location change: every sibling, same basename unless taken,
  nothing under `.folio.noindex` touched. `to` is `inbox` or `watch`,
  each optionally with a folder path; a record's entry directory
  is never a destination.
- `delete` trashes the siblings and the item's hidden entries by its id,
  which the app reads from the head it already serves.
- `openOriginal` opens the item's `.pdf` in a new tab of the owning
  Profile, or hands an `.epub` to the system until Folio has a reader. The
  extension cannot open a `file:` URL itself.

### Versions

```
fs.versions.list     { tabId, id }
                  -> { versions: [{ name, stamp, kind, ext, size }] }
fs.versions.read     { tabId, id, name, offset, length }
                  -> { data, eof }
fs.versions.restore  { tabId, id, name, location, basename }
                  -> { ok, size, modified }
```

`restore` snapshots the current head as `restore`, then copies the version
over it; the `.mhtml` follows only when the version is a `capture`. The
listing is the directory, newest last; the extension sorts for display.

### Records (subscriptions and import runs)

```
fs.records.list    { tabId, kind }                         -> { entries: [Entry] }
fs.records.write   { tabId, kind, basename, text, expect? } -> { ok, size, modified } | conflict
fs.records.rename  { tabId, kind, from, to }                -> { basename }
fs.records.delete  { tabId, kind, basename }                -> { ok }
```

`kind` is `feed` or `import`; `basename` may carry a folder path in front
of it (`Tech/Rust Notes`). A record is the `.md` plus the `_<basename>/`
directory beside it; the directory and the hidden state move or go with
it. Record writes take no
`snapshot`: the frontmatter is Folio's and the body is preserved by the
writer, which reads before it writes.

### Hidden state

```
fs.state.read   { tabId, kind, id }         -> { state } | not_found
fs.state.write  { tabId, kind, id, state }  -> { ok }
```

`kind` is `watch`, `feed` or `import`; `state` is an object the broker
stores as JSON without reading it. Writes are atomic (temp and rename).

### Import store

```
fs.writeBegin         { tabId, store: { kind: "import", id }, name }  -> { token }
fs.read               { tabId, store: { kind: "import", id }, name, offset, length }
fs.import.ledger.append  { tabId, id, line }        -> { ok }
fs.import.ledger.read    { tabId, id, offset? }     -> { lines, eof }
```

The export copy goes through the chunked write with a `store` in place of
a `location`; `name` is `export.<ext>` with the extension from the grammar.
The ledger is append-only; a line is one JSON object.

### Cleanup

```
fs.cleanup.list   { tabId }            -> { orphans: [{ kind, id, size, source? }] }
fs.cleanup.trash  { tabId, entries }   -> { ok }
```

Hidden entries whose id no item or record in any location claims. `source`
is read from the newest `.md` snapshot's head for a versions directory, so
the clean-up sheet can say what the history was of. Nothing is trashed
without the call.

### Folder changes

```
app -> ext   saveForLater.folderChanged   { profileId, locations: [location] }
```

The app watches the library folder with FSEvents and broadcasts which
locations changed, coalesced to a few hundred milliseconds. The library
page refreshes the shelves it shows; the worker uses it to notice a file
dragged into `_watch/`. The page's own `focus` and the worker's
`LIBRARY_CHANGED` runtime message stay as they are for Folio's own writes.

### Native-initiated

```
app -> ext   saveForLater.save        { requestId, tabId, windowId, trigger, location? }
app -> ext   saveForLater.addNote     { location, basename, block, note, tabId }
app -> ext   saveForLater.importFile  { tabId, location: "inbox", basename, ext }
app -> ext   saveForLater.importRun   { tabId, kind: "export" | "opml", service?, name, ext }
```

- `save` gains `location`: the File menu's Watch This Page saves straight
  into `_watch/`; everything else lands in the inbox. `saveResult` is
  unchanged.
- `importFile` follows the native open panel copying a `.pdf`/`.epub` into
  the inbox; the worker extracts and writes the `.md` beside it. Until it
  does, the listing shows an orphan original, which is the honest state.
- `importRun` follows the open panel accepting an export file: the app has
  stored it as a new run's `export.<ext>` under a fresh run id it minted
  for the occasion, and the worker takes it from there. `service` is the
  app's guess from the extension and file name; the worker confirms or
  asks.
- `addNote` carries `location` now, since the item may be in the inbox.

Unchanged: `getArmed`, `armedChanged`, `trigger`, `toast`, `videoGist`,
`videoArticles`, `saveResult`.

## Mirage runtime messages (library page to worker)

The page talks to the broker directly for anything immediate: reads,
listing, an edit's write, a move, a delete, versions. Anything that opens
shadow windows, outlives the page or must not run twice goes through the
worker, following the import's existing split: the page has the
vocabulary, the worker has the machine.

```
sfl:libraryChanged                                   (worker -> pages, exists)

sfl:importStart    { kind: "site", source }                    (exists)
sfl:importStart    { kind: "export", runId }                   new: resume or start a stored run
sfl:importStart    { kind: "opml", runId }
sfl:importStop     { runId? }
sfl:importStatus                               -> ImportProgress | null
sfl:importProgress ImportProgress & { runId, record }         (broadcast)

sfl:saveAgain      { location, basename }      -> { ok } | { error }
sfl:watchCheck     { id }                      -> { ok }   one check now
sfl:watchProgress  { id, phase: "checking" | "unchanged" | "changed" | "failed", error? }
sfl:feedPoll       { id }                      -> { ok }   one poll now
sfl:feedProgress   { id, phase: "polling" | "done" | "failed", added, error? }
sfl:feedMarkRead   { id, guids }               -> { ok }
sfl:subscribe      { url, title?, schedule?, fetch?, keep? } -> { basename, id } | { error }
sfl:feedPollAll    {}                            -> { queued }
sfl:feedUpdate     { ids, schedule?, fetch?, keep?, folder? } -> { ok }   bulk record change
sfl:unsubscribe    { ids }                       -> { ok, trashedEntries }
sfl:exportOpml     {}                            -> { opml }   feed folders as outlines
sfl:discoverFeed   { pageUrl }                 -> { feeds: [{ url, title, type }] }
```

- One run per key: a second `importStart` for a running `runId`, a second
  `watchCheck` for an id already checking, a second `feedPoll` likewise,
  returns the status of the one in flight. The worker keeps the in-flight
  set in `chrome.storage.session`, so a page cannot start a parallel run
  by being opened twice, which is the bug the import's split exists for.
- `saveAgain` is a re-capture through the normal save pipeline with
  `snapshot: "capture"`: new article and `.mhtml`, `captured` set,
  `## Highlights` tail carried over.
- `subscribe` writes the record and its first poll's state; `discoverFeed`
  reads a page's `<link rel="alternate">` through a content-script call
  and is what the save toast's Subscribe uses.
- `ImportProgress` gains `runId` and `record` (the run's basename), and
  `phase` gains `resuming`.

## Scheduling

The worker owns one `chrome.alarms` alarm, `sfl:tick`, every 15 minutes.
On each tick it lists `_watch/` and `_feed/*.md`, computes what is due from
each item's schedule and its hidden state's `lastChecked`/`lastFetched`,
and runs due work through the shadow-copy slot gate (two copies at a time,
shared with saves and imports, so a feed poll cannot starve a save). Due
work is ordered oldest-first and capped per tick (eight watch checks,
four feed polls); the rest waits for the next tick. A Profile whose
feature is off, or in Guest mode, is skipped. The library page's Check
now and Poll now go through the same path and jump the queue.

## Data layer (`library-data.ts`)

```ts
interface LibraryItem {
  location: Location;           // scope plus the folder path inside it
  folder: string;               // the folder path alone, "" at the root
  basename: string;
  id: string | null;            // null on a legacy item
  title; source; saved; site; type; trigger;
  captured: string | null;
  edited: string | null;
  watch: "daily" | "weekly" | null;   // meaningful only in _watch/
  tags: string[];
  highlights: number;
  original: "mhtml" | "pdf" | "epub" | null;
  sha256: string | null;
  size: number; modified: number; birth: number;
}

interface FeedRecord  { basename; id; title; url; site; schedule; fetch; keep; subscribed; tags; unread: number; state: FeedState | null }
interface ImportRecord { basename; id; title; service; file; started; finished; status; items; failed; state: ImportState | null }
```

`listItems(tabId, { location })` returns one shelf; `findItems(tabId,
{ source })` and `findItems(tabId, { sha256 })` use the `all` listing and
are what every "already saved" check calls. `itemsFromEntries` keeps
folders and orphans as separate return values rather than items, and reports
duplicate ids with each file's `birth` so the page can resolve them.
`parseFrontmatter` learns the one-line flow sequence for `tags`;
everything else it parses already.

## Compatibility

- A Mirage that predates this reads an app that has it unchanged: every
  new field is optional and `location` defaults to the inbox, which
  reads the root.
- An app that predates this answers the new messages with
  `unavailable`, which the page shows as the feature being off, the way it
  already shows an app too old for video articles.
- Nothing rewrites an existing file on upgrade. Ids, `highlights: true`
  and `sha256` on legacy items appear with the first write that touches
  them for another reason.
