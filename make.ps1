# trndi-cli Windows build script (mirror of the Makefile).
#   .\make.ps1           release build
#   .\make.ps1 debug     debug build (-g -gl -gh)
#   .\make.ps1 clean     remove build artifacts
#
# Note: the console native's HTTP transport is libcurl, so running
# bin\trndi-cli.exe needs libcurl.dll in PATH or next to the exe
# (https://curl.se/windows/).

param([string]$Target = 'release')

$ErrorActionPreference = 'Stop'

# Locate fpc: PATH first, then the standard Lazarus bundle location.
$fpc = (Get-Command fpc.exe -ErrorAction SilentlyContinue).Source
if (-not $fpc) {
    $candidate = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
    if (Test-Path $candidate) { $fpc = $candidate }
}
if (-not $fpc) {
    throw 'fpc.exe not found on PATH or at C:\lazarus\fpc\3.2.2\bin\x86_64-win64'
}

$T = 'vendor/trndi'
$flags = @(
    '-Mobjfpc', '-Sh', '-dX_CONSOLE', '-dWITHTHREADS',
    "-Fu$T/units/trndi", "-Fu$T/units/trndi/api",
    "-Fu$T/units/slicke", "-Fu$T/units/misc",
    "-Fi$T/inc", '-FUbuild', '-FEbin', '-otrndi-cli.exe'
)

switch ($Target) {
    'release' { }
    'debug'   { $flags += @('-g', '-gl', '-gh') }
    'clean'   {
        Remove-Item -Recurse -Force build, bin -ErrorAction SilentlyContinue
        exit 0
    }
    default   { throw "Unknown target '$Target' (release, debug, clean)" }
}

New-Item -ItemType Directory -Force build, bin | Out-Null
& $fpc @flags src/trndicli.pas
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'Built bin\trndi-cli.exe'
