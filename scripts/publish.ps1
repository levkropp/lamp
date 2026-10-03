param(
    [string]$Repository = 'levkropp/lamp',
    [string]$NoreplyEmail,
    [switch]$SkipRelease
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$gitArgs = @('-c',('safe.directory=' + $root.Replace('\','/')))
if ($Repository -ne 'levkropp/lamp') { throw 'This publishing script is scoped to levkropp/lamp.' }
Get-Command gh,git,node -ErrorAction Stop | Out-Null
function Invoke-Gh {
    param([string[]]$Arguments)
    $savedErrorAction = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = & gh @Arguments 2>&1; $commandExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedErrorAction }
    if ($commandExit) { throw "GitHub command failed: $($output -join [Environment]::NewLine)" }
    return $output
}
function Get-Api {
    param([string]$Endpoint,[switch]$AllowMissing)
    $savedErrorAction = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = & gh api $Endpoint 2>&1; $commandExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedErrorAction }
    if ($commandExit) {
        if ($AllowMissing -and ($output -join ' ') -match 'HTTP 404') { return $null }
        throw "GitHub API failed: $($output -join [Environment]::NewLine)"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}
function Invoke-Git {
    param([string[]]$Arguments)
    & git @gitArgs @Arguments
    if ($LASTEXITCODE) { throw "Git failed: $($Arguments[0])" }
}
Push-Location $root
$identityNames = @('GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL')
$savedIdentity = @{}
foreach ($key in $identityNames) { $savedIdentity[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
$savedPrompt = $env:GIT_TERMINAL_PROMPT
try {
    $account = Get-Api 'user'
    if ($account.login -ne 'levkropp' -or [long]$account.id -le 0) { throw 'Authenticate gh as levkropp before publishing.' }
    $login = [string]$account.login
    $idEmail = "$($account.id)+$login@users.noreply.github.com"
    $legacyEmail = "$login@users.noreply.github.com"
    if (-not $NoreplyEmail) { $NoreplyEmail = $idEmail }
    if ($NoreplyEmail -notin @($idEmail,$legacyEmail)) { throw 'Use the noreply address shown in levkropp GitHub email settings.' }
    if (-not (Test-Path -LiteralPath '.git')) { Invoke-Git -Arguments @('init','--initial-branch=main') }
    $branch = & git @gitArgs branch --show-current
    if ($branch -ne 'main') { throw 'Publish from the main branch; no branch will be overwritten.' }
    Invoke-Git -Arguments @('config','--local','user.name',$login)
    Invoke-Git -Arguments @('config','--local','user.email',$NoreplyEmail)
    $env:GIT_AUTHOR_NAME=$login; $env:GIT_COMMITTER_NAME=$login
    $env:GIT_AUTHOR_EMAIL=$NoreplyEmail; $env:GIT_COMMITTER_EMAIL=$NoreplyEmail
    $env:GIT_TERMINAL_PROMPT='0'
    ./build.ps1
    & node tests/verify-runtime.js
    if ($LASTEXITCODE) { throw 'Runtime verification failed.' }
    & node tests/smoke.js
    if ($LASTEXITCODE) { throw 'Decoder smoke verification failed.' }
    & node tests/verify-site.js
    if ($LASTEXITCODE) { throw 'Website verification failed.' }
    ./tests/render-ui.ps1
    $repo = Get-Api "repos/$Repository" -AllowMissing
    if (-not $repo) {
        Invoke-Gh -Arguments @('repo','create',$Repository,'--public','--description',"Lev's Assembly Media Player - an assembly-first media player.") | Out-Host
    } elseif ($repo.private) { throw 'The existing repository is private. Its visibility will not be changed.' }
    $origin = & git @gitArgs remote get-url origin 2>$null
    if ($LASTEXITCODE) {
        Invoke-Git -Arguments @('remote','add','origin',"https://github.com/$Repository.git")
    } elseif ($origin -notin @("https://github.com/$Repository.git","https://github.com/$Repository","git@github.com:$Repository.git")) {
        throw 'The origin remote points elsewhere; it will not be replaced.'
    }
    # Use gh for credentials for this operation only; no global Git configuration changes.
    $credentialArgs = @('-c','credential.helper=','-c','credential.helper=!gh auth git-credential')
    $remoteHeads = & git @gitArgs @credentialArgs ls-remote --heads origin
    if ($LASTEXITCODE) { throw 'Could not inspect remote history.' }
    if ($remoteHeads) {
        Invoke-Git -Arguments ($credentialArgs + @('fetch','origin'))
        & git @gitArgs rev-parse --verify HEAD 2>$null | Out-Null
        if ($LASTEXITCODE) { throw 'The existing remote contains commits. Integrate them before publishing; no remote history was overwritten.' }
        & git @gitArgs show-ref --verify --quiet refs/remotes/origin/main
        if ($LASTEXITCODE) { throw 'The existing remote uses a different branch. Review it before publishing.' }
        & git @gitArgs merge-base --is-ancestor origin/main HEAD
        if ($LASTEXITCODE) { throw 'Remote main is not an ancestor of local HEAD. Integrate changes before publishing; no force push is used.' }
    }
    Invoke-Git -Arguments @('add','--all')
    & git @gitArgs diff --cached --quiet
    if ($LASTEXITCODE -eq 1) { Invoke-Git -Arguments @('commit','-m',"Publish LAMP source, documentation and website") }
    elseif ($LASTEXITCODE) { throw 'Could not inspect staged changes.' }
    $head = & git @gitArgs rev-parse HEAD
    if ($LASTEXITCODE) { throw 'No commit is available to publish.' }
    Invoke-Git -Arguments ($credentialArgs + @('push','--set-upstream','origin','main'))
    # Split the site's history so Pages needs no custom workflow-upload permission.
    Invoke-Git -Arguments @('subtree','split','--prefix=site','--branch=lamp-pages')
    Invoke-Git -Arguments ($credentialArgs + @('push','origin','lamp-pages:gh-pages'))
    $pages = Get-Api "repos/$Repository/pages" -AllowMissing
    $method = if ($pages) {'PUT'} else {'POST'}
    Invoke-Gh -Arguments @('api','--method',$method,"repos/$Repository/pages",'-f','build_type=legacy','-f','source[branch]=gh-pages','-f','source[path]=/') | Out-Host
    Invoke-Gh -Arguments @('repo','edit',$Repository,'--homepage','https://levkropp.github.io/lamp/') | Out-Host
    ./package.ps1
    if (-not $SkipRelease) {
        $version = (Get-Content -LiteralPath VERSION -Raw).Trim()
        $tag = "v$version"
        $release = Get-Api "repos/$Repository/releases/tags/$tag" -AllowMissing
        if (-not $release) {
            $archive = Join-Path (Split-Path $root -Parent) "outputs/lamp-windows-x64-v$version.zip"
            Invoke-Gh -Arguments @('release','create',$tag,$archive,'--repo',$Repository,'--target',$head,'--title',"LAMP $version",'--notes-file','docs/release-v0.3.0.md','--prerelease') | Out-Host
        }
    }
    Write-Output "Published source commit $head with $login <$NoreplyEmail>."
    Write-Output "Pages deployment requested. Inspect its result with: gh api repos/$Repository/pages/builds/latest"
} finally {
    foreach ($key in $identityNames) { [Environment]::SetEnvironmentVariable($key,$savedIdentity[$key],'Process') }
    $env:GIT_TERMINAL_PROMPT=$savedPrompt
    Pop-Location
}
