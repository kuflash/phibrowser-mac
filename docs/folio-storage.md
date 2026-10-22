# Folio on-disk storage

Design for the next Folio features: version history, editing the markdown,
importing from other read-later services, manual PDF/EPUB import and watched
pages. This document decides only what lands on disk and what the native
broker lets the extension do with it. UI, extraction and scheduling are
separate work and are named at the end as out of scope.

It is the first of three layers: this document is what is on disk, the
[backend API](folio-api.md) is the contract that reads and writes it, and
the [UI](folio-ui.md) is built on that contract. It builds on
[Folio capture](folio-capture.md) and the
[native library](folio-native-library.md). The principle those set still
governs everything here: **the folder is the library**. Obsidian, Spotlight,
grep and a sync client are browsing UIs of equal standing with Folio's own,
there is no database beside the files, and nothing Folio does may silently
rewrite what a person saved.

## What exists today

```
~/Documents/PhiFolio/                         (global, or a per-Profile override)
  2026-10-21 Why Rust ships slowly.md         the item: frontmatter + body + ## Highlights
  2026-10-21 Why Rust ships slowly.mhtml      optional webpage copy, same basename
  2026-10-19 Some talk highlight.md           " highlight" marker = holds Folio highlights
```

- One item is one basename. Rename moves every file of the basename; delete
  trashes them.
- Metadata is the frontmatter block, always first in the file and short, so
  the listing's bounded head carries it: `title`, `source`, `saved`, `site`,
  `byline`, `type` (`article` | `video`), `trigger`, `extraction`.
- `source` (URL, `normalizedSource`) is the item's identity for "already
  saved", for appending highlights and for import de-duplication.
- The broker is content-agnostic and name-jailed: a bare `<basename>.md` or
  `.mhtml` in the folder, no separators, no leading dot. It lists, reads in
  chunks, writes text or a chunked stream to a `.part` then renames into
  place, renames pairs, trashes pairs, reveals.

Every new feature below is expressed as an extension of this shape. None of
them moves an existing item or requires a migration pass.

## Layout

```
~/Documents/PhiFolio/                         Folio's directories, and the person's own folders
  2024-03-11 An older save.md                 a file from before this layout; read as Inbox
  2024-03-11 An older save.mhtml
  Research/                                   a top-level folder the person made (location `folder/Research`)
    Papers/
      2026-10-12 Attention revisited.md

  _inbox/                                     where everything lands and lives; Folio made it
    2026-10-21 Why Rust ships slowly.md       head: what the person reads and edits
    2026-10-21 Why Rust ships slowly.mhtml    current webpage copy
    2026-09-02 Attention is all you need.md   a PDF item: extracted text
    2026-09-02 Attention is all you need.pdf  the original, as imported
    2026-08-15 Dune.md                        an EPUB item
    2026-08-15 Dune.epub
    rust/                                     a folder the person made; any depth
      2026-10-02 Cargo features that should have been defaults.md
    to read on the train/
      2026-10-18 Long read.md

  _watch/                                      pages Folio re-captures on a schedule
    2026-10-21 Acme pricing.md                an ordinary item; being here is the intent
    2026-10-21 Acme pricing.mhtml
    2026-10-21 Rust release notes.md
    2026-10-21 Rust release notes.mhtml

  _import/                                     runs that brought items in from elsewhere
    Pocket 2026-10-21.md                      the run: service, file, counts, status
    _Pocket 2026-10-21/                       what it brought, ordinary items; Folio made it
      2019-03-11 Old Pocket article.md
      2019-03-11 Old Pocket article.mhtml
      2021-07-02 Another one.md
    X bookmarks 2026-10-22.md                 the site-list imports use the same shape
    _X bookmarks 2026-10-22/
      2026-10-22 Some thread on X.md
      2026-10-22 Some thread on X.mhtml
    OPML 2026-10-22.md                        a run with no items: it made subscriptions

  _feed/                                       subscriptions and what they brought in
    Tech/                                     a folder the person made, to group feeds
      Simon Willison.md                       the subscription: feed URL, schedule, keep policy
      _Simon Willison/                        its entries, ordinary items; Folio made it
      2026-10-21 Prompt injection, again.md
      2026-10-20 Weeknotes.md
      Hacker News front page.md
      _Hacker News front page/
        2026-10-21 Show HN Something.md
        2026-10-21 Show HN Something.mhtml    a feed fetched as full pages has copies

  .folio.noindex/                             Folio's own area; not an item, not browsed
    _feed/
      01JB3G5J7L9N1Q3S5U7W9Y1A3C.json         runtime state of one subscription
    _watch/
      01JB0Z5H7G3QWX2K9R4M8N6P7T.json         runtime state of one watched item
    _import/
      01JB4H6K8M0P2R4T6V8X0Z2B4D/             by import run id
        export.csv                            the export file, kept for resume
        ledger.jsonl                          one line per item: outcome
    versions/
      01JB0Z5H7G3QWX2K9R4M8N6P7T/             by item id, so renames do not matter
        20261021T140502Z.capture.md           snapshot of the head as it was
        20261021T140502Z.capture.mhtml
        20261103T091500Z.edit.md
        20261110T060000Z.capture.md
        20261110T060000Z.capture.mhtml
```

