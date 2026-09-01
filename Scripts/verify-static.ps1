$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

$required = @(
    'CodexTouchBar.xcodeproj/project.pbxproj',
    'Packages/CodexTouchCore/Package.swift',
    'Packages/CodexTouchCore/Sources/Integration/AppServerClient.swift',
    'Packages/CodexTouchCore/Sources/Integration/StableProtocolAdapter.swift',
    'Packages/CodexTouchCore/Sources/Infrastructure/ProfileRegistry.swift',
    'App/TouchBarProvider.swift',
    'README.md',
    'Config/profile.example.json'
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $path" }
}
$null = [xml](Get-Content -Raw -LiteralPath 'App/Info.plist')
$null = [xml](Get-Content -Raw -LiteralPath 'App/CodexTouchBar.entitlements')

$projectText = Get-Content -Raw -LiteralPath 'CodexTouchBar.xcodeproj/project.pbxproj'
foreach ($sourceName in @('AppDelegate.swift','MenuBarController.swift','TouchBarProvider.swift','TouchBarController.swift','PreferencesWindowController.swift')) {
    if (-not $projectText.Contains("$sourceName in Sources")) { throw "App source is not wired into the Xcode target: $sourceName" }
}
foreach ($projectMarker in @(
    'productType = "com.apple.product-type.application"',
    'relativePath = Packages/CodexTouchCore',
    'CodexTouchCore in Frameworks',
    'CODE_SIGN_ENTITLEMENTS = App/CodexTouchBar.entitlements',
    'INFOPLIST_FILE = App/Info.plist',
    'MACOSX_DEPLOYMENT_TARGET = 12.0',
    'SWIFT_VERSION = 5.0'
)) {
    if (-not $projectText.Contains($projectMarker)) { throw "Xcode project wiring marker missing: $projectMarker" }
}
if ($projectText.Contains('SWIFT_VERSION = 5.10')) {
    throw 'Xcode SWIFT_VERSION is a language mode and must not be set to compiler release 5.10.'
}

$swiftFiles = @(Get-ChildItem -Path 'App','Packages' -Recurse -Filter '*.swift' -File)
$swiftText = ($swiftFiles | Get-Content -Raw) -join "`n"
foreach ($forbidden in @('DFRFoundation', '_NSTouchBar', 'dlopen(', 'NSClassFromString', 'Process.launchPath', '/bin/sh', 'auth.json', 'accessToken', 'apiKey')) {
    if ($swiftText.Contains($forbidden)) { throw "Forbidden implementation marker found: $forbidden" }
}
if (-not $swiftText.Contains('process.arguments = arguments') -or -not $swiftText.Contains('process.arguments = ["login"]')) {
    throw 'Expected argument-array Process launches were not found.'
}
if (-not $swiftText.Contains('childEnvironment["CODEX_HOME"] = codexHome.path')) {
    throw 'CODEX_HOME isolation assignment is missing.'
}
foreach ($requiredMarker in @('options: .atomic', 'readback', 'posixPermissions')) {
    if (-not $swiftText.Contains($requiredMarker)) { throw "Write-safety marker missing: $requiredMarker" }
}
foreach ($method in @('initialize', 'initialized', 'account/read', 'account/rateLimits/read', 'account/usage/read', 'model/list', 'config/read', 'config/batchWrite', 'turn/start')) {
    if (-not $swiftText.Contains($method)) { throw "Expected protocol method missing: $method" }
}
foreach ($requiredMarker in @(
    'public let jsonrpc: String?',
    'static let status = NSTouchBarItem.Identifier',
    '#selector(nextEffort)',
    'UTC (assumed; API omits timezone)',
    'rateLimitsByLimitId?["codex"]',
    'processGeneration',
    'intentionallyStopped',
    'applyRefresh',
    'beginAccountSwitch',
    'writeError',
    'childEnvironment.removeValue(forKey: key)',
    'environment.removeValue(forKey: key)'
)) {
    if (-not $swiftText.Contains($requiredMarker)) { throw "Required behavior marker missing: $requiredMarker" }
}

$fixtureFiles = Get-ChildItem -Path 'Tests/Fixtures/AppServer' -Filter '*.json' -File
if ($fixtureFiles.Count -lt 7) { throw 'Expected redacted app-server fixtures are missing.' }
foreach ($fixture in $fixtureFiles) {
    $null = Get-Content -Raw -LiteralPath $fixture.FullName | ConvertFrom-Json
}
$rateFixture = Get-Content -Raw -LiteralPath 'Tests/Fixtures/AppServer/rate-limits.json' | ConvertFrom-Json
if ($rateFixture.rateLimits.primary.windowDurationMins -ne 300 -or $rateFixture.rateLimits.secondary.windowDurationMins -ne 10080) {
    throw 'Rate-limit fixture does not contain the required 5h/7d windows.'
}
$modelFixture = Get-Content -Raw -LiteralPath 'Tests/Fixtures/AppServer/models.json' | ConvertFrom-Json
if (-not $modelFixture.data[0].supportedReasoningEfforts) { throw 'Model fixture has no dynamic effort list.' }
$fixtureText = ($fixtureFiles | Get-Content -Raw) -join "`n"
foreach ($forbidden in @('accessToken', 'refreshToken', 'apiKey', 'secret', 'password')) {
    if ($fixtureText.Contains($forbidden)) { throw "Credential-like fixture field found: $forbidden" }
}

$profileExample = Get-Content -Raw -LiteralPath 'Config/profile.example.json' | ConvertFrom-Json
if ($profileExample.oneTouchEnabled -ne $false) { throw 'Sample profile configuration must default one-touch switching off.' }
if (-not $profileExample.profiles) { throw 'Sample profile configuration has no profiles.' }

Write-Output ("Static verification passed: {0} Swift files, {1} fixtures." -f $swiftFiles.Count, $fixtureFiles.Count)
