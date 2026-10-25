# Build a module zip with forward-slash entry names (Windows Compress-Archive
# writes backslashes, which Android's unzip treats as literal filename chars).
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Out
)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Remove-Item -Force $Out -ErrorAction SilentlyContinue
$Out = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Out))
$base = (Resolve-Path $Source).Path.TrimEnd('\')
$zip = [System.IO.Compression.ZipFile]::Open($Out, 'Create')
try {
    Get-ChildItem -Recurse -File $Source | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1).Replace('\', '/')
        $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $entry.Open()
        $fs = [System.IO.File]::OpenRead($_.FullName)
        try { $fs.CopyTo($s) } finally { $fs.Close(); $s.Close() }
    }
} finally { $zip.Dispose() }
Write-Host "wrote $Out"