Six rules make the layout:

1. **An item is `<basename>.md` plus optional siblings.** Every item file
   is `<basename>.<ext>` with `ext` in `md | mhtml | pdf | epub`, and the
   `.md` is the item. A sibling with another extension is that item's
   original. This is today's pair rule with two more extensions, and it
   holds in every place an item can be.
2. **Items live in one of four locations, and the location is a state.**
   `_inbox/` is where everything lands and where it lives: a manual save,
   a site-action save, a dropped PDF, and anything the person pulls out of
   a feed or an import. There is no second shelf to promote things to; the
   Inbox is the library, arranged with folders. `_watch/` holds the pages
   Folio re-captures on a schedule. `_import/<run>/` is what one import
   run brought in, and `_feed/<name>/` what one subscription brought in.
   An item moves between locations whole, with its siblings, and keeps its
   basename and id. Watching is a move into `_watch/`; stopping a watch,
   or taking an entry out of a feed or a run, is a move into `_inbox/`;
   the trash is the only way out.
3. **A folder Folio makes starts with an underscore; a folder a person
   makes never does.** `_inbox`, `_watch`, `_feed`, `_import` and every
   record's entry directory are Folio's. Any other directory is the
   person's, at any depth inside any location, and Folio treats it as a
   plain folder of items. The one character is the whole distinction, so
   Finder and Obsidian show it too, and the underscore sorts Folio's
   folders to the top. A user folder may not start with `_` or `.`.
4. **`_feed/` and `_import/` pair a record with a directory.** A
   subscription is `<basename>.md` plus `_<basename>/` of its entries
   beside it; an import run is `<basename>.md` plus `_<basename>/` of what
   it brought. Both may sit inside a person's folder (`_feed/Tech/`). The
   record's frontmatter is Folio's, its body is the person's. Entries and
   imported items live apart from the inbox because a feed brings dozens
   of items a day and an export brings thousands, and either would bury
   what the person saved by hand.
5. **One hidden directory holds everything that is not an item.** It is
   dot-prefixed so Obsidian ignores it and Finder hides it, and carries the
   `.noindex` suffix so Spotlight does not return five copies of every
   edited article. It is created on first use. A library without it is
   simply a library with no history yet.
6. **The hidden area is keyed by id, never by basename or location.**
   Renaming an item, a folder or a subscription, or moving an item between
   locations or folders, touches nothing under `.folio.noindex/`.

### Folders

A person can make a folder anywhere an item can be: in the inbox, in
`_watch/`, inside a feed's or a run's entry directory, and as a group
inside `_feed/` or `_import/` to arrange subscriptions and runs. A folder
is only ever a directory; Folio keeps no record of it beyond its name.
Nesting is capped at eight levels, which is a grammar limit, not a
feature.

A person can also make folders **at the root, beside Folio's sections**:
`<root>/Research/Papers/` is the location `folder/Research/Papers`, and
the library page shows these under a **Folders** heading of their own.
They never collide with Folio's directories because a person's folder
never starts with an underscore or a dot. The root itself (`folder`) only
arranges them: a write there is refused, and a file lying at the root is
an older inbox save, listed by the Inbox.

A folder inherits the meaning of the location it is in: an item in
`_watch/pricing/` is watched, an item in `_inbox/to read on the train/`
is still an inbox item. Watch and To inbox move an item to the root of
the destination unless the person chooses a folder, and the last folder
chosen per destination is remembered; Move to… inside the Inbox is the
same move between its own folders.

Renaming or moving a folder moves everything in it; ids are unaffected,
so history, watch and feed state follow. Deleting a folder trashes it
whole, and the broker reads the ids from the heads inside it first so
their hidden entries go too, the same as deleting the items one by one.
An empty folder is kept until the person deletes it; Folio never removes
a directory it did not make.

