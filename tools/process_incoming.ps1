<#
Puzzle Palace community gallery processor.

Takes every image in incoming/, assigns it the next free slot, and writes:
  images/NNNN.jpg      the puzzle (fits 2048x2048, VRChat's limit)
  thumbs/page_PPP.jpg  4x2 thumbnail atlas, 8 slots per page (1536x512)
  catalog.json         {"v":1,"count":N,"items":[{"t":title,"a":author},...]}

Slots are append-only: the world has one baked URL per slot, so a slot is
never reused for a different picture. To pull a picture, use -Remove.

Title/author come from an optional sidecar incoming/<name>.json
({"title":"...","author":"..."}, written by the upload worker), else from the
file name: "Sunset Harbor - by Hayzl.jpg" -> title "Sunset Harbor", author "Hayzl".

Usage:
  powershell -File tools/process_incoming.ps1              # process incoming/
  powershell -File tools/process_incoming.ps1 -Remove 12   # blank slot 12
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
$MaxSlots = 1024
$PerPage = 8
$CellW = 384
$CellH = 256
$AtlasCols = 4
$AtlasRows = 2
$JpegQuality = 88L
$ThumbQuality = 82L

$incoming = Join-Path $Root 'incoming'
$imagesDir = Join-Path $Root 'images'
$thumbsDir = Join-Path $Root 'thumbs'
$catalogPath = Join-Path $Root 'catalog.json'
foreach ($d in @($incoming, $imagesDir, $thumbsDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

function Read-Catalog {
    $items = New-Object System.Collections.ArrayList
    if (Test-Path $catalogPath) {
        $json = Get-Content -Raw -Encoding UTF8 $catalogPath | ConvertFrom-Json
        foreach ($it in @($json.items)) {
            if ($null -eq $it) { continue }
            [void]$items.Add([pscustomobject]@{ t = [string]$it.t; a = [string]$it.a })
        }
    }
    return ,$items
}

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

function Write-Catalog($items) {
    $lines = New-Object System.Collections.ArrayList
    foreach ($it in $items) { [void]$lines.Add('{"t":' + (ConvertTo-JsonString $it.t) + ',"a":' + (ConvertTo-JsonString $it.a) + '}') }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $text = '{"v":1,"updated":"' + $stamp + '","count":' + $items.Count + ',"items":[' + "`n" + ($lines -join ",`n") + "`n]}`n"
    [System.IO.File]::WriteAllText($catalogPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-JpegCodec {
    return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
}

function Save-Jpeg([System.Drawing.Bitmap]$bmp, [string]$path, [long]$quality) {
    $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $quality)
    $tmp = $path + '.tmp'
    $bmp.Save($tmp, (Get-JpegCodec), $params)
    $params.Dispose()
    Move-Item -Force $tmp $path
}

function Open-Oriented([string]$path) {
    # Load without locking the file, then apply EXIF orientation (phone photos).
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    $bmp = New-Object System.Drawing.Bitmap($img)
    if ($img.PropertyIdList -contains 0x0112) {
        $o = [int]$img.GetPropertyItem(0x0112).Value[0]
        switch ($o) {
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
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.PixelOffsetMode = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    return $g
}

function Resize-ToFit([System.Drawing.Bitmap]$src, [int]$max) {
    $scale = [Math]::Min(1.0, [Math]::Min($max / $src.Width, $max / $src.Height))
    $w = [Math]::Max(1, [int][Math]::Round($src.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($src.Height * $scale))
    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $dst
    $g.Clear([System.Drawing.Color]::White)  # flatten transparency
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    return $dst
}

function Get-SlotName([int]$slot) { return ('{0:D4}.jpg' -f $slot) }

function Build-ThumbPage([int]$page, $items) {
    $atlas = New-Object System.Drawing.Bitmap(($CellW * $AtlasCols), ($CellH * $AtlasRows), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $atlas
    $g.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
    for ($cell = 0; $cell -lt $PerPage; $cell++) {
        $index = $page * $PerPage + $cell
        if ($index -ge $items.Count) { break }
        $file = Join-Path $imagesDir (Get-SlotName ($index + 1))
        if (-not (Test-Path $file)) { continue }
        $src = Open-Oriented $file
        # Cover-crop to the cell aspect.
        $cellAspect = $CellW / $CellH
        $srcAspect = $src.Width / $src.Height
        if ($srcAspect -gt $cellAspect) { $cropH = $src.Height; $cropW = [int]($src.Height * $cellAspect) }
        else { $cropW = $src.Width; $cropH = [int]($src.Width / $cellAspect) }
        $sx = [int](($src.Width - $cropW) / 2); $sy = [int](($src.Height - $cropH) / 2)
        $col = $cell % $AtlasCols; $row = [Math]::Floor($cell / $AtlasCols)
        $dest = New-Object System.Drawing.Rectangle(($col * $CellW), ($row * $CellH), $CellW, $CellH)
        $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $cropW, $cropH)
        $g.DrawImage($src, $dest, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
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
        $title = ($title -replace '[_]+', ' ').Trim()
    }
    if ($title.Length -gt 48) { $title = $title.Substring(0, 48) }
    if ($author.Length -gt 32) { $author = $author.Substring(0, 32) }
    return @($title, $author, $sidecar)
}

$items = Read-Catalog
$dirtyPages = New-Object System.Collections.Generic.HashSet[int]

if ($Remove -gt 0) {
    if ($Remove -gt $items.Count) { throw "Slot $Remove does not exist." }
    # Keep the slot (URLs are baked) but replace the picture with a plain card.
    $card = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = New-Graphics $card; $g.Clear([System.Drawing.Color]::FromArgb(60, 60, 60)); $g.Dispose()
    Save-Jpeg $card (Join-Path $imagesDir (Get-SlotName $Remove)) 80L
    $card.Dispose()
    $items[$Remove - 1] = [pscustomobject]@{ t = '(removed)'; a = '' }
    [void]$dirtyPages.Add([int][Math]::Floor(($Remove - 1) / $PerPage))
    Write-Host "Removed slot $Remove"
}

$extensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif')
$files = @(Get-ChildItem -File $incoming | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object LastWriteTime, Name)
foreach ($file in $files) {
    if ($items.Count -ge $MaxSlots) { Write-Warning "Gallery is full ($MaxSlots slots); leaving $($file.Name) in incoming/."; break }
    try { $src = Open-Oriented $file.FullName }
    catch { Write-Warning "Skipping unreadable image $($file.Name): $_"; continue }
    if ($src.Width -lt 400 -or $src.Height -lt 300) {
        $src.Dispose(); Write-Warning "Skipping $($file.Name): too small for a puzzle (min 400x300)."; continue
    }
    $meta = Get-Meta $file
    $slot = $items.Count + 1
    $fitted = Resize-ToFit $src $MaxSide
    $src.Dispose()
    Save-Jpeg $fitted (Join-Path $imagesDir (Get-SlotName $slot)) $JpegQuality
    $size = "$($fitted.Width)x$($fitted.Height)"
    $fitted.Dispose()
    [void]$items.Add([pscustomobject]@{ t = $meta[0]; a = $meta[1] })
    [void]$dirtyPages.Add([int][Math]::Floor(($slot - 1) / $PerPage))
    Remove-Item -Force $file.FullName
    if (Test-Path $meta[2]) { Remove-Item -Force $meta[2] }
    Write-Host ("Slot {0}: '{1}' by '{2}' ({3})" -f $slot, $meta[0], $meta[1], $size)
}

if ($RebuildThumbs) {
    $pages = [Math]::Ceiling($items.Count / $PerPage)
    for ($p = 0; $p -lt $pages; $p++) { [void]$dirtyPages.Add($p) }
}
foreach ($p in $dirtyPages) { Build-ThumbPage $p $items }
Write-Catalog $items
Write-Host ("Catalog: {0} puzzle(s), {1} thumbnail page(s) rebuilt." -f $items.Count, $dirtyPages.Count)
