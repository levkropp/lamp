param([int]$Workers = 4, [int]$Seconds = 8, [ValidateSet('flac','mp3','vorbis')][string]$Codec = 'flac')
$ErrorActionPreference='Stop'
if ($Workers -lt 1 -or $Workers -gt 8 -or $Seconds -lt 6 -or $Seconds -gt 30) { throw 'Use 1..8 workers and 6..30 seconds.' }
$root=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path $PSScriptRoot 'generated'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$extension=if($Codec -eq 'vorbis'){'ogg'}else{$Codec}
$fixture=Join-Path $scratch "stress-silence.$extension"
$coding=switch($Codec){'mp3'{@('-c:a','libmp3lame','-b:a','128k')};'vorbis'{@('-c:a','libvorbis','-q:a','4')};'flac'{@('-c:a','flac')}}
$layout=if ($Codec -eq 'flac') {'mono'} else {'stereo'}
& ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=44100:cl=$layout" -t $Seconds @coding $fixture
if ($LASTEXITCODE) { throw 'Fixture generation failed.' }
$shell=(Get-Process -Id $PID).Path
$workerScript=Join-Path $PSScriptRoot 'stress-worker.ps1'
$processes=[Collections.Generic.List[Diagnostics.Process]]::new()
$stdoutPath=Join-Path $scratch 'stress.stdout.txt'
$stderrPath=Join-Path $scratch 'stress.stderr.txt'
try {
    for ($i=0;$i -lt $Workers;$i++) {
        $p=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',('"'+$workerScript+'"'),'-Seconds',($Seconds+2)) -WindowStyle Hidden -PassThru
        $processes.Add($p)
    }
    $exe=Join-Path $root 'bin\lamp-cli.exe'
    $player=Start-Process -FilePath $exe -ArgumentList ('"'+$fixture+'"') -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    if (-not $player.WaitForExit(($Seconds+5)*1000)) { $player.Kill(); throw 'Playback exceeded its deadline.' }
    $stats=Get-Content -LiteralPath $stdoutPath -Raw
    if ($player.ExitCode -ne 0 -or $stats -notmatch 'underruns=0 ' -or $stats -notmatch 'endpoint_dry=0') { throw "Stress test failed: $stats" }
    $record=[pscustomobject]@{codec=$Codec;workers=$Workers;seconds=$Seconds;result='passed';stats=$stats.Trim();scope='bounded CPU pressure with digital silence; not whole-system saturation'}
    $report=switch($Codec){'mp3'{'mp3-stress-verification.json'};'vorbis'{'vorbis-stress-verification.json'};'flac'{'stress-verification.json'}}
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root $report) -Encoding utf8
    Write-Output $stats
} finally {
    foreach ($p in $processes) { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() }
}