### Inbox

The inbox is the library. Every save that creates an item lands in
`_inbox/` and stays there; the person arranges it with folders, moves it
to `_watch/` to track it, or trashes it. Nothing in the inbox expires and
nothing has to be done to an item for it to count as kept: saving was the
decision. "New" is a view, not a state: the page marks what arrived since
it was last looked at, and that mark lives in the page, not on disk.

Everything that applies to an inbox item applies to an item in any
location: the pair rule, versions, edits, highlights. "Already saved" and
the import's duplicate check look in every location, so a page saved last
month is found whether it sits in the inbox, `_watch/` or a feed or import
directory, and a highlight taken today lands in that item wherever it is.

**The root of the folder** holds only Folio's directories and, in a
library that predates this layout, the items earlier versions saved
there. Those are read as inbox items: the Inbox location is `_inbox/`
plus, for reading, the root. No write ever lands at the root again, and
Folio offers once, on the first open after the change, to move the root's
items into `_inbox/`; declining leaves them where they are, still listed.
A folder the person makes at the root is treated as an inbox folder.

### Item id

Every item gains a stable `id` in its frontmatter: a ULID (26 characters,
Crockford base32, time-ordered). New saves write it. An existing item
without one is given one the first time Folio needs it, which is the first
versioned operation on that item: an edit, a re-capture, enabling a watch.
That operation snapshots the head before touching it (see below), so the
file as the person had it is the first version in the history and the
`id:` line is the only change the head sees.

The id is not the identity for matching a page to an item. That stays
`source`. The id exists so the hidden area survives renames.

A ULID rather than something derived: a hash of `source` would tie
identity to a page address, which a file item does not have and an edited
note never had. A ULID needs no central counter, sorts by creation time,
is unique across libraries, and the extension mints it at write time
without asking the broker, which only checks the grammar.

**Assignment adopts before it mints.** Whenever Folio is about to give an
item an id, it first looks for an orphan versions directory, one whose id
no item in any location carries, whose snapshots name the same `source`
(or `sha256` for a file item). If there is one, the item takes that id and
its history is back. Only when there is none is a fresh id minted. This is
what recovers an `id:` line a person deleted in an editor: the item reads
as a legacy one, and on its next versioned operation the history reattaches.
An id edited to a value that fails the grammar is treated as absent and
recovers the same way. One edited to a different valid value names a new
item; its old history is orphaned and is merged under the new id by the
same `source` match, with the newer snapshot winning on an identical stamp.

**Two files with one id** come from Finder's Duplicate, a sync client's
conflict copy or a copy-paste in Obsidian. Two items sharing one history
would interleave their snapshots, so the listing resolves it: the file with
the later creation time (the APFS birth time, which a duplicate gets fresh
even when its modification time is preserved) is given a new id and starts
with empty history; the original keeps everything.

**A file copied into another library** keeps its id and arrives with no
history, since the hidden area is per library. Two libraries merged later
cannot collide on ids.

Only the versions directory is worth reattaching. The watch, feed and
import state files are disposable: a lost watch state costs one extra
content check, a lost feed state lets an expired entry come back once as
new, a lost import state loses the resume shortcut. Orphaned hidden state
is never deleted on Folio's initiative; the library offers a clean-up that
trashes hidden entries no item or record in any location claims.

## Frontmatter

The block stays the single, first, short YAML map the listing already
parses. Every value is a scalar on one line, except `tags`, which is a YAML
flow sequence on one line (`tags: [rust, compilers]`) so the existing
line-based parser can read it and Obsidian's properties view can too.
Empty values are dropped, as now.

