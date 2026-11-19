Param(
    [string] $srcDirectory, # the path that contains the mod project folder (repo root)
    [string] $sdkPath,      # the path to the SDK, ending in "XCOM 2 War of the Chosen SDK"
    [string] $gamePath,     # the path to the game, ending in "XCom2-WarOfTheChosen"
    [string] $config        # build configuration: default | debug
)

$ScriptDirectory = Split-Path $MyInvocation.MyCommand.Path
$common = Join-Path -Path $ScriptDirectory "X2ModBuildCommon\build_common.ps1"
Write-Host "Sourcing $common"
. ($common)

# --- Resolve SDK and game paths ---------------------------------------------------------------
# ModBuddy passes paths derived from XCOM2_UserPath/XCOM2_GamePath; when those are unset it passes
# a folder next to the project instead. Validate what we got and fall back to the Steam libraries.

function Test-SdkPath([string] $p) {
    return -not [string]::IsNullOrEmpty($p) -and (Test-Path (Join-Path $p "Binaries\Win64\XComGame.com"))
}
function Test-GamePath([string] $p) {
    return -not [string]::IsNullOrEmpty($p) -and (Test-Path (Join-Path $p "Binaries\Win64\XCom2.exe"))
}
function Get-SteamLibraries() {
    $libs = @()
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches) {
                $libs += $m.Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    return $libs | Select-Object -Unique
}

if (!(Test-SdkPath $sdkPath) -or !(Test-GamePath $gamePath)) {
    Write-Host "SDK/game path not usable (sdk='$sdkPath', game='$gamePath'); searching Steam libraries..."
    foreach ($lib in Get-SteamLibraries) {
        $candidateSdk = Join-Path $lib "steamapps\common\XCOM 2 War of the Chosen SDK"
        $candidateGame = Join-Path $lib "steamapps\common\XCOM 2\XCom2-WarOfTheChosen"
        if (!(Test-SdkPath $sdkPath) -and (Test-SdkPath $candidateSdk)) { $sdkPath = $candidateSdk }
        if (!(Test-GamePath $gamePath) -and (Test-GamePath $candidateGame)) { $gamePath = $candidateGame }
    }
    if (!(Test-SdkPath $sdkPath)) { ThrowFailure "Could not find the XCOM 2 War of the Chosen SDK. Install it from Steam (Library > Tools)." }
    if (!(Test-GamePath $gamePath)) { ThrowFailure "Could not find XCOM 2 War of the Chosen. Pass -gamePath explicitly." }
    Write-Host "Using sdk='$sdkPath', game='$gamePath'"
}

$builder = [BuildProject]::new("XComCoop", $srcDirectory, $sdkPath, $gamePath)

# --- Highlander source ------------------------------------------------------------------------
# Compile against the Highlander's version of the base game packages.
# Override with X2_HIGHLANDER_SRC; otherwise use the Workshop copy in the same Steam library as the game
# (<steamapps>\common\XCOM 2\XCom2-WarOfTheChosen -> <steamapps>\workshop\content\268500\1134256495\Src).
$highlanderSrc = $env:X2_HIGHLANDER_SRC
if ([string]::IsNullOrEmpty($highlanderSrc)) {
    $steamapps = Split-Path (Split-Path (Split-Path $gamePath -Parent) -Parent) -Parent
    $highlanderSrc = Join-Path $steamapps "workshop\content\268500\1134256495\Src"
}
if (!(Test-Path $highlanderSrc)) {
    ThrowFailure "Highlander source not found at $highlanderSrc. Subscribe to X2WOTCCommunityHighlander on the Workshop or set X2_HIGHLANDER_SRC."
}
$builder.IncludeSrc($highlanderSrc)

switch ($config)
{
    "debug" {
        $builder.EnableDebug()
    }
    "default" {
        # Nothing special
    }
    "" { ThrowFailure "Missing build configuration" }
    default { ThrowFailure "Unknown build configuration $config" }
}

$builder.InvokeBuild()
