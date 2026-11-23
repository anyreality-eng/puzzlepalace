<#
Puzzle Palace online packs processor.

Put pictures in incoming/<Pack Name>/ (pictures directly in incoming/ go to
the "Extras" pack). Each picture gets the next free slot:
  images/NNNN.jpg      the puzzle (fits 2048x2048, VRChat's limit)
  thumbs/page_PPP.jpg  4x2 thumbnail sheet; each pack owns whole sheets
  catalog.json         packs + titles, read by the world

packs.json sets each pack's order and unlock requirement (completed puzzles
needed; 0 = free; "Unlock all" purchasers get everything). Add new packs at
the END of packs.json: the world refers to packs by position.

Slots are append-only (the world has one baked URL per slot), so a slot is
never reused for a different picture. To pull a picture use -Remove <slot>.

Title/author: optional sidecar <name>.json ({"title","author"}), else the file
name: "Sunset Harbor - by Hayzl.jpg" -> "Sunset Harbor", by "Hayzl". A trailing
_YYYYMMDDhhmm timestamp and underscores are cleaned up.

Usage:
  powershell -File tools/process_incoming.ps1
  powershell -File tools/process_incoming.ps1 -Remove 12
  powershell -File tools/process_incoming.ps1 -RebuildThumbs
Works on Windows PowerShell 5.1 and PowerShell 7 on Windows (System.Drawing).
#>
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$Remove = 0,
    [switch]$RebuildThumbs
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$MaxSide = 2048
$MaxSlots = 2048       # must match PuzzleOnlinePacksSetup.MaxSlots in the world
$MaxPages = 512        # must match PuzzleOnlinePacksSetup.MaxThumbPages
$PerPage = 8
$CellW = 384
$CellH = 256
$AtlasCols = 4
$AtlasRows = 2
$JpegQuality = 88L
$ThumbQuality = 82L
$LoosePack = 'Extras'