| Key | Written by | Meaning |
| --- | --- | --- |
| `id` | every write from now on | stable item id, see above |
| `title`, `source`, `site`, `byline`, `trigger`, `extraction` | unchanged | |
| `type` | capture, import | `article` \| `video` \| `pdf` \| `epub` |
| `saved` | first save | when the person kept this. For a third-party import it is the date the other service recorded, so a 2019 Pocket article is a 2019 item |
| `captured` | capture, re-capture | when the current head's content was taken from the source. Absent means equal to `saved` |
| `edited` | Folio's editor | when Folio's own editor last wrote the head. External editors leave it alone; the version history still records them |
| `sha256` | every item with a `.pdf` or `.epub` original | hash of the original bytes; the identity of an item with no URL, and what re-pairs an orphaned original after a rename |
| `highlights` | first highlight | `true` once Folio has written a `## Highlights` section. Replaces the ` highlight` basename marker, which a rename can drop; the marker is still read on legacy items and no longer written |
| `import` | import run | on an imported item: the run record's id, what re-pairs a run directory with a renamed record |
| `imported`, `imported_from` | third-party import | when Folio wrote it, and from which service (`pocket`, `instapaper`, `raindrop`, `omnivore`, `bookmarks-html`, `markdown-folder`) |
| `tags` | import, editor | the person's tags, carried over from the other service or set in the editor |
| `watch` | watch UI, editor | the schedule of an item in `_watch/`: `daily` \| `weekly`; absent means `daily`. Outside `_watch/` the line is inert |
| `watch_selector` | watch UI | optional CSS selector narrowing what counts as the page's content |
| `profile` | capture | the browser Profile whose hidden window captured the page; a re-capture or watch check uses the same one. One library serves every Profile |
| `type: import`, `service`, `file`, `status`, `items`, `failed` | import run | on an import record only, see Imports |
| `feed` | feed fetch | on an entry: the feed URL it came from. `trigger` is `feed` |
| `published` | feed fetch | on an entry: the entry's own date from the feed; `saved` is when Folio wrote it |
| `type: feed`, `url`, `schedule`, `fetch`, `keep` | subscribe UI, editor | on a subscription file only, see Subscriptions |

The dated basename keeps using `saved`, so imported items file themselves on
the day they were kept, not the day of the import. The library's list sorts
by `saved`, not by file modification time; the modification time stays what
it is today, a cache key.

Watch *intent* is the item's location: it is in `_watch/` or it is not, and
a person can start or stop a watch by moving the file in Finder or
Obsidian. The frontmatter only tunes it. Watch *state* (last check, last
hash, last error) changes on every check and lives in the hidden area so a
check never rewrites the person's file.

## Renames outside Folio

The folder is the library, so a person renames files in Finder and
Obsidian, and Folio has to read the result as the same library. Nothing
important is keyed by a file name: the hidden area follows the id, the
title comes from the frontmatter, `source` still matches the page, the
basename's date is cosmetic because sorting uses `saved`, and moving the
file into or out of `_watch/` is just a move. The broker's record of what
it last wrote has no entry under the new name, so the next Folio write
takes a spare `external` snapshot first. An editor holding the old name
gets a not-found on save and reloads.

Two things do break and get a repair rule.

**The original is orphaned.** Obsidian and most editors rename only the
`.md`; the `.mhtml` or `.pdf` keeps the old basename, the item shows no
webpage copy and nothing lists the orphan. A listing that holds an
original with no `.md` beside it triggers a re-pairing pass, run by the
extension because it is the side that reads frontmatter:

- an orphan `.mhtml` carries its page address in the
  `Snapshot-Content-Location` header Chromium writes; it is matched to the
  item, in any location, whose `source` equals it and that has no sibling;
- an orphan `.pdf` or `.epub` has no such header, so every item with one
  carries `sha256`, and the orphan is hashed once and matched the same way;
- the match renames and, if needed, moves the orphan alone to the item's
  basename and location through a single-file rename. An orphan that
  matches nothing is left where it is and the library shows it as such.

The same pass re-pairs a record with its directory: a renamed
`_feed/<basename>.md` is matched to a directory whose entries carry its
`url` in their `feed` line, a renamed `_import/<basename>.md` to a
directory whose items carry its id in their `import` line, and the
directory is renamed to follow.

**The highlight marker is lost.** Today the ` highlight` tail of a
basename is what says a `## Highlights` section is Folio's; a rename that
drops the word makes the section read as the article's own, so the count
shows zero and the next highlight opens a second section. The marker
moves to the frontmatter as `highlights: true`, written with the first
highlight. The basename tail is still read on items that have it and is no
longer written.

**What is not recovered.** A name that starts with a dot hides the file
from Folio until it is renamed back. A rename to a name another item holds
is refused by the file system before Folio sees it.

## Versions

A version is a snapshot of the head's files at a moment. The head in the top
level is always the newest; `.folio.noindex/versions/<id>/` holds what the
head used to be.

File name: `<stamp>.<kind>.<ext>`, where `stamp` is `YYYYMMDDTHHMMSSZ`,
`kind` is one of

