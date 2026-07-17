$ErrorActionPreference = 'Stop'
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $compiler)) {
    $compiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $compiler)) {
    throw 'The .NET Framework C# compiler was not found.'
}

$gac = "$env:WINDIR\Microsoft.NET\assembly"
$presentationCore = Get-ChildItem "$gac\GAC_64\PresentationCore" -Recurse -Filter PresentationCore.dll | Select-Object -First 1 -ExpandProperty FullName
$presentationFramework = Get-ChildItem "$gac\GAC_MSIL\PresentationFramework" -Recurse -Filter PresentationFramework.dll | Select-Object -First 1 -ExpandProperty FullName
$windowsBase = Get-ChildItem "$gac\GAC_MSIL\WindowsBase" -Recurse -Filter WindowsBase.dll | Select-Object -First 1 -ExpandProperty FullName
$systemXaml = Get-ChildItem "$gac\GAC_MSIL\System.Xaml" -Recurse -Filter System.Xaml.dll | Select-Object -First 1 -ExpandProperty FullName
if (-not $presentationCore -or -not $presentationFramework -or -not $windowsBase -or -not $systemXaml) {
    throw 'The Windows WPF framework assemblies were not found.'
}

& $compiler /nologo /target:winexe /optimize+ /platform:x64 `
    /out:ClockWidget.exe `
    "/reference:$presentationCore" `
    "/reference:$presentationFramework" `
    "/reference:$windowsBase" `
    "/reference:$systemXaml" `
    /reference:System.dll `
    /reference:System.Core.dll `
    ClockWidget.cs

if ($LASTEXITCODE -ne 0) { throw "Compilation failed with exit code $LASTEXITCODE." }
Write-Output "Built $((Resolve-Path .\ClockWidget.exe).Path)"
