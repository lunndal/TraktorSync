<#
.SYNOPSIS
    Tallies the music files in a Library folder, diffs them against a Traktor Pro
    collection.nml, and (optionally) merges the new tracks and M3U playlists into a
    COPY of the collection file.

.DESCRIPTION
    Nothing is ever written outside -WorkDir unless you explicitly pass
    -InstallToTraktor.  The flow is:

      1. Copy collection.nml  ->  <WorkDir>\collection.original.<timestamp>.nml
      2. Tally   <LibraryRoot>\Tracks   (audio files, by format / artist / size)
      3. Parse   <LibraryRoot>\M3U\*.m3u (one Traktor playlist per file)
      4. Diff    against the collection:
            - tracks on disk that are not in the collection      (will be ADDED)
            - collection tracks under Library that are gone      (reported; -RemoveMissingTracks deletes)
            - playlists: new / changed (added, removed, reordered) / orphaned
      5. Merge   -> <WorkDir>\collection.merged.nml   (after a prompt, or with -Apply)
      6. Install -> only with -InstallToTraktor: copies merged file over the real one,
                    keeping a backup in <TraktorRoot>\Backup\Collection.  Refuses while Traktor is running.

    Automatic work folder: deleted at exit after -Apply -InstallToTraktor succeeded, after
    "nothing to merge" and after answering no at the merge prompt. Kept (path is printed) after
    -ReportOnly (it holds the full-path report), after a merge that was not installed, and after
    any error or refused install. Folders older than 7 days are swept at the next start.

.PARAMETER LibraryRoot
    Folder holding "Tracks" and "M3U".
.PARAMETER TraktorRoot
    Traktor's root folder, the one holding collection.nml (e.g. ...\Traktor\Root\Traktor 4.5.1).
    Not given: looked up among the Traktor* folders in TraktorBase.
    If several hold a collection.nml, the script lists them and stops: -TraktorRoot is then required.
.PARAMETER TraktorBase
    Folder holding the Traktor version folders (e.g. "Traktor 4.5.1"). Used when TraktorRoot is not given.
.PARAMETER WorkDir
    Where copies / reports are written.  Not given: a new random folder TraktorSync-<id> in
    $env:TEMP, which is deleted at exit when nothing in it is worth keeping (see .DESCRIPTION).
    A folder you name yourself is never deleted.
.PARAMETER PlaylistFolder
    Traktor folder node that holds the M3U playlists (created if missing).
.PARAMETER ReportOnly
    Print the diff and stop (never prompts).
.PARAMETER Apply
    Write the merged file without prompting.
.PARAMETER RemoveMissingTracks
    Also drop collection entries under Library\Tracks whose file is gone.
.PARAMETER RemoveOrphanPlaylists
    Also drop Traktor playlists in PlaylistFolder that have no M3U.
.PARAMETER InstallToTraktor
    Copy the merged file over the real collection.nml (with backup, confirm).
.PARAMETER Force
    Skip the confirmation for -InstallToTraktor.

.NOTES
    Every parameter above can also be set in Sync-TraktorLibrary.conf next to the script (git-ignored),
    as "Name = value" (switches: true/false). A parameter given on the command line wins over the file.
    If the file does not exist, the script creates it with instructions and exits.

.EXAMPLE
    .\Sync-TraktorLibrary.ps1                      # tally + diff, then asks whether to write the merge
    .\Sync-TraktorLibrary.ps1 -ReportOnly
    .\Sync-TraktorLibrary.ps1 -Apply               # writes <WorkDir>\collection.merged.nml
    .\Sync-TraktorLibrary.ps1 -Apply -InstallToTraktor
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LibraryRoot,
    [string]$TraktorRoot,
    [string]$TraktorBase,
    [string]$WorkDir,
    [string]$PlaylistFolder,
    [switch]$ReportOnly,
    [switch]$Apply,
    [switch]$RemoveMissingTracks,
    [switch]$RemoveOrphanPlaylists,
    [switch]$InstallToTraktor,
    [switch]$Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$AudioExtensions = @('.flac', '.mp3', '.wav', '.aiff', '.aif', '.m4a', '.aac', '.ogg', '.wma')

