# Original synthetic FLAC vectors. Forces branches that an encoder may avoid.
# Dot-source and call New-FlacVectors <directory>; no reference code copied.
function Add-FlacBits($Builder, [long]$Value, [int]$Width) {
    for ($j=$Width-1; $j -ge 0; $j--) { [void]$Builder.Append([char](48+(($Value -shr $j) -band 1))) }
}
function Convert-FlacBits($Builder) {
    while ($Builder.Length % 8) { [void]$Builder.Append('0') }
    $data = [byte[]]::new($Builder.Length/8)
    for ($j=0; $j -lt $data.Length; $j++) { $data[$j]=[Convert]::ToByte($Builder.ToString($j*8,8),2) }
    return ,$data
}
function Get-FlacCrc([byte[]]$Data, [int]$Width) {
    $crc=0
    $poly=if ($Width -eq 8) {7} else {0x8005}
    $mask=(1 -shl $Width)-1
    foreach ($b in $Data) {
        $crc=$crc -bxor ([int]$b -shl ($Width-8))
        for ($j=0; $j -lt 8; $j++) {
            $crc=$crc -shl 1
            if ($crc -band (1 -shl $Width)) { $crc=$crc -bxor $poly }
        }
        $crc=$crc -band $mask
    }
    return $crc
}
function New-FlacVectors([string]$Directory) {
    $specs=@(
        @{name='constant'; type=0; order=0; mode=1; rice=4; escape=$false; wasted=0},
        @{name='verbatim'; type=1; order=0; mode=1; rice=4; escape=$false; wasted=0},
        @{name='fixed0'; type=8; order=0; mode=1; rice=4; escape=$false; wasted=0},
        @{name='fixed1'; type=9; order=1; mode=1; rice=4; escape=$false; wasted=0},
        @{name='fixed2'; type=10; order=2; mode=1; rice=4; escape=$false; wasted=0},
        @{name='fixed3'; type=11; order=3; mode=1; rice=4; escape=$false; wasted=0},
        @{name='fixed4'; type=12; order=4; mode=1; rice=4; escape=$false; wasted=0},
        @{name='lpc3'; type=34; order=3; mode=1; rice=4; escape=$false; wasted=0},
        @{name='rice5'; type=10; order=2; mode=1; rice=5; escape=$false; wasted=0},
        @{name='escape'; type=10; order=2; mode=1; rice=4; escape=$true; wasted=0},
        @{name='escape5'; type=10; order=2; mode=1; rice=5; escape=$true; wasted=0},
        @{name='wasted2'; type=10; order=2; mode=1; rice=4; escape=$false; wasted=2},
        @{name='left-side'; type=10; order=2; mode=8; rice=4; escape=$false; wasted=0},
        @{name='side-right'; type=10; order=2; mode=9; rice=4; escape=$false; wasted=0},
        @{name='mid-side'; type=10; order=2; mode=10; rice=4; escape=$false; wasted=0}
    )
    $paths=[System.Collections.Generic.List[string]]::new()
    foreach ($spec in $specs) {
        $left=[long[]]::new(32); $right=[long[]]::new(32)
        for ($i=0;$i -lt 32;$i++) {
            $left[$i]=[long][Math]::Round(1000*[Math]::Sin($i*0.3))
            $right[$i]=[long][Math]::Round(600*[Math]::Cos($i*0.4))
            if ($spec.type -eq 0) { $left[$i]=1337; $right[$i]=-321 }
            if ($spec.wasted) { $left[$i]*=4; $right[$i]*=4 }
        }
        $a=$left.Clone(); $b=$right.Clone()
        for ($i=0;$i -lt 32;$i++) {
            switch ($spec.mode) {
                8 { $b[$i]=$left[$i]-$right[$i] }
                9 { $a[$i]=$left[$i]-$right[$i] }
                10 { $a[$i]=($left[$i]+$right[$i]) -shr 1; $b[$i]=$left[$i]-$right[$i] }
            }
        }
        $bits=[Text.StringBuilder]::new()
        for ($channel=0;$channel -lt 2;$channel++) {
            $samples=if ($channel -eq 0) {$a} else {$b}
            $bps=16
            if (($spec.mode -eq 9 -and $channel -eq 0) -or ($spec.mode -in @(8,10) -and $channel -eq 1)) { $bps++ }
            Add-FlacBits $bits 0 1
            Add-FlacBits $bits $spec.type 6
            Add-FlacBits $bits ([int]($spec.wasted -gt 0)) 1
            if ($spec.wasted) {
                for ($j=1;$j -lt $spec.wasted;$j++) { Add-FlacBits $bits 0 1 }
                Add-FlacBits $bits 1 1
                $bps-=$spec.wasted
                for ($i=0;$i -lt 32;$i++) { $samples[$i]=$samples[$i] -shr $spec.wasted }
            }
            if ($spec.type -eq 0) { Add-FlacBits $bits $samples[0] $bps; continue }
            if ($spec.type -eq 1) {
                foreach ($sample in $samples) { Add-FlacBits $bits $sample $bps }
                continue
            }
            for ($i=0;$i -lt $spec.order;$i++) { Add-FlacBits $bits $samples[$i] $bps }
            $coeff=switch ($spec.order) { 0 {,@()} 1 {,@(1)} 2 {,@(2,-1)} 3 {,@(3,-3,1)} 4 {,@(4,-6,4,-1)} }
            if ($spec.type -ge 32) {
                Add-FlacBits $bits 3 4      # 4-bit coefficient precision
                Add-FlacBits $bits 0 5      # zero right shift
                foreach ($c in $coeff) { Add-FlacBits $bits $c 4 }
            }
            Add-FlacBits $bits ($spec.rice-4) 2
            Add-FlacBits $bits 1 4          # two residual partitions
            for ($partition=0;$partition -lt 2;$partition++) {
                $start=if ($partition -eq 0) {$spec.order} else {16}
                $end=if ($partition -eq 0) {16} else {32}
                $parameter=if ($spec.escape) {(1 -shl $spec.rice)-1} else {8}
                Add-FlacBits $bits $parameter $spec.rice
                if ($spec.escape) { Add-FlacBits $bits 16 5 }
                for ($i=$start;$i -lt $end;$i++) {
                    $prediction=0L
                    for ($j=0;$j -lt $spec.order;$j++) { $prediction+=$coeff[$j]*$samples[$i-$j-1] }
                    $residual=$samples[$i]-$prediction
                    if ($spec.escape) { Add-FlacBits $bits $residual 16; continue }
                    $unsigned=if ($residual -lt 0) {-2*$residual-1} else {2*$residual}
                    $quotient=$unsigned -shr $parameter
                    for ($j=0;$j -lt $quotient;$j++) { Add-FlacBits $bits 0 1 }
                    Add-FlacBits $bits 1 1
                    Add-FlacBits $bits ($unsigned -band ((1 -shl $parameter)-1)) $parameter
                }
            }
        }
        $payload=Convert-FlacBits $bits
        $header=[byte[]]@(0xff,0xf8,0x60,(($spec.mode -shl 4) -bor 8),0,31)
        $header+=[byte](Get-FlacCrc $header 8)
        $frame=[byte[]]($header+$payload)
        $crc=Get-FlacCrc $frame 16
        $frame+=[byte[]]@(($crc -shr 8),($crc -band 255))
        $metadata=[byte[]]::new(34)
        $metadata[1]=32; $metadata[3]=32
        $packed=([long]48000 -shl 44) -bor ([long]1 -shl 41) -bor ([long]15 -shl 36) -bor 32L
        for ($i=0;$i -lt 8;$i++) { $metadata[10+$i]=[byte](($packed -shr (56-8*$i)) -band 255) }
        $file=Join-Path $Directory "vector-$($spec.name).flac"
        [IO.File]::WriteAllBytes($file,([byte[]]@(0x66,0x4c,0x61,0x43,0x80,0,0,34)+$metadata+$frame))
        $paths.Add($file)
    }
    return $paths.ToArray()
}
