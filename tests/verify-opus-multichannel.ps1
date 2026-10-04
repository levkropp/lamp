param([string]$Ffmpeg='ffmpeg',[string]$Node='node',[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$exe=Join-Path $out 'lamp-cli.exe'
$scratch=Join-Path $PSScriptRoot 'generated\multichannel-opus'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$report=[Collections.Generic.List[object]]::new()
function FF([string[]]$Arguments){
 & $Ffmpeg -hide_banner -loglevel error -y @Arguments
 if($LASTEXITCODE){throw 'Multichannel Opus fixture/reference failed'}
}
# Speaker labels avoid depending on FFmpeg's PCM channel order. Coefficients
# follow RFC7845 Figures4-9, evaluated independently in double precision.
$q=1/[Math]::Sqrt(2);$a=[Math]::Sqrt(3)/2
$layouts=@('mono','stereo','3.0','quad','5.0','5.1','6.1','7.1')
$speakers=@(@('FC'),@('FL','FR'),@('FL','FC','FR'),@('FL','FR','BL','BR'),@('FL','FC','FR','BL','BR'),@('FL','FC','FR','BL','BR','LFE'),@('FL','FC','FR','SL','SR','BC','LFE'),@('FL','FC','FR','SL','SR','BL','BR','LFE'))
$left=@(@(1),@(1,0),@(1,$q,0),@(1,0,$a,0.5),@(1,$q,0,$a,0.5),@(1,$q,0,$a,0.5,$q),@(1,$q,0,$a,0.5,($a*$q),$q),@(1,$q,0,$a,0.5,$a,0.5,$q))
$right=@(@(1),@(0,1),@(0,$q,1),@(0,1,0.5,$a),@(0,$q,1,0.5,$a),@(0,$q,1,0.5,$a,$q),@(0,$q,1,0.5,$a,($a*$q),$q),@(0,$q,1,0.5,$a,0.5,$a,$q))
$normal=@(1,1,(1/(1+$q)),(1/(1+$a+0.5)),(2/(1+$q+$a+0.5)),(2/(1+2*$q+$a+0.5)),(2/(1+2*$q+$a+0.5+$a*$q)),(2/(2+2*$q+2*$a)))
foreach($channels in 1..8){foreach($duration in @(2.5,5,10,20,40,60,120)){foreach($vbr in @('on','off')){
 $name="opus-family1-$channels-$duration-$vbr.opus";$file=Join-Path $scratch $name
 $source=((0..($channels-1) | ForEach-Object {"0.08*sin(2*PI*$([int](113+79*$_))*t)+0.012*sin(2*PI*$([int](3101+131*$_))*t)"}) -join '|')
 $application=if($duration -lt 10){'lowdelay'}else{'audio'}
 FF @('-f','lavfi','-i',"aevalsrc=$($source):s=48000:d=0.73:c=$($layouts[$channels-1])",'-c:a','libopus','-mapping_family','1','-application',$application,'-frame_duration',"$duration",'-b:a',"$([int](48000*$channels))",'-vbr',$vbr,$file)
 $bytes=[IO.File]::ReadAllBytes($file);$head=27+$bytes[26]
 if($bytes[$head+9] -ne $channels -or $bytes[$head+18] -ne 1){throw 'Encoder did not create the requested family1 header'}
 $ours=Join-Path $scratch "$name.ours.f32";$reference=Join-Path $scratch "$name.reference.f32"
 if(Test-Path -LiteralPath $ours){Remove-Item -LiteralPath $ours}
 $stats=& $exe --decode $file $ours
 if($LASTEXITCODE){throw "Multichannel Opus decode failed $name $stats"}
 $terms=@()
 foreach($weights in @($left[$channels-1],$right[$channels-1])){
  $row=@();for($c=0;$c -lt $channels;$c++){if($weights[$c] -ne 0){$coefficient=($weights[$c]*$normal[$channels-1]).ToString('G17',[Globalization.CultureInfo]::InvariantCulture);$row+="$coefficient*$($speakers[$channels-1][$c])"}}
  $terms+=($row -join '+')
 }
 FF @('-request_sample_fmt','flt','-c:a','libopus','-i',$file,'-af',"aformat=sample_fmts=flt,pan=stereo|c0=$($terms[0])|c1=$($terms[1])",'-ar','48000','-c:a','pcm_f32le','-f','f32le',$reference)
 $comparison=& $Node (Join-Path $PSScriptRoot 'compare-pcm.js') $ours $reference 60 0.00004
 if($LASTEXITCODE){throw "Modern multichannel PCM mismatch $name $comparison"}
 $measure=$comparison | ConvertFrom-Json
 $report.Add([pscustomobject]@{test=$name;result='matched';source_channels=$channels;streams=$bytes[$head+19];coupled_streams=$bytes[$head+20];frames=$measure.frames;snr_db=$measure.snrDb;peak_error=$measure.peakError;stats="$stats"})
 Write-Output "$name $comparison"
}}}
$ffmpegVersion=@(& $Ffmpeg -version)
if($LASTEXITCODE){throw 'Could not record the reference version'}
[pscustomobject]@{result='passed';scope='112 independent modern-libopus Ogg family1 files,1..8 speaker channels,2.5..120ms packets,VBR/CBR and explicit RFC7845 stereo downmix; decoder PCM comparisons, not native surround output or chained Ogg';minimum_snr_db=60;maximum_absolute_error=0.00004;ffmpeg_version=$ffmpegVersion[0];checks=@($report)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'opus-multichannel-verification.json') -Encoding utf8
