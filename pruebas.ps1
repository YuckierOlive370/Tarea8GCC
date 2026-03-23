# Verificar que H: está montado
net use H: \\192.168.32.3\Homes\smendez /persistent:yes
Get-PSDrive H

# PRUEBA CUOTA: crear archivo de 6MB (debe bloquearse, límite es 5MB)
$buf = New-Object byte[] (6 * 1024 * 1024)
[System.IO.File]::WriteAllBytes("H:\prueba_6mb.dat", $buf)

# PRUEBA FILE SCREENING: intentar guardar un .mp3 (debe bloquearse)
Copy-Item "C:\Windows\System32\notepad.exe" "H:\musica.mp3"