# --------------------------------------------------------------------------- helpers
function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# Traktor path encoding:  C:\Users\X\a.flac  <->  VOLUME="C:" DIR="/:Users/:X/:" FILE="a.flac"
function ConvertTo-TraktorLocation([string]$WindowsPath) {
    $volume = [System.IO.Path]::GetPathRoot($WindowsPath).TrimEnd('\')          # "C:"
    $dir    = [System.IO.Path]::GetDirectoryName($WindowsPath)
    $rel    = $dir.Substring($volume.Length).Trim('\')                           # "Users\X"
    $parts  = @($rel -split '\\' | Where-Object { $_ -ne '' })
    $tDir   = '/:'
    foreach ($p in $parts) { $tDir += $p + '/:' }
    $file   = [System.IO.Path]::GetFileName($WindowsPath)
    return [pscustomobject]@{ Volume = $volume; Dir = $tDir; File = $file; Key = $volume + $tDir + $file }
}

function ConvertFrom-TraktorLocation($LocationNode) {
    return $LocationNode.GetAttribute('VOLUME') + ($LocationNode.GetAttribute('DIR') -replace '/:', '\') + $LocationNode.GetAttribute('FILE')
}

# Minimal FLAC reader: STREAMINFO (duration/bitrate) + VORBIS_COMMENT (tags).
function Read-FlacInfo([string]$Path) {
    $result = @{ Title = $null; Artist = $null; Album = $null; Track = $null; Date = $null; Genre = $null; Seconds = 0.0 }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $br = New-Object System.IO.BinaryReader($fs)
        if ([System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -ne 'fLaC') { return $result }
        $last = $false
        while (-not $last -and $fs.Position -lt $fs.Length) {
            $hdr   = $br.ReadByte()
            $last  = ($hdr -band 0x80) -ne 0
            $type  = $hdr -band 0x7F
            $lenB  = $br.ReadBytes(3)
            $len   = ([int]$lenB[0] -shl 16) -bor ([int]$lenB[1] -shl 8) -bor [int]$lenB[2]
            if ($type -eq 0 -and $len -ge 18) {                                   # STREAMINFO
                $b = $br.ReadBytes($len)
                $sampleRate   = ([int]$b[10] -shl 12) -bor ([int]$b[11] -shl 4) -bor ([int]$b[12] -shr 4)
                $totalSamples = ([long]($b[13] -band 0x0F) -shl 32) -bor ([long]$b[14] -shl 24) -bor ([long]$b[15] -shl 16) -bor ([long]$b[16] -shl 8) -bor [long]$b[17]
                if ($sampleRate -gt 0) { $result.Seconds = $totalSamples / $sampleRate }
            }
            elseif ($type -eq 4) {                                                # VORBIS_COMMENT
                $b = $br.ReadBytes($len)
                $pos = 0
                $vendorLen = [BitConverter]::ToUInt32($b, $pos); $pos += 4 + $vendorLen
                $count = [BitConverter]::ToUInt32($b, $pos); $pos += 4
                for ($i = 0; $i -lt $count -and $pos + 4 -le $b.Length; $i++) {
                    $cl = [BitConverter]::ToUInt32($b, $pos); $pos += 4
                    if ($pos + $cl -gt $b.Length) { break }
                    $kv = [System.Text.Encoding]::UTF8.GetString($b, $pos, $cl); $pos += $cl
                    $eq = $kv.IndexOf('=')
                    if ($eq -lt 1) { continue }
                    $k = $kv.Substring(0, $eq).ToUpperInvariant(); $v = $kv.Substring($eq + 1)
                    switch ($k) {
                        'TITLE'       { if (-not $result.Title)  { $result.Title  = $v } }
                        'ARTIST'      { if (-not $result.Artist) { $result.Artist = $v } }
                        'ALBUM'       { if (-not $result.Album)  { $result.Album  = $v } }
                        'TRACKNUMBER' { if (-not $result.Track)  { $result.Track  = ($v -split '/')[0] } }
                        'DATE'        { if (-not $result.Date)   { $result.Date   = $v } }
                        'GENRE'       { if (-not $result.Genre)  { $result.Genre  = $v } }
                    }
                }
            }
            else { $fs.Seek($len, 'Current') | Out-Null }
        }
    } catch { }
    finally { if ($fs) { $fs.Dispose() } }
    return $result
}

# Tags for any audio file: FLAC tags when available, else guess from "Artist\YYYY - Album\N. Title.ext".
function Get-TrackMetadata([System.IO.FileInfo]$File) {
    $meta = @{ Title = $null; Artist = $null; Album = $null; Track = $null; Date = $null; Genre = $null; Seconds = 0.0 }
    if ($File.Extension -ieq '.flac') { $meta = Read-FlacInfo $File.FullName }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $m = [regex]::Match($base, '^(\d+)\.\s*(.+)$')
    if (-not $meta.Title) { if ($m.Success) { $meta.Title = $m.Groups[2].Value } else { $meta.Title = $base } }
    if (-not $meta.Track -and $m.Success) { $meta.Track = $m.Groups[1].Value }
    $albumDir = $File.Directory
    $am = [regex]::Match($albumDir.Name, '^(\d{4})\s*-\s*(.+)$')
    if (-not $meta.Album) { if ($am.Success) { $meta.Album = $am.Groups[2].Value } else { $meta.Album = $albumDir.Name } }
    if (-not $meta.Date -and $am.Success) { $meta.Date = $am.Groups[1].Value }
    if (-not $meta.Artist -and $albumDir.Parent) { $meta.Artist = $albumDir.Parent.Name }
    return $meta
}

function Read-M3U([string]$Path) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $line = $raw.Trim().TrimStart([char]0xFEFF)
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^[a-z]+://') { continue }                               # URLs: not supported
        if (-not [System.IO.Path]::IsPathRooted($line)) { $line = Join-Path $dir $line }
        $out.Add([System.IO.Path]::GetFullPath($line))
    }
    return $out
}

function Get-Sha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Dispose(); $sha.Dispose() }
}

function New-TraktorUuid { return ([guid]::NewGuid().ToString('N')) }

function Get-TraktorDate([datetime]$d) { return ('{0}/{1}/{2}' -f $d.Year, $d.Month, $d.Day) }