| kind | snapshot taken because |
| --- | --- |
| `capture` | a re-capture is about to overwrite the head: a watch found a change, or the person chose Save again |
| `edit` | Folio's editor is about to write |
| `rebuild` | a video article is about to be rebuilt when its gist lands |
| `external` | Folio is about to overwrite a head that changed since Folio last wrote it (Obsidian, a sync client), and has no snapshot of that change |
| `restore` | the person is restoring an older version over the head |

and `ext` is the head file's extension. A `capture` snapshot takes the `.md`
and the current `.mhtml`/`.pdf` together; every other kind takes only the
`.md`, because an edit does not change the original and the original must
not be duplicated for it.

The name carries everything the history needs: there is no manifest. The
listing of the directory is the history, newest last. A snapshot's own
frontmatter is whatever the head carried at the time, untouched.

**Snapshot before overwrite** is the one invariant. Any write that replaces
a head `.md` that already exists first copies the head into the version
directory under the kind that names the reason. `FileManager.copyItem` is a
clone on APFS, so the copy is instant and costs no space until the head is
rewritten. An existing head Folio did not write (its size or modification
time differs from what the broker recorded after its last write to that
file) is snapshotted as `external` before any other kind, so an edit made in
Obsidian is never lost to a watch re-capture an hour later. Last writer
still wins on the head; nothing is lost from the history.

**Restore** snapshots the current head as `restore`, then copies the chosen
version's files over the head. The `.mhtml` is restored only when the chosen
version was a `capture`; otherwise the current original stays.

**Retention**: `.md` snapshots are kept without limit; they are small.
Original snapshots (`.capture.mhtml`, `.capture.pdf`) are kept for the
newest five captures per item, older ones are deleted when a new capture
lands. The number is a constant to start with, not a preference.

**Delete** trashes the head's files and the item's version directory and
watch file together. The hidden area never outlives its item.

## Editing

The editor in the library page writes through the broker's existing text
write, extended with a precondition: `saveForLater.fs.writeText` accepts an
optional `expect: { size, modified }` taken from the listing the editor
loaded from. When the head no longer matches, the broker refuses with
`conflict` and writes nothing; the page offers to reload or to overwrite,
and overwrite goes through the same snapshot-before-overwrite path, so the
other side's text is in the history as `external` before it is replaced.

The editor writes the whole file, frontmatter included, and is the one
place that sets `edited`. It must preserve the `## Highlights` section
verbatim: highlight blocks are anchored by their own text for note
insertion, and an editor that reflows them breaks that anchor.

A video item whose gist arrives after the person has edited it is not
rebuilt over their text. The rebuild path checks `edited` and, when set,
writes the article as a `rebuild` snapshot only and leaves the head alone;
the library can offer it from the history.

## Originals: PDF and EPUB

A PDF or EPUB item is a `.md` plus the original under the same basename.
How the original arrived decides only the frontmatter:

- **From a tab** (a PDF open in the browser, Save): `source` is its URL,
  `trigger: manual`, the bytes are the response body streamed through the
  chunked write with ext `pdf`, replacing the MHTML capture that makes no
  sense for a PDF.
- **From Finder** (File > Import into Folio…, or a drop onto the library
  page): no `source`; `sha256` of the bytes, `trigger: import`,
  `imported_from` absent. The native side owns the open panel and copies the
  file into the inbox as `<basename>.pdf` itself, since the extension
  cannot read arbitrary paths; a drop hands the page the bytes, which go
  through the same chunked write. Both land identically and then ask the
  extension to extract the markdown.

The `.md` body is the extracted text: for a PDF the text layer (pdf.js in
the extension), for an EPUB the chapters converted with the same HTML to
markdown pass articles use, images inlined as data URLs under the same size
cap as article images. A file that yields no text gets the link-stub body
articles get, with the note saying so. The `.md` is what the reader shows
and what highlights attach to; "open original" opens the sibling in the
browser's PDF viewer or, later, an EPUB reader.

Every item with a `.pdf` or `.epub` original carries `sha256`, whichever
way it arrived. Duplicate detection for file imports is by it, the way
`source` is for pages, and it is what re-pairs an orphaned original after
a rename. The listing serves the frontmatter, so no extra read is needed.

## Imports

An import is a run that brings items in from somewhere that is not a page
the person is looking at: a service's export (Pocket, Instapaper, Raindrop,
Omnivore, a bookmarks HTML file, a folder of markdown), one of the
site-list imports Folio already has (X bookmarks, Reddit saved, YouTube
liked), or an OPML file of subscriptions. Every run has the same shape on
disk.

