param([int]$Seconds = 10)
$clock = [Diagnostics.Stopwatch]::StartNew()
$value = 1.0
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    for ($i=0; $i -lt 50000; $i++) { $value=[Math]::Sqrt($value+1.23456789) }
}
