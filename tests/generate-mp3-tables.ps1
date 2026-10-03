param([string]$ReferenceHeader = (Join-Path $PSScriptRoot 'reference\dr_mp3.h'))
$ErrorActionPreference='Stop'
$culture=[Globalization.CultureInfo]::InvariantCulture
$source=Get-Content -LiteralPath $ReferenceHeader -Raw
$text=[Text.StringBuilder]::new()
[void]$text.AppendLine('; Data tables adapted from dr_mp3 by David Reid (MIT-0), based on minimp3 (CC0).')
[void]$text.AppendLine('; See THIRD_PARTY_NOTICES. No C implementation is linked into the player.')
function Get-CArray([string]$Name) {
    $match=[regex]::Match($source,'\b'+[regex]::Escape($Name)+'\s*\[[^;=]*=\s*\{([\s\S]*?)\};')
    if (-not $match.Success) { throw "Missing reference array $Name" }
    return [regex]::Matches($match.Groups[1].Value,'(?<![A-Za-z_])[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?[fF]?') | ForEach-Object {$_.Value.TrimEnd('f','F')}
}
function Emit([string]$Name,[string]$Type,$Values) {
    if ($Type -eq 'DWORD') { [void]$text.AppendLine('ALIGN 16') }
    [void]$text.AppendLine("$Name LABEL $Type")
    $directive=switch ($Type) { 'BYTE' {'db'} 'WORD' {'dw'} 'DWORD' {'dd'} }
    for ($i=0;$i -lt $Values.Count;$i+=16) {
        $last=[Math]::Min($i+15,$Values.Count-1)
        [void]$text.AppendLine('    '+$directive+' '+(($Values[$i..$last]) -join ','))
    }
    [void]$text.AppendLine($Name+'_count EQU '+$Values.Count)
}
foreach ($item in @(@('mp_sfb_long','g_scf_long','BYTE'),@('mp_sfb_short','g_scf_short','BYTE'),@('mp_sfb_mixed','g_scf_mixed','BYTE'),@('mp_huff_tabs','tabs','WORD'),@('mp_huff_index','tabindex','WORD'),@('mp_huff_linbits','g_linbits','BYTE'),@('mp_count32','tab32','BYTE'),@('mp_count33','tab33','BYTE'),@('mp_partitions','g_scf_partitions','BYTE'),@('mp_scfc','g_scfc_decode','BYTE'),@('mp_mod','g_mod','BYTE'),@('mp_preamp','g_preamp','BYTE'))) {
    Emit $item[0] $item[2] @(Get-CArray $item[1])
}
function FloatBits([double]$Value) {
    $bits=[BitConverter]::ToUInt32([BitConverter]::GetBytes([single]$Value),0)
    return '0'+$bits.ToString('X8',$culture)+'h'
}
foreach ($item in @(@('mp_aa','g_aa'),@('mp_pan','g_pan'),@('mp_twid9','g_twid9'),@('mp_mdct_win','g_mdct_window'),@('mp_twid3','g_twid3'),@('mp_synth_win','g_win'),@('mp_dct_sec','g_sec'))) {
    $values=@(Get-CArray $item[1] | ForEach-Object {FloatBits ([double]::Parse($_,$culture))})
    Emit $item[0] 'DWORD' $values
}
$pow=@(0..8206 | ForEach-Object {FloatBits ([Math]::Pow($_,4.0/3.0))})
Emit 'mp_pow43' 'DWORD' $pow
$gain=@(-800..100 | ForEach-Object {FloatBits ([Math]::Pow(2.0,$_/4.0))})
Emit 'mp_gain' 'DWORD' $gain
$dct9=@(for($i=0;$i -lt 9;$i++){for($j=0;$j -lt 9;$j++){FloatBits ([Math]::Cos([Math]::PI*$j*(2*$i+1)/18.0))}})
Emit 'mp_dct9' 'DWORD' $dct9
$target=Join-Path (Split-Path $PSScriptRoot -Parent) 'src\mp3_tables.inc'
[IO.File]::WriteAllText($target,$text.ToString(),[Text.UTF8Encoding]::new($false))
Write-Output "Generated $target"
