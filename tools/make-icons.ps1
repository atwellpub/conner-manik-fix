#Requires -Version 5.1
<#
    Regenerates the two icons in assets\ from scratch.

    icon-on.ico   green keycap with a tick   (exe icon, and tray icon while the fix is ON)
    icon-off.ico  gray keycap with a bar     (tray icon while the fix is OFF)

    The icons are committed, so the normal build never needs this script. Run it
    only to change how the icons look:

        powershell -ExecutionPolicy Bypass -File tools\make-icons.ps1

    Add -PreviewPng to also write a 256 px PNG of each icon next to the .ico.
#>
param([switch]$PreviewPng)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
$sizes  = 16, 20, 24, 32, 40, 48, 64, 256

function New-RoundedRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-IconBitmap([int]$size, [string]$baseHex, [string]$faceHex, [string]$glyph) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single]$size

    # Keycap body, then the lighter top face sitting slightly high on it.
    $body = New-RoundedRect ($s * 0.03) ($s * 0.03) ($s * 0.94) ($s * 0.94) ($s * 0.20)
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($baseHex))), $body)
    $face = New-RoundedRect ($s * 0.09) ($s * 0.06) ($s * 0.82) ($s * 0.80) ($s * 0.16)
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($faceHex))), $face)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ($s * 0.125)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    if ($glyph -eq 'tick') {
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF ($s * 0.28), ($s * 0.47)),
            (New-Object System.Drawing.PointF ($s * 0.44), ($s * 0.62)),
            (New-Object System.Drawing.PointF ($s * 0.72), ($s * 0.30))
        )
        $g.DrawLines($pen, $points)
    } else {
        $g.DrawLine($pen, [single]($s * 0.31), [single]($s * 0.46), [single]($s * 0.69), [single]($s * 0.46))
    }

    $g.Dispose()
    return $bmp
}

# One .ico image entry. Sizes below 256 are stored as classic 32-bit bitmaps,
# which every icon loader accepts. The 256 px entry is stored as PNG.
function Get-IconImageBytes([System.Drawing.Bitmap]$bmp) {
    $size = $bmp.Width
    $ms = New-Object System.IO.MemoryStream

    if ($size -ge 256) {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$ms.ToArray()
    }

    $rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $pixels = New-Object byte[] ($stride * $size)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $bmp.UnlockBits($data)

    $maskStride = [int]([math]::Floor(($size + 31) / 32)) * 4
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([uint32]40)                 # BITMAPINFOHEADER size
    $w.Write([int32]$size)               # width
    $w.Write([int32]($size * 2))         # height counts the colour rows plus the mask rows
    $w.Write([uint16]1)                  # planes
    $w.Write([uint16]32)                 # bits per pixel
    $w.Write([uint32]0)                  # no compression
    $w.Write([uint32]($size * $size * 4 + $maskStride * $size))
    $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($row = $size - 1; $row -ge 0; $row--) {     # bitmap rows are stored bottom-up
        $w.Write($pixels, $row * $stride, $size * 4)
    }
    $w.Write((New-Object byte[] ($maskStride * $size)))   # empty mask: the alpha channel does the work
    $w.Flush()
    return ,$ms.ToArray()
}

function Write-Icon([string]$path, [string]$baseHex, [string]$faceHex, [string]$glyph) {
    $images = @()
    foreach ($size in $sizes) {
        $bmp = New-IconBitmap $size $baseHex $faceHex $glyph
        $images += ,@($size, (Get-IconImageBytes $bmp))
        if ($PreviewPng -and $size -eq 256) {
            $bmp.Save([System.IO.Path]::ChangeExtension($path, '.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        $bmp.Dispose()
    }

    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)   # ICONDIR
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
        $size = $image[0]; $bytes = $image[1]
        $dim = if ($size -ge 256) { 0 } else { $size }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$bytes.Length); $w.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($image in $images) { $w.Write([byte[]]$image[1]) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($path, $out.ToArray())
    Write-Host ("wrote {0} ({1:N0} bytes)" -f $path, $out.Length)
}

Write-Icon (Join-Path $assets 'icon-on.ico')  '#166534' '#16A34A' 'tick'
Write-Icon (Join-Path $assets 'icon-off.ico') '#4B5563' '#7B8494' 'bar'
