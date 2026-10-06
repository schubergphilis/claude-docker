# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# PowerShell entry point for claude-docker on Windows. A thin launcher, not a
# port: it runs run.sh under the bash that ships with Git for Windows, so every
# flag, mount and security control stays in one script. Usage is identical:
#
#   claude-docker C:\Users\me\dev\repo -- --resume
#
# Deliberately never calls a bare `bash`: on Windows that usually resolves to
# C:\Windows\System32\bash.exe, which is WSL's — run.sh would then run inside a
# Linux distro with a different $HOME, different paths, and no Windows engine.

$ErrorActionPreference = 'Stop'

# Find Git for Windows' bash.exe from git.exe's location. git.exe sits in
# <GitRoot>\cmd, <GitRoot>\bin or <GitRoot>\mingw64\bin depending on the
# installer's PATH option; bash.exe is always <GitRoot>\bin\bash.exe.
$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) {
  [Console]::Error.WriteLine("claude-docker: Git for Windows not found on PATH - install it from https://git-scm.com/download/win")
  exit 1
}
$bash = $null
$dir = Split-Path -Parent $git.Source
for ($i = 0; $i -lt 3 -and $dir; $i++) {
  $candidate = Join-Path $dir 'bin\bash.exe'
  if (Test-Path -LiteralPath $candidate) { $bash = $candidate; break }
  $dir = Split-Path -Parent $dir
}
if (-not $bash) {
  [Console]::Error.WriteLine("claude-docker: found $($git.Source) but no bin\bash.exe next to it - is this a Git for Windows install?")
  exit 1
}

# Forward slashes: bash reads the script path itself, and backslashes are
# escape characters to it.
$runSh = (Join-Path $PSScriptRoot 'run.sh') -replace '\\', '/'

# Git Bash's own launcher sets these; a bare bash.exe started from PowerShell
# may not. HOME is where run.sh finds ~/.claude, ~/.aws, ~/.cache/claude-docker
# (bash converts the Windows form itself). TERM is forwarded into the container,
# where Claude's UI needs it; Windows Terminal and conhost both speak xterm.
# Set for the child only and restored, so the PowerShell session is unchanged.
$saved = @{ HOME = $env:HOME; TERM = $env:TERM }
try {
  if (-not $env:HOME) { $env:HOME = $env:USERPROFILE }
  if (-not $env:TERM) { $env:TERM = 'xterm-256color' }
  & $bash $runSh @args
  $code = $LASTEXITCODE
} finally {
  $env:HOME = $saved.HOME
  $env:TERM = $saved.TERM
}
exit $code
