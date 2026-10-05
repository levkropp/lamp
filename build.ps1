param([switch]$Debug, [string]$OutputDirectory, [switch]$Tests)
# Builds bin\lamp.exe and bin\lamp-cli.exe with LLVM (llvm-mc, lld-link,
# llvm-dlltool, llvm-rc) and Python. Install LLVM, e.g. `winget install LLVM.LLVM`,
# or set LLVM_BIN. Linux builds use ./build.sh.
$ErrorActionPreference = 'Stop'
$arguments = @((Join-Path $PSScriptRoot 'tools\build-windows.py'))
if ($OutputDirectory) { $arguments += @('--out', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)) }
if ($Debug) { $arguments += '--debug' }
if ($Tests) { $arguments += '--tests' }
$python = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }
& $python @arguments
if ($LASTEXITCODE) { throw 'Windows build failed.' }
