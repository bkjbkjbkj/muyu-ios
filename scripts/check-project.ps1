$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pbx = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'Muyu.xcodeproj/project.pbxproj'))
$sources = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Muyu') -Filter '*.swift')
foreach ($source in $sources) {
    if (!$pbx.Contains("path = $($source.Name);")) { throw "Missing Xcode file reference: $($source.Name)" }
}
$definitions = @([regex]::Matches($pbx, '(?m)^([0-9A-F]{24}) = ') | ForEach-Object {$_.Groups[1].Value})
if (@($definitions | Select-Object -Unique).Count -ne $definitions.Count) { throw 'Duplicate project object IDs' }
foreach ($reference in [regex]::Matches($pbx, '[0-9A-F]{24}')) {
    if ($reference.Value -notin $definitions) { throw "Undefined project object: $($reference.Value)" }
}
foreach ($file in @('Muyu/Info.plist','Muyu/PrivacyInfo.xcprivacy','Muyu.xcodeproj/xcshareddata/xcschemes/Muyu.xcscheme')) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.Load((Join-Path $projectRoot $file))
    if (!$xml.DocumentElement) { throw "Invalid XML: $file" }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Muyu/Assets.xcassets') -Filter '*.json' -Recurse) {
    $null = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
}
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile((Join-Path $projectRoot 'Muyu/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))
try {
    if ($image.Width -ne 1024 -or $image.Height -ne 1024) { throw 'Icon must be 1024px' }
    if ([System.Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat)) { throw 'App icon must be opaque' }
} finally { $image.Dispose() }
$workflow = [System.IO.File]::ReadAllText((Join-Path $projectRoot '.github/workflows/ios.yml'))
foreach ($required in @('workflow_dispatch:', 'macos-15', 'CoreChecks.swift', 'actions/upload-artifact@v4', 'build/Muyu-unsigned.ipa')) {
    if (!$workflow.Contains($required)) { throw "Missing workflow setting: $required" }
}
foreach ($required in @('CODE_SIGNING_ALLOWED = NO;', 'CODE_SIGNING_REQUIRED = NO;', 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;')) {
    if (!$pbx.Contains($required)) { throw "Missing build setting: $required" }
}
Write-Output "PASS: $($sources.Count) Swift source references, project IDs, plist XML, asset JSON, opaque app icon, cloud workflow and unsigned build settings."
Write-Output 'Swift type checking, core execution and iPhone compilation require the macOS workflow.'
