# Stages shared code into the hosted agent package before a local run or `azd deploy`:
#   - .github/skills/sql-ha-*/SKILL.md  -> src/sql-ha-agent/skills   (same instructions the VS Code agent uses)
#   - core/sqlha                         -> src/sql-ha-agent/sqlha    (shared library also used by the backend and MCP server)
# Runs automatically as the azd predeploy hook. Both targets are generated, so they are git-ignored.
$ErrorActionPreference = 'Stop'
$controlPlane = Resolve-Path (Join-Path $PSScriptRoot '..')
$repo = Resolve-Path (Join-Path $controlPlane '..')
$agentDir = Join-Path $controlPlane 'src\sql-ha-agent'

$skillsTarget = Join-Path $agentDir 'skills'
if (Test-Path $skillsTarget) { Remove-Item $skillsTarget -Recurse -Force }
New-Item -ItemType Directory -Path $skillsTarget | Out-Null
Get-ChildItem (Join-Path $repo '.github\skills') -Directory -Filter 'sql-ha-*' | ForEach-Object {
    $dest = Join-Path $skillsTarget $_.Name
    New-Item -ItemType Directory -Path $dest | Out-Null
    Copy-Item (Join-Path $_.FullName 'SKILL.md') $dest
}
Write-Host "Synced $((Get-ChildItem $skillsTarget -Directory).Count) skills to $skillsTarget"

$coreTarget = Join-Path $agentDir 'sqlha'
if (Test-Path $coreTarget) { Remove-Item $coreTarget -Recurse -Force }
Copy-Item (Join-Path $controlPlane 'core\sqlha') $coreTarget -Recurse -Exclude '__pycache__'
Get-ChildItem $coreTarget -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
Write-Host "Synced sqlha core library to $coreTarget"
