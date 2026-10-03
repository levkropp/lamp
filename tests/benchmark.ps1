param([string]$Ffmpeg = 'ffmpeg', [int]$Runs = 5,[ValidateSet('mp3','vorbis')][string]$Codec='mp3')
$ErrorActionPreference='Stop'
if ($Runs -lt 3 -or $Runs -gt 20) { throw 'Use 3..20 benchmark runs.' }
$root=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path $PSScriptRoot 'generated'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$extension=if($Codec -eq 'vorbis'){'ogg'}else{'mp3'}
$file=Join-Path $scratch "$Codec-benchmark.$extension"
# Independent noise channels exercise both spectral paths. Never played aloud.
$source='anoisesrc=r=48000:d=30:seed=7722:a=0.2[a];anoisesrc=r=48000:d=30:seed=7793:a=0.2[b];[a][b]amerge=inputs=2'
$coding=if($Codec -eq 'vorbis'){@('-c:a','libvorbis','-q:a','8')}else{@('-c:a','libmp3lame','-b:a','320k')}
& $Ffmpeg -hide_banner -loglevel error -y -f lavfi -i $source @coding $file
if ($LASTEXITCODE) { throw 'Benchmark fixture generation failed.' }
$measure=@()
for ($i=0;$i -lt $Runs;$i++) {
    $stats=& (Join-Path $root 'bin\lamp-cli.exe') --check $file
    if ($LASTEXITCODE -or "$stats" -notmatch 'frames=1440000 ') { throw "Benchmark decoding failed: $stats" }
    $cpu=[regex]::Match("$stats",'cpu_us=(\d+)').Groups[1].Value
    $wall=[regex]::Match("$stats",'elapsed_ms=(\d+)').Groups[1].Value
    $measure+=[pscustomobject]@{run=$i+1;cpu_us=[long]$cpu;elapsed_ms=[long]$wall;stats="$stats"}
}
$median=($measure.cpu_us | Sort-Object)[[int][Math]::Floor($Runs/2)]
$report=[pscustomobject]@{
    fixture="30 seconds, $Codec, 48 kHz stereo, independent seeded noise; $(if($Codec -eq 'vorbis'){'quality 8'}else{'320 kbps'})";
    executable_bytes=(Get-Item -LiteralPath (Join-Path $root 'bin\lamp-cli.exe')).Length;
    median_cpu_us=$median;one_core_equivalent_percent=$median/30000000*100;
    scope='Offline decode including process setup. Coarse Windows process CPU accounting; excludes audio rendering. No comparison with other players.';
    runs=$measure
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "$Codec-benchmark.json") -Encoding utf8
$report | Select-Object median_cpu_us,one_core_equivalent_percent,executable_bytes
