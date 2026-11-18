# Sync-TraktorLibrary.ps1

Tallies your music `Library` folder, diffs it against the Traktor Pro collection,
and merges new tracks + M3U playlists into a **copy** of `collection.nml`.
The real Traktor file is never touched unless you pass `-InstallToTraktor`.

## Settings: Sync-TraktorLibrary.conf

Machine-specific settings (your library path, Traktor path, playlist folder, ...) live in
`Sync-TraktorLibrary.conf` next to the script. It is git-ignored. On the first run the script creates
it with instructions in its comments and exits; edit it and run again.

Any parameter of the script can be set there as `Name = value` (switches: `true`/`false`).
A parameter given on the command line overrides the file.

## Quick use

```powershell
cd <folder with the script>
.\Sync-TraktorLibrary.ps1                 # tally + diff, then asks before writing the merge
.\Sync-TraktorLibrary.ps1 -ReportOnly     # just show what would change
.\Sync-TraktorLibrary.ps1 -Apply          # write collection.merged.nml, no questions
```

Works in both Windows PowerShell 5.1 and PowerShell 7.
If scripts are blocked: `powershell -ExecutionPolicy Bypass -File .\Sync-TraktorLibrary.ps1`

## What it does

| Source                      | Becomes in Traktor                                   |
|-----------------------------|------------------------------------------------------|
| `Library\Tracks\**\*.flac`  | Collection entries (no playlist)                     |
| `Library\M3U\*.m3u`         | One playlist per file, inside the Traktor folder named by `PlaylistFolder`, same track order as the M3U |

The M3U files are the source of truth for playlists: tracks added to, removed from or
reordered in an M3U are applied to the Traktor playlist with the same name.
Existing Traktor entries are left byte-for-byte untouched (cues, grids, keys, ratings survive).
New entries get title / artist / album / track number / year / length from the FLAC tags
(filename and folder name as fallback); Traktor analyses BPM, key and waveform itself.

## Output (in a random work folder, `%TEMP%\TraktorSync-<id>`, unless you pass `-WorkDir`)

- `collection.original.<timestamp>.nml`  untouched copy of what Traktor had
- `collection.merged.nml`                 the result
- `report.<timestamp>.txt`                the diff in text form, with full paths

The work folder is deleted at exit after a successful `-InstallToTraktor`, after "nothing to merge"
and after answering no at the merge prompt. It is kept (the path is printed) after `-ReportOnly`,
after a merge that was not installed, and after any error or refused install. Old ones (7 days)
are swept at the next start. A folder you name with `-WorkDir` is never deleted.

## Putting it into Traktor, and the backup

Close Traktor (it rewrites collection.nml on exit and would overwrite your merge), then run:

```powershell
.\Sync-TraktorLibrary.ps1 -Apply -InstallToTraktor      # asks to confirm; -Force skips the question
```

Traktor itself keeps a copy of the collection in
`<Traktor dir>\Backup\Collection\collection_2026y11m15d_13h50m24s.nml` each time it saves.
The install step follows the same regime:

1. Refuses if Traktor is running.
2. Copies the live file to `Backup\Collection\collection_<yyyy>y<MM>m<dd>d<HH>h<mm>m<ss>s.nml`
   (same folder and name pattern Traktor uses).
3. Refuses if the live collection.nml changed since the script started.
4. Verifies the backup copy by SHA-256 hash. Any failure aborts before the live file is touched.
5. Only then overwrites collection.nml and prints the one-line rollback command.

Without `-InstallToTraktor` the script never writes outside its work folder.

## Optional switches

| Switch                     | Effect                                                                   |
|----------------------------|--------------------------------------------------------------------------|
| `-RemoveMissingTracks`     | Drop collection entries under `Library\Tracks` whose file no longer exists |
| `-RemoveOrphanPlaylists`   | Drop Traktor playlists in the `PlaylistFolder` that have no matching M3U |
| `-PlaylistFolder <name>`   | Traktor playlist folder to sync into (created if missing)               |
| `-LibraryRoot`, `-TraktorBase`, `-TraktorRoot`, `-WorkDir` | Paths. No `-TraktorRoot`: uses the only `Traktor*` folder in `TraktorBase`; errors if several |

Without the two `-Remove…` switches, nothing is ever deleted; those cases are only reported.
