# Rebuild SuApp.apk (aapt2 + javac + d8 + zipalign + apksigner).
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$apk = Join-Path $work 'apk'
$bt = Join-Path $work 'sdk\bt\android-13'
$jar = Join-Path $work 'sdk\plat\android-12\android.jar'
$javac = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot\bin\javac.exe'
$java = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot\bin\java.exe'
$env:JAVA_HOME = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot'

Push-Location $apk
try {
    Remove-Item -Recurse -Force classes, dex, app.unsigned.apk, app.aligned.apk -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path classes, dex | Out-Null

    & "$bt\aapt2.exe" link -o app.unsigned.apk -I $jar --manifest AndroidManifest.xml
    if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

    $src = Get-ChildItem -Recurse src -Filter *.java | ForEach-Object { $_.FullName }
    & $javac -source 8 -target 8 -Xlint:-options -bootclasspath $jar -d classes $src
    if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

    $cls = Get-ChildItem -Recurse classes -Filter *.class | ForEach-Object { $_.FullName }
    & $java -Xmx1024M -cp "$bt\lib\d8.jar" com.android.tools.r8.D8 --lib $jar --min-api 21 --output dex $cls
    if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

    Push-Location dex
    & "$bt\aapt.exe" add ..\app.unsigned.apk classes.dex
    if ($LASTEXITCODE -ne 0) { throw 'aapt add failed' }
    Pop-Location

    & "$bt\zipalign.exe" -f 4 app.unsigned.apk app.aligned.apk
    if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }

    & "$bt\apksigner.bat" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android --out SuApp.apk app.aligned.apk
    if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

    Write-Host ("SuApp.apk " + (Get-Item SuApp.apk).Length + " bytes")
} finally {
    Pop-Location
}