**The run record** `_import/<basename>.md`, named `<Service> <date>`, is a
markdown file whose frontmatter Folio writes when the run starts and
again when it ends or is resumed, and whose body is the person's:

```
---
id: 01JB4H6K8M0P2R4T6V8X0Z2B4D
title: Pocket 2026-10-21
type: import
service: pocket
file: ril_export.csv
started: 2026-10-21T15:30:00Z
finished: 2026-10-21T16:12:40Z
status: done
items: 2993
failed: 7
---
```

`status` is `running` \| `done` \| `stopped` \| `failed`; a `running`
record with no live run behind it is one the browser quit on, and is
offered for resume. A run that created subscriptions rather than items
(OPML) has a record and no directory.

**The items** land in `_import/<basename>/` the ordinary way, differing
only in the frontmatter: `trigger: import`, `imported_from: <service>`,
`imported: <stamp>`, `import: <run id>`, `tags` carried over, and `saved` set from the export's
own date, so a 2019 Pocket article is a 2019 item. For an export that only
names URLs each item is fetched through the existing shadow-copy save and
gets a real article and webpage copy; one that carries full text is
written as-is with `extraction: imported` and no webpage copy. The
site-list imports keep their current `trigger` value and gain the same
record and directory.

Nothing in an import directory expires. **To inbox** moves an item out of
the run and into `_inbox/`, or a folder in it; a run of three thousand
items is gone through at the person's pace and the directory empties as
they go, or stays as the run's own folder if they prefer it that way.

**Runtime state** is `.folio.noindex/import/<id>/`:

- `export.<ext>`: a copy of the export file, so a run interrupted at item
  400 of 3,000 can resume without asking for the file again.
- `ledger.jsonl`: one line per item, `{ source, outcome, basename?,
  error? }`, appended as the run goes. Resume reads it to skip what already
  landed; de-duplication by `source` against the listing of every location
  is still the authority, and the ledger only saves re-checking.

The ledger is a log, not an index: deleting it loses nothing but the resume
shortcut. **Deleting a run** trashes the record, its directory and its
hidden state; items the person moved out of it are no longer the run's
and stay. **Renaming** one renames the record and the directory together.

## Watched pages

A watched item is an item in `_watch/`. Moving it there, from the inbox,
a feed or an import, starts the watch; moving it to the inbox stops it, and its history stays in the versions
directory either way. The schedule is the item's `watch:` line, `daily`
when absent. The scheduler finds watched items by listing `_watch/`, which
it already can; there is no registry to keep in step, and a file dragged
into `_watch/` in Finder is watched from the next pass.

A page that advertises a feed is better served by a subscription, and the
UI can offer that instead of a watch; on disk the two stay distinct.

Its runtime state is `.folio.noindex/watch/<id>.json`:

```json
{
  "lastChecked": "2026-11-10T06:00:00Z",
  "lastChanged": "2026-11-10T06:00:00Z",
  "contentHash": "sha256:…",
  "status": "active",
  "error": null,
  "consecutiveFailures": 0
}
```

A check opens the page as a shadow copy, extracts with the item's selector
when it has one, normalises the markdown (whitespace, the attribution and
timestamp lines Folio itself writes) and hashes it. An unchanged hash only
updates `lastChecked`. A changed hash is a re-capture: snapshot the head as
`capture`, write the new `.md` with `captured` set and the `## Highlights`
tail carried over exactly as the video rebuild carries it today, stream
the new `.mhtml`, update the state file. A diff between any two versions is
computed on demand from the markdown; nothing is stored for it.

Repeated failures set `status: error` with the reason and stop the
schedule; the item stays in `_watch/`, so the person's intent is not
silently dropped, and the library shows why.

## Subscriptions

A subscription is a feed (RSS, Atom or JSON Feed) that Folio polls and
turns into items. It is the counterpart of a watched page: a watch is for a
page that changes in place, a subscription for a site that announces new
pages.

**The subscription file** `_feed/<basename>.md` is a markdown file whose
frontmatter is the configuration and whose body belongs to the person, for
notes about why they follow it. Folio writes the frontmatter when the
subscription is created or changed from its UI and otherwise leaves the
file alone, so a person can edit it in Obsidian and the next poll reads the
change.

```
---
id: 01JB3G5J7L9N1Q3S5U7W9Y1A3C
title: Simon Willison
type: feed
url: https://simonwillison.net/atom/everything/
site: simonwillison.net
schedule: hourly
fetch: page
keep: 30d
subscribed: 2026-10-21T15:30:00Z
tags: [ai, python]
---
```