# --------------------------------------------------------------------------- 0a. config file
# Any parameter of this script may be set in the .conf file; a parameter given on the command line wins.
$confPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Sync-TraktorLibrary.conf'
if (-not (Test-Path -LiteralPath $confPath)) {
    $template = @'
# Sync-TraktorLibrary.conf  -  settings for Sync-TraktorLibrary.ps1 (this file is git-ignored)
#
# TO DO: edit the values at the bottom so they match your machine, then run the script again.
#
# Format: one "Name = value" per line. Lines starting with # are comments.
# No quotes needed; write backslashes as they are. %USERPROFILE% and other %VARIABLES% are expanded.
# Any parameter of the script can be set here (see: Get-Help .\Sync-TraktorLibrary.ps1 -Full).
# A parameter given on the command line overrides this file. An empty value counts as not set.
#
#   LibraryRoot     Folder holding your "Tracks" and "M3U" subfolders.
#   TraktorBase     Folder holding the Traktor version folders (e.g. "Traktor 4.5.1"), each with a
#                   collection.nml. A default Traktor install uses %USERPROFILE%\Documents\Native Instruments
#   TraktorRoot     Optional. The one version folder to use. Needed only when TraktorBase holds more than
#                   one Traktor folder with a collection.nml (the script then stops and lists them).
#   PlaylistFolder  Name of the Traktor playlist folder that gets one playlist per M3U file.
#                   Created if it does not exist.
#   WorkDir         Optional. Empty = a temporary folder that is cleaned up automatically.
#
# Switches (ReportOnly, Apply, RemoveMissingTracks, RemoveOrphanPlaylists, InstallToTraktor, Force)
# take true or false and are off unless you set them. Be careful with Apply, InstallToTraktor and
# Force: set here they apply to every run, so leave them for the command line unless you mean it.

LibraryRoot    = %USERPROFILE%\Music\Library
TraktorBase    = %USERPROFILE%\Documents\Native Instruments
TraktorRoot    =
PlaylistFolder = Synced
WorkDir        =

# ReportOnly            = false
# RemoveMissingTracks   = false
# RemoveOrphanPlaylists = false
'@
    [System.IO.File]::WriteAllText($confPath, ($template -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Created $confPath" -ForegroundColor Yellow
    Write-Host 'Edit it as described in its comments, then run the script again.' -ForegroundColor Yellow
    exit 1
}
$scriptParams = (Get-Command $PSCommandPath).Parameters
$commonParams = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
foreach ($line in Get-Content -LiteralPath $confPath -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $eq = $t.IndexOf('=')
    if ($eq -lt 1) { throw "${confPath}: cannot read this line (expected Name = value): $line" }
    $name = $t.Substring(0, $eq).Trim()
    $text = [Environment]::ExpandEnvironmentVariables($t.Substring($eq + 1).Trim())
    if (-not $scriptParams.ContainsKey($name) -or $commonParams -contains $name) { throw "${confPath}: '$name' is not a parameter of this script" }
    if ($PSBoundParameters.ContainsKey($name) -or $text -eq '') { continue }          # command line wins; empty = not set
    if ($scriptParams[$name].ParameterType -eq [switch]) {
        if     ($text -match '^(true|yes|on|1)$')   { $text = $true }
        elseif ($text -match '^(false|no|off|0)$')  { $text = $false }
        else { throw "${confPath}: '$name' must be true or false, not '$text'" }
    }
    Set-Variable -Name $name -Value $text
}
if (-not $LibraryRoot)    { throw "LibraryRoot is not set (in $confPath or on the command line)" }
if (-not $PlaylistFolder) { throw "PlaylistFolder is not set (in $confPath or on the command line)" }
if (-not $TraktorRoot -and -not $TraktorBase) { throw "Set TraktorBase or TraktorRoot (in $confPath or on the command line)" }

# --------------------------------------------------------------------------- 0. sanity
$tracksDir = Join-Path $LibraryRoot 'Tracks'
$m3uDir    = Join-Path $LibraryRoot 'M3U'
if (-not $TraktorRoot) {
    $traktorBase = $TraktorBase
    $candidates = @(Get-ChildItem -LiteralPath $traktorBase -Directory -Filter 'Traktor*' |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'collection.nml') } |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'collection.nml')).LastWriteTime } -Descending)
    if ($candidates.Count -eq 0) { throw "No Traktor* folder with a collection.nml in $traktorBase" }
    if ($candidates.Count -eq 1) { $TraktorRoot = $candidates[0].FullName }
    else {
        $list = ($candidates | ForEach-Object {
            '  {0}   (collection.nml saved {1:yyyy-MM-dd HH:mm})' -f $_.FullName, (Get-Item -LiteralPath (Join-Path $_.FullName 'collection.nml')).LastWriteTime
        }) -join "`n"
        throw "Several Traktor folders with a collection.nml were found in $traktorBase :`n$list`nSince there are several, TraktorRoot is required: set it in $confPath or re-run with -TraktorRoot '<one of the folders above>'."
    }
}
$nmlPath   = Join-Path $TraktorRoot 'collection.nml'
foreach ($p in @($tracksDir, $m3uDir, $nmlPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}
$autoWork = -not $WorkDir
if ($autoWork) {
    $tempRoot = [System.IO.Path]::GetTempPath()
    Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'TraktorSync-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $WorkDir = Join-Path $tempRoot ('TraktorSync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }
$cleanWork = $false          # set to $true at the exits where the work folder holds nothing worth keeping

# Everything below runs inside try so the finally block can remove the work folder on any exit (return included).
try {

$stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$originalCopy = Join-Path $WorkDir "collection.original.$stamp.nml"
$mergedPath   = Join-Path $WorkDir 'collection.merged.nml'
$reportPath   = Join-Path $WorkDir "report.$stamp.txt"

Write-Section "Traktor Library Sync  ($stamp)"
Write-Host "Library   : $LibraryRoot"
Write-Host "Traktor   : $nmlPath"
Write-Host "Work dir  : $WorkDir"

# --------------------------------------------------------------------------- 1. copy the collection (we only ever work on the copy)
Copy-Item -LiteralPath $nmlPath -Destination $originalCopy
Write-Host "Copied collection -> $originalCopy" -ForegroundColor DarkGray

$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $false
$xml.Load($originalCopy)
$collectionNode = $xml.SelectSingleNode('/NML/COLLECTION')
if (-not $collectionNode) { throw 'Not a Traktor collection: missing /NML/COLLECTION' }

# Index of collection entries by lower-cased windows path
$collection = @{}                       # lcPath -> @{ Path; Node }
$volumeIds  = @{}                       # "C:" -> VOLUMEID
foreach ($entry in $collectionNode.SelectNodes('ENTRY')) {
    $loc = $entry.SelectSingleNode('LOCATION')
    if (-not $loc) { continue }
    $winPath = ConvertFrom-TraktorLocation $loc
    $collection[$winPath.ToLowerInvariant()] = @{ Path = $winPath; Node = $entry }
    $vol = $loc.GetAttribute('VOLUME'); $vid = $loc.GetAttribute('VOLUMEID')
    if ($vol -and $vid -and -not $volumeIds.ContainsKey($vol)) { $volumeIds[$vol] = $vid }
}

# Spelling of the library prefix as Traktor already knows it (Windows is case-insensitive,
# but Traktor keys are strings, so we keep one consistent spelling).
$libRootFull = [System.IO.Path]::GetFullPath($LibraryRoot).TrimEnd('\')
$libPrefixSpelling = $libRootFull
foreach ($c in $collection.Values) {
    if ($c.Path.Length -gt $libRootFull.Length -and $c.Path.Substring(0, $libRootFull.Length).Equals($libRootFull, 'OrdinalIgnoreCase')) {
        $libPrefixSpelling = $c.Path.Substring(0, $libRootFull.Length); break
    }
}
function Get-CanonicalPath([string]$WindowsPath) {
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    $lc = $full.ToLowerInvariant()
    if ($collection.ContainsKey($lc)) { return $collection[$lc].Path }
    if ($full.Length -gt $libRootFull.Length -and $full.Substring(0, $libRootFull.Length).Equals($libRootFull, 'OrdinalIgnoreCase')) {
        return $libPrefixSpelling + $full.Substring($libRootFull.Length)
    }
    return $full
}

# --------------------------------------------------------------------------- 2. tally Library\Tracks
Write-Section 'Library tally'
$allFiles  = @(Get-ChildItem -LiteralPath $tracksDir -Recurse -File)
$diskFiles = @($allFiles | Where-Object { $AudioExtensions -contains $_.Extension.ToLowerInvariant() })
$nonAudio  = @($allFiles | Where-Object { $AudioExtensions -notcontains $_.Extension.ToLowerInvariant() })
$disk = @{}                                            # lcPath -> FileInfo
foreach ($f in $diskFiles) { $disk[$f.FullName.ToLowerInvariant()] = $f }

$artists = @{}; $albums = @{}
foreach ($f in $diskFiles) {
    $artist = $f.Directory.Parent.Name; $album = $f.Directory.Name
    if (-not $artists.ContainsKey($artist)) { $artists[$artist] = 0 }
    $artists[$artist]++
    $albums["$artist|$album"] = 1
}
$totalBytes = [long]0
foreach ($f in $diskFiles) { $totalBytes += $f.Length }

$tally = New-Object System.Collections.Generic.List[string]
$tally.Add(('Audio files : {0}' -f $diskFiles.Count))
$tally.Add(('Artists     : {0}' -f $artists.Count))
$tally.Add(('Albums      : {0}' -f $albums.Count))
$tally.Add(('Total size  : {0}' -f (Format-Size $totalBytes)))
$tally.Add(('Other files : {0}  (artwork etc., ignored)' -f $nonAudio.Count))
$tally.Add('By format   :')
foreach ($g in ($diskFiles | Group-Object { $_.Extension.ToLowerInvariant() } | Sort-Object Count -Descending)) {
    $bytes = [long]0; foreach ($f in $g.Group) { $bytes += $f.Length }
    $tally.Add(('    {0,-6} {1,5}   {2}' -f $g.Name, $g.Count, (Format-Size $bytes)))
}
$tally.Add('Top artists :')
foreach ($a in ($artists.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
    $tally.Add(('    {0,3}  {1}' -f $a.Value, $a.Key))
}
$tally | ForEach-Object { Write-Host $_ }

# --------------------------------------------------------------------------- 3. diff tracks
Write-Section 'Track diff  (disk vs collection)'
$newTracks = @($diskFiles | Where-Object { -not $collection.ContainsKey($_.FullName.ToLowerInvariant()) } | Sort-Object FullName)
$libPrefixLc = $libRootFull.ToLowerInvariant() + '\'
$missingTracks = @($collection.Values | Where-Object { $_.Path.ToLowerInvariant().StartsWith($libPrefixLc) -and -not (Test-Path -LiteralPath $_.Path) } | Sort-Object { $_.Path })
$outsideLibrary = @($collection.Values | Where-Object { -not $_.Path.ToLowerInvariant().StartsWith($libPrefixLc) })

$newColor = 'Gray'; if ($newTracks.Count) { $newColor = 'Green' }
$missColor = 'Gray'; $missNote = ''
if ($missingTracks.Count) { $missColor = 'Yellow'; if ($RemoveMissingTracks) { $missNote = '(will be removed)' } else { $missNote = '(kept; use -RemoveMissingTracks to drop)' } }
Write-Host ('Collection entries           : {0}' -f $collection.Count)
Write-Host ('  of which outside Library   : {0}  (left untouched)' -f $outsideLibrary.Count)
Write-Host ('NEW on disk, not in Traktor  : {0}' -f $newTracks.Count) -ForegroundColor $newColor
foreach ($t in $newTracks) { Write-Host ('  + ' + $t.FullName.Substring($libRootFull.Length + 1)) -ForegroundColor Green }
Write-Host ('In Traktor, MISSING on disk  : {0}  {1}' -f $missingTracks.Count, $missNote) -ForegroundColor $missColor
foreach ($t in $missingTracks) { Write-Host ('  - ' + $t.Path.Substring($libRootFull.Length + 1)) -ForegroundColor Yellow }

# --------------------------------------------------------------------------- 4. diff playlists
Write-Section "Playlist diff  (M3U vs Traktor folder '$PlaylistFolder')"
$rootNode = $xml.SelectSingleNode('/NML/PLAYLISTS/NODE[@TYPE="FOLDER" and @NAME="$ROOT"]')
if (-not $rootNode) { throw 'Collection has no $ROOT playlist folder' }
$rootSub = $rootNode.SelectSingleNode('SUBNODES')
$folderNode = $null
foreach ($n in $rootSub.SelectNodes('NODE[@TYPE="FOLDER"]')) {
    if ($n.GetAttribute('NAME') -ieq $PlaylistFolder) { $folderNode = $n; break }
}
$folderCreated = $false
if (-not $folderNode) {
    $folderCreated = $true
    Write-Host "Folder '$PlaylistFolder' does not exist in Traktor; it will be created." -ForegroundColor Green
}

# Existing Traktor playlists in that folder: name -> @{ Node; Keys[] }
$traktorPlaylists = [ordered]@{}
if ($folderNode) {
    foreach ($pl in $folderNode.SelectNodes('SUBNODES/NODE[@TYPE="PLAYLIST"]')) {
        $keys = @($pl.SelectNodes('PLAYLIST/ENTRY/PRIMARYKEY[@TYPE="TRACK"]') | ForEach-Object { $_.GetAttribute('KEY') })
        $traktorPlaylists[$pl.GetAttribute('NAME')] = @{ Node = $pl; Keys = $keys }
    }
}

# M3U playlists: name -> list of canonical windows paths (+ warnings)
$m3uFiles = @(Get-ChildItem -LiteralPath $m3uDir -File | Where-Object { $_.Extension -match '^\.m3u8?$' } | Sort-Object Name)
$m3uPlaylists = [ordered]@{}
$playlistWarnings = New-Object System.Collections.Generic.List[string]
$playlistOnlyTracks = @{}            # lcPath -> canonical path of tracks referenced by playlists but not in the Tracks scan
foreach ($mf in $m3uFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($mf.Name)
    $paths = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($p in (Read-M3U $mf.FullName)) {
        $lc = $p.ToLowerInvariant()
        if (-not ($disk.ContainsKey($lc) -or $collection.ContainsKey($lc) -or (Test-Path -LiteralPath $p))) {
            $playlistWarnings.Add("[$name] file not found, skipped: $p"); continue
        }
        if ($seen.ContainsKey($lc)) { continue }                                   # Traktor playlists don't hold duplicates
        $seen[$lc] = 1
        $canon = Get-CanonicalPath $p
        $paths.Add($canon)
        if (-not $disk.ContainsKey($lc) -and -not $collection.ContainsKey($lc)) { $playlistOnlyTracks[$lc] = $canon }
    }
    $m3uPlaylists[$name] = $paths
}

$plNew = New-Object System.Collections.Generic.List[string]
$plChanged = [ordered]@{}            # name -> @{ Added; Removed; Reordered; ExistingName }
$plSame = New-Object System.Collections.Generic.List[string]
foreach ($name in $m3uPlaylists.Keys) {
    $wantKeys = @($m3uPlaylists[$name] | ForEach-Object { (ConvertTo-TraktorLocation $_).Key })
    $existingName = $null
    foreach ($k in $traktorPlaylists.Keys) { if ($k -ieq $name) { $existingName = $k; break } }
    if (-not $existingName) { $plNew.Add($name); continue }
    $haveKeys = @($traktorPlaylists[$existingName].Keys)
    $haveSet = @{}; foreach ($k in $haveKeys) { $haveSet[$k.ToLowerInvariant()] = 1 }
    $wantSet = @{}; foreach ($k in $wantKeys) { $wantSet[$k.ToLowerInvariant()] = 1 }
    $added   = @($wantKeys | Where-Object { -not $haveSet.ContainsKey($_.ToLowerInvariant()) })
    $removed = @($haveKeys | Where-Object { -not $wantSet.ContainsKey($_.ToLowerInvariant()) })
    # reordered = the tracks present on both sides no longer come in the same order
    $commonWant = @($wantKeys | Where-Object { $haveSet.ContainsKey($_.ToLowerInvariant()) } | ForEach-Object { $_.ToLowerInvariant() })
    $commonHave = @($haveKeys | Where-Object { $wantSet.ContainsKey($_.ToLowerInvariant()) } | ForEach-Object { $_.ToLowerInvariant() })
    $reordered = $false
    for ($i = 0; $i -lt $commonWant.Count; $i++) { if ($commonWant[$i] -ne $commonHave[$i]) { $reordered = $true; break } }
    if ($added.Count -or $removed.Count -or $reordered) {
        $plChanged[$name] = @{ Added = $added; Removed = $removed; Reordered = $reordered; ExistingName = $existingName }
    } else { $plSame.Add($name) }
}
$plOrphan = New-Object System.Collections.Generic.List[string]
foreach ($tn in $traktorPlaylists.Keys) {
    $found = $false
    foreach ($mn in $m3uPlaylists.Keys) { if ($mn -ieq $tn) { $found = $true; break } }
    if (-not $found) { $plOrphan.Add($tn) }
}

function Show-Key([string]$Key) {
    $p = $Key -replace '/:', '\'
    $prefix = $libPrefixSpelling + '\Tracks\'
    if ($p.StartsWith($prefix, 'OrdinalIgnoreCase')) { $p = $p.Substring($prefix.Length) }
    return $p
}

$sameNote = ''; if ($plSame.Count) { $sameNote = '(' + ($plSame -join ', ') + ')' }
$plNewColor = 'Gray'; if ($plNew.Count) { $plNewColor = 'Green' }
$plChgColor = 'Gray'; if ($plChanged.Count) { $plChgColor = 'Green' }
$orphColor = 'Gray'; $orphNote = ''
if ($plOrphan.Count) { $orphColor = 'Yellow'; if ($RemoveOrphanPlaylists) { $orphNote = '(will be removed)' } else { $orphNote = '(no M3U; kept, use -RemoveOrphanPlaylists to drop)' } }

Write-Host ('M3U playlists found          : {0}' -f $m3uPlaylists.Count)
Write-Host ('Unchanged                    : {0}  {1}' -f $plSame.Count, $sameNote) -ForegroundColor Gray
Write-Host ('NEW playlists                : {0}' -f $plNew.Count) -ForegroundColor $plNewColor
foreach ($n in $plNew) { Write-Host ('  + {0}  ({1} tracks)' -f $n, $m3uPlaylists[$n].Count) -ForegroundColor Green }
Write-Host ('CHANGED playlists            : {0}' -f $plChanged.Count) -ForegroundColor $plChgColor
foreach ($n in $plChanged.Keys) {
    $c = $plChanged[$n]
    $desc = @()
    if ($c.Added.Count)   { $desc += "+$($c.Added.Count)" }
    if ($c.Removed.Count) { $desc += "-$($c.Removed.Count)" }
    if ($c.Reordered)     { $desc += 'reordered' }
    Write-Host ('  ~ {0}  [{1}]  -> {2} tracks' -f $n, ($desc -join ' '), $m3uPlaylists[$n].Count) -ForegroundColor Green
    foreach ($k in $c.Added)   { Write-Host ('      + ' + (Show-Key $k)) -ForegroundColor Green }
    foreach ($k in $c.Removed) { Write-Host ('      - ' + (Show-Key $k)) -ForegroundColor Yellow }
}
Write-Host ('ORPHAN Traktor playlists     : {0}  {1}' -f $plOrphan.Count, $orphNote) -ForegroundColor $orphColor
foreach ($n in $plOrphan) { Write-Host ('  ? {0}  ({1} tracks)' -f $n, $traktorPlaylists[$n].Keys.Count) -ForegroundColor Yellow }
if ($playlistOnlyTracks.Count) {
    Write-Host ('Playlist tracks outside Library\Tracks not yet in Traktor: {0} (will be added)' -f $playlistOnlyTracks.Count) -ForegroundColor Green
    foreach ($p in $playlistOnlyTracks.Values) { Write-Host "  + $p" -ForegroundColor Green }
}
foreach ($w in $playlistWarnings) { Write-Host "  ! $w" -ForegroundColor Yellow }

# --------------------------------------------------------------------------- write the text report
$report = New-Object System.Collections.Generic.List[string]
$report.Add("Traktor Library Sync report  $stamp")
$report.Add("Library: $LibraryRoot"); $report.Add("Collection: $nmlPath"); $report.Add('')
$report.Add('--- Tally ---'); foreach ($l in $tally) { $report.Add($l) }; $report.Add('')
$report.Add("--- New tracks ($($newTracks.Count)) ---"); foreach ($t in $newTracks) { $report.Add('+ ' + $t.FullName) }
$report.Add(''); $report.Add("--- Collection tracks missing on disk ($($missingTracks.Count)) ---"); foreach ($t in $missingTracks) { $report.Add('- ' + $t.Path) }
$report.Add(''); $report.Add("--- New playlists ($($plNew.Count)) ---"); foreach ($n in $plNew) { $report.Add("+ $n ($($m3uPlaylists[$n].Count))") }
$report.Add(''); $report.Add("--- Changed playlists ($($plChanged.Count)) ---")
foreach ($n in $plChanged.Keys) {
    $c = $plChanged[$n]; $report.Add("~ $n")
    foreach ($k in $c.Added)   { $report.Add('    + ' + ($k -replace '/:', '\')) }
    foreach ($k in $c.Removed) { $report.Add('    - ' + ($k -replace '/:', '\')) }
    if ($c.Reordered) { $report.Add('    (reordered)') }
}
$report.Add(''); $report.Add("--- Orphan Traktor playlists ($($plOrphan.Count)) ---"); foreach ($n in $plOrphan) { $report.Add("? $n") }
$report.Add(''); $report.Add('--- Warnings ---'); foreach ($w in $playlistWarnings) { $report.Add($w) }
[System.IO.File]::WriteAllLines($reportPath, $report, (New-Object System.Text.UTF8Encoding($false)))

# --------------------------------------------------------------------------- 5. decide
$changeCount = $newTracks.Count + $playlistOnlyTracks.Count + $plNew.Count + $plChanged.Count
if ($RemoveMissingTracks)   { $changeCount += $missingTracks.Count }
if ($RemoveOrphanPlaylists) { $changeCount += $plOrphan.Count }
if ($folderCreated)         { $changeCount += 1 }
Write-Section 'Merge'
if ($changeCount -eq 0) {
    Write-Host 'Traktor collection is already in sync with the Library. Nothing to merge.' -ForegroundColor Green
    $cleanWork = $true
    return
}
if ($ReportOnly) { Write-Host "$changeCount change(s) pending. Re-run without -ReportOnly to merge."; Write-Host "Full-path report -> $reportPath" -ForegroundColor DarkGray; return }
if (-not $Apply) {
    $answer = Read-Host "Write merged collection with $changeCount change(s) to`n  $mergedPath`n[Y/n]"
    if ($answer -and $answer.Trim().ToLowerInvariant() -notin @('y', 'yes')) { Write-Host 'Aborted; nothing written.'; $cleanWork = $true; return }
}

# --------------------------------------------------------------------------- 6. merge (in memory, on the copy)
$now = Get-Date
$today = Get-TraktorDate $now
$secondsToday = [int][math]::Floor($now.TimeOfDay.TotalSeconds)

function Add-CollectionEntry([string]$CanonicalPath) {
    $fi = Get-Item -LiteralPath $CanonicalPath
    $meta = Get-TrackMetadata $fi
    $loc = ConvertTo-TraktorLocation $CanonicalPath

    $entry = $xml.CreateElement('ENTRY')
    $entry.SetAttribute('MODIFIED_DATE', $today)
    $entry.SetAttribute('MODIFIED_TIME', [string]$secondsToday)
    $entry.SetAttribute('TITLE', [string]$meta.Title)
    $entry.SetAttribute('ARTIST', [string]$meta.Artist)

    $l = $xml.CreateElement('LOCATION')
    $l.SetAttribute('DIR', $loc.Dir); $l.SetAttribute('FILE', $loc.File); $l.SetAttribute('VOLUME', $loc.Volume)
    if ($volumeIds.ContainsKey($loc.Volume)) { $l.SetAttribute('VOLUMEID', $volumeIds[$loc.Volume]) }
    $entry.AppendChild($l) | Out-Null

    $a = $xml.CreateElement('ALBUM')
    if ($meta.Track) { $a.SetAttribute('TRACK', [string]$meta.Track) }
    $a.SetAttribute('TITLE', [string]$meta.Album)
    $entry.AppendChild($a) | Out-Null

    $mi = $xml.CreateElement('MODIFICATION_INFO'); $mi.SetAttribute('AUTHOR_TYPE', 'importer'); $entry.AppendChild($mi) | Out-Null

    $info = $xml.CreateElement('INFO')
    if ($meta.Seconds -gt 0) {
        $info.SetAttribute('BITRATE', [string][int][math]::Round($fi.Length * 8 / $meta.Seconds))
        $info.SetAttribute('PLAYTIME', [string][int][math]::Round($meta.Seconds))
        $info.SetAttribute('PLAYTIME_FLOAT', ([double]$meta.Seconds).ToString('F6', [cultureinfo]::InvariantCulture))
    }
    if ($meta.Genre) { $info.SetAttribute('GENRE', [string]$meta.Genre) }
    $info.SetAttribute('IMPORT_DATE', $today)
    if ($meta.Date -and $meta.Date -match '^(\d{4})') { $info.SetAttribute('RELEASE_DATE', "$($Matches[1])/1/1") }
    $info.SetAttribute('FLAGS', '28')
    $info.SetAttribute('FILESIZE', [string][int][math]::Round($fi.Length / 1KB))
    $entry.AppendChild($info) | Out-Null

    $collectionNode.AppendChild($entry) | Out-Null
    $script:collection[$CanonicalPath.ToLowerInvariant()] = @{ Path = $CanonicalPath; Node = $entry }
}

$addedCount = 0
foreach ($t in $newTracks) { Add-CollectionEntry (Get-CanonicalPath $t.FullName); $addedCount++ }
foreach ($p in $playlistOnlyTracks.Values) { if (-not $collection.ContainsKey($p.ToLowerInvariant())) { Add-CollectionEntry $p; $addedCount++ } }
Write-Host ('Added {0} collection entries' -f $addedCount) -ForegroundColor Green

if ($RemoveMissingTracks) {
    $removedCount = 0
    foreach ($t in $missingTracks) { $collectionNode.RemoveChild($t.Node) | Out-Null; $collection.Remove($t.Path.ToLowerInvariant()); $removedCount++ }
    Write-Host ('Removed {0} entries whose files are gone' -f $removedCount) -ForegroundColor Yellow
}
$collectionNode.SetAttribute('ENTRIES', [string]$collectionNode.SelectNodes('ENTRY').Count)

if (-not $folderNode) {
    $folderNode = $xml.CreateElement('NODE'); $folderNode.SetAttribute('TYPE', 'FOLDER'); $folderNode.SetAttribute('NAME', $PlaylistFolder)
    $folderNode.AppendChild($xml.CreateElement('SUBNODES')) | Out-Null
    $rootSub.PrependChild($folderNode) | Out-Null         # user folders sit above the built-in lists
}
$folderSub = $folderNode.SelectSingleNode('SUBNODES')
if (-not $folderSub) { $folderSub = $folderNode.AppendChild($xml.CreateElement('SUBNODES')) }

function Set-PlaylistEntries($PlaylistNode, [string[]]$Paths) {
    $pl = $PlaylistNode.SelectSingleNode('PLAYLIST')
    foreach ($old in @($pl.SelectNodes('ENTRY'))) { $pl.RemoveChild($old) | Out-Null }
    foreach ($p in $Paths) {
        $e = $xml.CreateElement('ENTRY')
        $pk = $xml.CreateElement('PRIMARYKEY'); $pk.SetAttribute('TYPE', 'TRACK'); $pk.SetAttribute('KEY', (ConvertTo-TraktorLocation $p).Key)
        $e.AppendChild($pk) | Out-Null; $pl.AppendChild($e) | Out-Null
    }
    $pl.SetAttribute('ENTRIES', [string]$Paths.Count)
}

foreach ($name in $plNew) {
    $node = $xml.CreateElement('NODE'); $node.SetAttribute('TYPE', 'PLAYLIST'); $node.SetAttribute('NAME', $name)
    $pl = $xml.CreateElement('PLAYLIST'); $pl.SetAttribute('ENTRIES', '0'); $pl.SetAttribute('TYPE', 'LIST'); $pl.SetAttribute('UUID', (New-TraktorUuid))
    $node.AppendChild($pl) | Out-Null
    $folderSub.AppendChild($node) | Out-Null
    Set-PlaylistEntries $node @($m3uPlaylists[$name])
    Write-Host ("Created playlist '{0}' with {1} tracks" -f $name, $m3uPlaylists[$name].Count) -ForegroundColor Green
}
foreach ($name in $plChanged.Keys) {
    $node = $traktorPlaylists[$plChanged[$name].ExistingName].Node
    Set-PlaylistEntries $node @($m3uPlaylists[$name])
    Write-Host ("Updated playlist '{0}' -> {1} tracks" -f $name, $m3uPlaylists[$name].Count) -ForegroundColor Green
}
if ($RemoveOrphanPlaylists) {
    foreach ($name in $plOrphan) { $folderSub.RemoveChild($traktorPlaylists[$name].Node) | Out-Null; Write-Host "Removed playlist '$name'" -ForegroundColor Yellow }
}
# keep the SUBNODES COUNT attributes honest
foreach ($sub in $xml.SelectNodes('//SUBNODES')) { $sub.SetAttribute('COUNT', [string]$sub.SelectNodes('NODE').Count) }

# --------------------------------------------------------------------------- 7. save in Traktor's own style
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $false
$settings.OmitXmlDeclaration = $true
$sb = New-Object System.Text.StringBuilder
$writer = [System.Xml.XmlWriter]::Create($sb, $settings)
$xml.DocumentElement.WriteTo($writer); $writer.Flush(); $writer.Dispose()
$body = $sb.ToString()
$body = [regex]::Replace($body, '<([A-Z_0-9]+)((?:\s+[A-Z_0-9]+="[^"]*")*)\s*/>', '<$1$2></$1>')   # Traktor never writes <X/>
$body = [regex]::Replace($body, '(</[A-Z_0-9]+>)', "`$1`n").TrimEnd("`n")                                  # Traktor: newline after every end tag only
$text = '<?xml version="1.0" encoding="UTF-8" standalone="no" ?>' + "`n" + $body + "`n"
[System.IO.File]::WriteAllText($mergedPath, $text, (New-Object System.Text.UTF8Encoding($false)))

# verify it still parses and the numbers add up
$check = New-Object System.Xml.XmlDocument; $check.Load($mergedPath)
$checkEntries = $check.SelectNodes('/NML/COLLECTION/ENTRY').Count
$checkPlaylists = $check.SelectNodes("/NML/PLAYLISTS//NODE[@TYPE='FOLDER' and @NAME='$PlaylistFolder']/SUBNODES/NODE[@TYPE='PLAYLIST']").Count
Write-Host ''
Write-Host ("Merged collection written -> {0}  ({1} entries, {2} playlists in '{3}')" -f $mergedPath, $checkEntries, $checkPlaylists, $PlaylistFolder) -ForegroundColor Green

# --------------------------------------------------------------------------- 8. optional install
if (-not $InstallToTraktor) {
    Write-Host ''
    Write-Host 'To use it in Traktor, close Traktor and re-run with -Apply -InstallToTraktor.' -ForegroundColor Cyan
    Write-Host '(That backs up the live collection first, the way Traktor does. A manual copy would skip the backup.)'
    return
}
if (Get-Process -Name 'Traktor*' -ErrorAction SilentlyContinue) {
    Write-Host 'Traktor is running. Close it first; it would overwrite the collection on exit.' -ForegroundColor Red; return
}
# Traktor's own backup regime: <TraktorRoot>\Backup\Collection\collection_2026y11m15d_13h50m24s.nml
$backupDir  = Join-Path $TraktorRoot 'Backup\Collection'
$backupName = 'collection_' + (Get-Date -Format "yyyy'y'MM'm'dd'd'HH'h'mm'm'ss's'") + '.nml'
$backupPath = Join-Path $backupDir $backupName

if (-not $Force) {
    $answer = Read-Host "Overwrite the live collection`n  $nmlPath`nFirst backing it up to`n  $backupPath`n[y/N]"
    if (-not $answer -or $answer.Trim().ToLowerInvariant() -notin @('y', 'yes')) { Write-Host 'Install skipped.'; return }
}

# The merge was computed from the copy taken at the start of this run. If Traktor saved since, it is stale.
if ((Get-Sha256 $nmlPath) -ne (Get-Sha256 $originalCopy)) {
    Write-Host 'The live collection.nml changed since this run started. Nothing installed; run the script again.' -ForegroundColor Red; return
}
# Back up first. Any failure or hash mismatch aborts before the live file is touched.
try {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    if (Test-Path -LiteralPath $backupPath) { throw "Backup already exists: $backupPath" }
    Copy-Item -LiteralPath $nmlPath -Destination $backupPath
    if ((Get-Sha256 $backupPath) -ne (Get-Sha256 $nmlPath)) { throw "Backup verification failed: $backupPath" }
} catch {
    Write-Host "Backup failed, live collection NOT touched: $($_.Exception.Message)" -ForegroundColor Red; return
}
Write-Host "Backed up -> $backupPath" -ForegroundColor Green

Copy-Item -LiteralPath $mergedPath -Destination $nmlPath
Write-Host "Installed -> $nmlPath" -ForegroundColor Green
Write-Host "To roll back: Copy-Item -LiteralPath '$backupPath' -Destination '$nmlPath'  (Traktor closed)" -ForegroundColor DarkGray
$cleanWork = $true
} finally {
    if ($autoWork) {
        if ($cleanWork) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        else { Write-Host "Work folder kept -> $WorkDir" -ForegroundColor DarkGray }
    }
}