$incoming = Join-Path $Root 'incoming'
$imagesDir = Join-Path $Root 'images'
$thumbsDir = Join-Path $Root 'thumbs'
$catalogPath = Join-Path $Root 'catalog.json'
$packsConfigPath = Join-Path $Root 'packs.json'
foreach ($d in @($incoming, $imagesDir, $thumbsDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# ---------------------------------------------------------------- state

function New-Pack([string]$name, [int]$unlock) {
    return [pscustomobject]@{ n = $name; u = $unlock; s = (New-Object System.Collections.ArrayList); p = (New-Object System.Collections.ArrayList) }
}

$items = New-Object System.Collections.ArrayList
$packs = New-Object System.Collections.ArrayList
if (Test-Path $catalogPath) {
    $json = Get-Content -Raw -Encoding UTF8 $catalogPath | ConvertFrom-Json
    foreach ($it in @($json.items)) {
        if ($null -eq $it) { continue }
        [void]$items.Add([pscustomobject]@{ t = [string]$it.t; a = [string]$it.a })
    }
    if ($json.v -ge 2) {
        foreach ($pk in @($json.packs)) {
            if ($null -eq $pk) { continue }
            $np = New-Pack ([string]$pk.n) ([int]$pk.u)
            foreach ($x in @($pk.s)) { if ($null -ne $x) { [void]$np.s.Add([int]$x) } }
            foreach ($x in @($pk.p)) { if ($null -ne $x) { [void]$np.p.Add([int]$x) } }
            [void]$packs.Add($np)
        }
    }
}

function Find-Pack([string]$name) {
    foreach ($pk in $packs) { if ($pk.n -ieq $name) { return $pk } }
    return $null
}

# packs.json: order + unlock requirements. Packs already in the catalog keep
# their position; new ones from packs.json are appended in file order.
$config = @()
if (Test-Path $packsConfigPath) { $parsed = Get-Content -Raw -Encoding UTF8 $packsConfigPath | ConvertFrom-Json; $config = @($parsed | ForEach-Object { $_ }) }
$configChanged = $false
foreach ($c in $config) {
    $existing = Find-Pack ([string]$c.name)
    if ($null -eq $existing) { [void]$packs.Add((New-Pack ([string]$c.name) ([int]$c.unlock))); $configChanged = $true }
    elseif ($existing.u -ne [int]$c.unlock) { $existing.u = [int]$c.unlock; $configChanged = $true }
}

# ---------------------------------------------------------------- json out

function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { $s = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            default {
                if ($code -lt 32 -or $code -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-Catalog {
    $packLines = New-Object System.Collections.ArrayList
    foreach ($pk in $packs) {
        [void]$packLines.Add('{"n":' + (ConvertTo-JsonString $pk.n) + ',"u":' + $pk.u + ',"s":[' + (($pk.s | ForEach-Object { $_ }) -join ',') + '],"p":[' + (($pk.p | ForEach-Object { $_ }) -join ',') + ']}')
    }
    $itemLines = New-Object System.Collections.ArrayList
    foreach ($it in $items) { [void]$itemLines.Add('{"t":' + (ConvertTo-JsonString $it.t) + ',"a":' + (ConvertTo-JsonString $it.a) + '}') }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $text = '{"v":2,"updated":"' + $stamp + '","count":' + $items.Count + ",`n" +
        '"packs":[' + "`n" + ($packLines -join ",`n") + "`n],`n" +
        '"items":[' + "`n" + ($itemLines -join ",`n") + "`n]}`n"
    [System.IO.File]::WriteAllText($catalogPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- images

function Get-JpegCodec { return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1 }

function Save-Jpeg([System.Drawing.Bitmap]$bmp, [string]$path, [long]$quality) {
    $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $quality)
    $tmp = $path + '.tmp'
    $bmp.Save($tmp, (Get-JpegCodec), $params)
    $params.Dispose()
    Move-Item -Force $tmp $path
}

function Open-Oriented([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    $bmp = New-Object System.Drawing.Bitmap($img)
    if ($img.PropertyIdList -contains 0x0112) {
        switch ([int]$img.GetPropertyItem(0x0112).Value[0]) {
            2 { $bmp.RotateFlip('RotateNoneFlipX') }
            3 { $bmp.RotateFlip('Rotate180FlipNone') }
            4 { $bmp.RotateFlip('Rotate180FlipX') }
            5 { $bmp.RotateFlip('Rotate90FlipX') }
            6 { $bmp.RotateFlip('Rotate90FlipNone') }
            7 { $bmp.RotateFlip('Rotate270FlipX') }
            8 { $bmp.RotateFlip('Rotate270FlipNone') }
        }
    }
    $img.Dispose(); $ms.Dispose()
    return $bmp
}

function New-Graphics([System.Drawing.Bitmap]$bmp) {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'
    $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
    return $g
}

function Resize-ToFit([System.Drawing.Bitmap]$src, [int]$max) {
    $scale = [Math]::Min(1.0, [Math]::Min($max / $src.Width, $max / $src.Height))
    $w = [Math]::Max(1, [int][Math]::Round($src.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($src.Height * $scale))
    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $dst
    $g.Clear([System.Drawing.Color]::White)
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    return $dst
}

function Get-SlotName([int]$slot) { return ('{0:D4}.jpg' -f $slot) }

# Sheet $page holds pack slots [first .. first+7].
function Build-ThumbPage([int]$page, $slots, [int]$first) {
    $atlas = New-Object System.Drawing.Bitmap(($CellW * $AtlasCols), ($CellH * $AtlasRows), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $atlas
    $g.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
    for ($cell = 0; $cell -lt $PerPage; $cell++) {
        $k = $first + $cell
        if ($k -ge $slots.Count) { break }
        $file = Join-Path $imagesDir (Get-SlotName $slots[$k])
        if (-not (Test-Path $file)) { continue }
        $src = Open-Oriented $file
        $cellAspect = $CellW / $CellH
        if (($src.Width / $src.Height) -gt $cellAspect) { $cropH = $src.Height; $cropW = [int]($src.Height * $cellAspect) }
        else { $cropW = $src.Width; $cropH = [int]($src.Width / $cellAspect) }
        $sx = [int](($src.Width - $cropW) / 2); $sy = [int](($src.Height - $cropH) / 2)
        $col = $cell % $AtlasCols; $row = [Math]::Floor($cell / $AtlasCols)
        $dest = New-Object System.Drawing.Rectangle(($col * $CellW), ($row * $CellH), $CellW, $CellH)
        $g.DrawImage($src, $dest, (New-Object System.Drawing.Rectangle($sx, $sy, $cropW, $cropH)), [System.Drawing.GraphicsUnit]::Pixel)
        $src.Dispose()
    }
    $g.Dispose()
    Save-Jpeg $atlas (Join-Path $thumbsDir ('page_{0:D3}.jpg' -f $page)) $ThumbQuality
    $atlas.Dispose()
}

function Get-Meta([System.IO.FileInfo]$file) {
    $title = ''; $author = ''
    $sidecar = [System.IO.Path]::ChangeExtension($file.FullName, '.json')
    if (Test-Path $sidecar) {
        $m = Get-Content -Raw -Encoding UTF8 $sidecar | ConvertFrom-Json
        $title = [string]$m.title; $author = [string]$m.author
    }
    if (-not $title) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $parts = $base -split '\s+-\s+by\s+', 2
        $title = $parts[0]
        if ($parts.Count -gt 1 -and -not $author) { $author = $parts[1] }
        $title = $title -replace '\(\d+\)$', ''            # "(1)" duplicate suffixes
        $title = $title -replace '_\d{8,14}$', ''          # generator timestamps
        $title = $title -replace '^\d{1,3}_', ''           # "01_" ordering prefixes
        $title = $title -replace '[_]+', ' ' -replace ([string][char]0x2026), '' -replace '\s+', ' '
        # Prompt-style names: "Make_space_nebula_picture" -> "Space nebula"
        $title = $title -replace '^(and the |and one for the |and one for |and a |and )', ''
        $title = $title -replace '^(Creating |Make a |Make |Making picture of |Requesting picture of |Rendition of |Unique version of |Unique version )', ''
        $title = $title -replace ' (picture creation|picture|image|photos?)$', ''
        $title = $title.Trim()
        if ($title.Length -gt 0) { $title = $title.Substring(0, 1).ToUpper() + $title.Substring(1) }
    }
    if ($title.Length -gt 48) { $title = $title.Substring(0, 48).Trim() }
    if ($author.Length -gt 32) { $author = $author.Substring(0, 32) }
    return @($title, $author, $sidecar)
}

# ---------------------------------------------------------------- run

$dirtyPacks = New-Object System.Collections.Generic.HashSet[string]

if ($Remove -gt 0) {
    if ($Remove -gt $items.Count) { throw "Slot $Remove does not exist." }
    $card = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $card; $g.Clear([System.Drawing.Color]::FromArgb(60, 60, 60)); $g.Dispose()
    Save-Jpeg $card (Join-Path $imagesDir (Get-SlotName $Remove)) 80L
    $card.Dispose()
    $items[$Remove - 1] = [pscustomobject]@{ t = '(removed)'; a = '' }
    foreach ($pk in $packs) { if ($pk.s.Contains($Remove)) { $pk.s.Remove($Remove); [void]$dirtyPacks.Add($pk.n) } }
    Write-Host "Removed slot $Remove"
}

$extensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif')
$work = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -File $incoming | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)) {
    [void]$work.Add(@($LoosePack, $f))
}
foreach ($dir in @(Get-ChildItem -Directory $incoming | Sort-Object Name)) {
    foreach ($f in @(Get-ChildItem -File $dir.FullName | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)) {
        [void]$work.Add(@($dir.Name, $f))
    }
}
# Process in pack order so slot numbers group by pack on a fresh import.
$packOrder = @{}
for ($i = 0; $i -lt $packs.Count; $i++) { $packOrder[$packs[$i].n.ToLowerInvariant()] = $i }
$work = @($work | Sort-Object @{ Expression = { if ($packOrder.ContainsKey($_[0].ToLowerInvariant())) { $packOrder[$_[0].ToLowerInvariant()] } else { 9999 } } }, @{ Expression = { $_[0] } }, @{ Expression = { $_[1].Name } })

foreach ($entry in $work) {
    $packName = $entry[0]; $file = $entry[1]
    if ($items.Count -ge $MaxSlots) { Write-Warning "All $MaxSlots slots used; leaving $($file.Name)."; break }
    try { $src = Open-Oriented $file.FullName }
    catch { Write-Warning "Skipping unreadable image $($file.Name): $_"; continue }
    if ($src.Width -lt 400 -or $src.Height -lt 300) { $src.Dispose(); Write-Warning "Skipping $($file.Name): smaller than 400x300."; continue }

    $pack = Find-Pack $packName
    if ($null -eq $pack) { $pack = New-Pack $packName 0; [void]$packs.Add($pack); Write-Warning "Pack '$packName' is not in packs.json; added as free." }
    $meta = Get-Meta $file
    $slot = $items.Count + 1
    $fitted = Resize-ToFit $src $MaxSide
    $src.Dispose()
    Save-Jpeg $fitted (Join-Path $imagesDir (Get-SlotName $slot)) $JpegQuality
    $size = "$($fitted.Width)x$($fitted.Height)"
    $fitted.Dispose()
    [void]$items.Add([pscustomobject]@{ t = $meta[0]; a = $meta[1] })
    [void]$pack.s.Add($slot)
    [void]$dirtyPacks.Add($pack.n)
    Remove-Item -Force $file.FullName
    if (Test-Path $meta[2]) { Remove-Item -Force $meta[2] }
    Write-Host ("Slot {0} [{1}]: '{2}'{3} ({4})" -f $slot, $pack.n, $meta[0], $(if ($meta[1]) { " by '$($meta[1])'" } else { '' }), $size)
}
# Remove now-empty pack folders.
foreach ($dir in @(Get-ChildItem -Directory $incoming)) {
    if (-not (Get-ChildItem -Force $dir.FullName)) { Remove-Item -Force $dir.FullName }
}

if ($RebuildThumbs) { foreach ($pk in $packs) { [void]$dirtyPacks.Add($pk.n) } }
if ($dirtyPacks.Count -eq 0 -and -not $configChanged) { Write-Host "Nothing to process."; exit 0 }

# Give each pack enough sheets (append-only page numbers), then rebuild.
$nextPage = 0
foreach ($pk in $packs) { foreach ($x in $pk.p) { if ($x -ge $nextPage) { $nextPage = $x + 1 } } }
foreach ($pk in $packs) {
    $need = [Math]::Ceiling($pk.s.Count / $PerPage)
    while ($pk.p.Count -lt $need) {
        if ($nextPage -ge $MaxPages) { throw "Out of thumbnail sheets ($MaxPages)." }
        [void]$pk.p.Add($nextPage); $nextPage++
        [void]$dirtyPacks.Add($pk.n)
    }
}
$rebuilt = 0
foreach ($pk in $packs) {
    if (-not $dirtyPacks.Contains($pk.n)) { continue }
    for ($i = 0; $i -lt [Math]::Ceiling($pk.s.Count / $PerPage); $i++) {
        Build-ThumbPage $pk.p[$i] $pk.s ($i * $PerPage)
        $rebuilt++
    }
}
Write-Catalog
Write-Host ("Catalog: {0} pack(s), {1} picture(s); {2} thumbnail sheet(s) rebuilt." -f $packs.Count, $items.Count, $rebuilt)