| Key | Values | Meaning |
| --- | --- | --- |
| `url` | feed URL | what is polled; `source` is not used, a subscription is not a page |
| `schedule` | `hourly` \| `daily` \| `weekly` \| `off` | poll interval; `off` keeps the entries and stops polling |
| `fetch` | `entry` \| `page` | `page` opens each entry URL in the shadow window and saves it like a manual save, article and `.mhtml` both, the newest uncaptured entries first and at most 10 per poll (the rest keep the feed's text until a later poll reaches them); `entry` writes only what the feed carries (title, summary or content) and no webpage copy. Default `page` |
| `keep` | `30d`, `90d`, `forever` | how long an entry stays before it is trashed. Default `30d` |
| `subscribed` | stamp | when it was created |

**Entries** are ordinary items in `_feed/<basename>/`, dated by `published`.
An entry carries `trigger: feed`, `feed: <url>`, `published`, `saved`, and
`extraction: feed` while its body is the feed's own text; a page capture
replaces the body, adds `captured` and the `.mhtml`, and sets
`extraction: page`. Its `source` is the entry's
link, so the usual de-duplication, highlight matching and "already saved"
apply unchanged. An entry has an `id` from the moment it is written, which
is what makes keeping it cheap.

**To inbox** moves an entry out of the feed: its files go to `_inbox/`
or a folder in it, same basename, same id, same history, and nothing
under `.folio.noindex/` changes. From then on it is the person's item and
the feed's expiry never sees it again. The reverse move does not exist.

**Expiry** runs with each poll: entries whose `published` is older than
`keep` are trashed together with their hidden state. The feed's seen set
(below) still remembers them, so an expired entry does not come back on the
next poll as new.

**Runtime state** is `.folio.noindex/feed/<id>.json`:

```json
{
  "lastFetched": "2026-10-21T16:00:00Z",
  "etag": "\"5f3a…\"",
  "lastModified": "Tue, 21 Oct 2026 15:58:01 GMT",
  "status": "active",
  "error": null,
  "consecutiveFailures": 0,
  "seen": { "<entry guid>": "2026-10-21T16:00:00Z" },
  "read": ["<entry guid>"]
}
```

`seen` is the set of entry guids already written or expired, with the time
each was first seen, trimmed to the last two thousand; a deleted or expired
entry is not fetched again because of it. `read` marks the entries the
person has opened, so the library can show unread counts without writing
into the entry's file every time it is opened. `etag` and `lastModified`
make a poll a conditional request. Repeated failures set `status: error`
and stop the schedule the same way a watch does; the subscription file and
its `schedule` line are untouched.

**OPML** import is an import run whose record has no directory: the file
is kept as its `export.opml` and each outline becomes a subscription file,
de-duplicated by `url` against the heads of `_feed/*.md`.

**Renaming a subscription** renames the file and the directory together,
the way an item's siblings move together. **Deleting** one trashes the
file, the directory and the state file; the versions of entries it held go
with them, and the versions of entries the person kept stay, since those
items are no longer the feed's.

## Broker contract

The additions, all gated as today (sender is the Mirage extension, feature
enabled) and all jailed. Payload shapes and error codes are in the
[backend API](folio-api.md); this table is what the storage layer needs
the broker to be able to do:

| Message | Does |
| --- | --- |
| `fs.list {location?}` | one location's items with their heads, as today's listing does for the folder; `location` is `inbox` (default), `watch`, `feed/<basename>` or `import/<basename>`. Lists `.pdf`/`.epub` siblings; never descends into `.folio.noindex` |
| `fs.list {location: "all"}` | every location in one reply, each entry carrying its `location`, for the duplicate checks and the highlight match. The head budget is shared, newest first across locations |
| `fs.move {from: {location, basename}, to: location}` | moves an item's files whole to `inbox` or `watch`, or a folder in either, under the first free basename there; replies with it |
| `fs.records.list {kind}` | the record files of one kind, `_feed/*.md` or `_import/*.md`, with their frontmatter heads |
| `fs.records.write {kind, basename, text}` / `fs.records.rename` / `fs.records.delete` | a subscription or import record, with its directory and hidden state moving or going with it |
| `fs.state.read {kind, id}` / `fs.state.write {kind, id, state}` | the hidden state file of a watch, feed or import |
| `fs.import.store {id, ext, …}` / `fs.import.export.read` / `fs.import.ledger.append` / `fs.import.ledger.read` | the run's export copy and ledger |
| every item call (`fs.read`, `fs.writeText`, `fs.writeBegin/Chunk/End`, `fs.rename`, `delete`, `reveal`, versions) | takes `location` beside `basename`; omitted means `kept`, which keeps today's callers valid. Writes that create an item default to `inbox`; `fs.read`, `fs.writeBegin/Chunk/End` accept `.pdf` and `.epub` names |
| `fs.writeText` | `expect: {size, modified}` precondition, `conflict` reply; snapshot-before-overwrite |
| `fs.rename`, `delete` | move or trash every sibling extension; delete also removes the item's version directory and watch file |
| `fs.rename {…, only: ext}` | renames one file of an item, across locations if asked; the re-pairing pass uses it to bring an orphaned original back beside its `.md` |
| `fs.list` reply | an original with no `.md` beside it is listed as an orphan rather than dropped, so the re-pairing pass can see it; a duplicate id across the listing is reported with each file's birth time |
| `fs.cleanup.list` / `fs.cleanup.trash {ids}` | the hidden entries no item or record claims, and trashing the ones the person chose |
| `fs.versions.list {id}` | names, sizes, stamps under the item's version directory |
| `fs.versions.read {id, name, offset, length}` | chunked read of one snapshot |
| `fs.versions.restore {id, name}` | snapshot head as `restore`, copy the version over it |
| `importFile` (app to extension) | a file the native open panel just copied in, by basename and ext |

Path construction stays entirely native. The extension names an item by
basename, an entry by `(feed, basename)`, a version by `(id, name)`, an
import by `(stamp, service)`; the broker builds the path and refuses
anything outside its grammar:

- item name: today's `brokerFileName` with `pdf` and `epub` added;
- location: `inbox`, `watch`, `feed/<path>` or `import/<path>`, each
  optionally followed by a folder path of up to eight components; `inbox`
  reads the root as well, for items from before this layout; every component follows the item rule with no
  extension and may not start with `_` or `.`; the broker alone maps a
  location to its underscore-prefixed directory, so neither an underscore
  nor a path ever comes from the extension;
- record file: `_feed/<folders>/<basename>.md` or
  `_import/<folders>/<basename>.md`, its directory `_<basename>/` beside
  it;
- id: `^[0-9A-HJKMNP-TV-Z]{26}$`;
- version name: `^\d{8}T\d{6}Z\.(capture|edit|rebuild|external|restore)\.(md|mhtml|pdf|epub)$`;
- hidden import files: `export.(csv|html|json|opml|xml|zip|md)` and
  `ledger.jsonl` under `_import/<id>/`.

The snapshot-before-overwrite check needs the broker to remember what it
last wrote: a small in-memory map of `location/basename → (size, modified)`
per folder, filled after each of its own writes and after a listing. A head
whose stat does not match is treated as externally changed. The map being
empty after a restart errs on the side of a spare `external` snapshot, which
costs a clone and nothing else.

## What this deliberately does not do

- No archive, "done" or "kept" location. Saving is the decision; the
  Inbox is where things live, folders arrange it, and Delete is the trash,
  which macOS already keeps for a while. The location grammar can take another name later without moving
  anything.
- No watch intent in frontmatter. Being in `_watch/` is the intent; a line
  that could disagree with the location would need a rule for which wins.
- No run state in the import record beyond counts and status. The record
  is read by people; the per-item ledger is a log and stays hidden.
- No per-feed state in the subscription file. The file is read by people
  and polled by Folio; a seen set of two thousand guids rewritten hourly
  would churn it in every sync client and editor.
- No per-item folders. They would solve the same problems but move every
  existing item, break every link people hold to a file, and show "index"
  as every note's name in Obsidian. The flat pair rule still holds, so it is
  extended rather than replaced.
- No manifest, index or database in the hidden area. Version names are
  self-describing, watch state is one file per item, import ledgers are
  logs. Everything is reconstructible from a directory listing.
- No storage of diffs, rendered HTML or thumbnails. All derived on demand.
- No automatic trimming of `.md` history and no preference for the original
  retention count until there is a reason.

## Out of scope here

The editor UI, the version and diff views, the PDF/EPUB extractors, the
service-specific export parsers, the feed parser, the watch and feed
scheduler (`chrome.alarms` in the Mirage worker and its interaction with the
shadow-copy slot cap), feed discovery from a page's `<link rel=alternate>`,
newsletter-to-feed bridging and the EPUB reading surface. Each is its own piece of work on top of this layout.
