param(
    [Parameter(Mandatory = $true)][string]$PythonForBuild,
    [Parameter(Mandatory = $true)][string]$Dotnet,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$CacheDirectory,
    [string]$Version = '0.6.0-preview.1',
    [switch]$SkipArchive
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Build the Windows bundle on Windows x64.' }
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Version must be a semantic version without path separators.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$python = (Get-Command $PythonForBuild -ErrorAction Stop).Source
$dotnetExe = (Get-Command $Dotnet -ErrorAction Stop).Source
if ((Test-Path $output) -and @(Get-ChildItem -Force $output).Count -gt 0) {
    throw 'OutputDirectory must be new or empty; never overwrite an existing installation.'
}
New-Item -ItemType Directory -Force $output, $cache | Out-Null
$work = Join-Path $cache ('build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$inputs = Get-Content -Raw (Join-Path $PSScriptRoot 'inputs.json') | ConvertFrom-Json
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
function Get-VerifiedInput($item) {
    $path = Join-Path $cache $item.filename
    if ((Test-Path $path) -and ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $item.sha256)) { return $path }
    $temporary = $path + '.download-' + [Guid]::NewGuid().ToString('N')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $item.url -OutFile $temporary -TimeoutSec 600
        if ((Get-FileHash $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) { throw "Hash mismatch: $($item.filename)" }
        Move-Item -Force $temporary $path
    } finally { if (Test-Path $temporary) { Remove-Item $temporary -Force } }
    return $path
}

# Use a separate build interpreter. End users receive no pip bootstrap step.
Invoke-Checked $python @('-c', 'import struct,sys; assert sys.version_info[:2]==(3,11) and struct.calcsize("P")==8, "Use CPython 3.11 x64 for packaging"')
$pythonArchive = Get-VerifiedInput $inputs.python
$llamaArchive = Get-VerifiedInput $inputs.llama
$vcRedist = Get-VerifiedInput $inputs.vc_redist
$signature = Get-AuthenticodeSignature $vcRedist
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'The Microsoft runtime installer signature is invalid.' }
foreach ($license in $inputs.licenses) { Get-VerifiedInput $license | Out-Null }
$helper = Join-Path $PSScriptRoot 'bundle.py'
Invoke-Checked $python @('-B', $helper, 'prepare', '--root', $output, '--repo', $repo, '--cache', $cache, '--work', $work)
$wheels = Join-Path $work 'wheels'
$requirements = Join-Path $repo 'backend\requirements-windows.txt'
Invoke-Checked $python @('-m', 'pip', 'download', '--disable-pip-version-check', '--only-binary=:all:', '--dest', $wheels, '-r', $requirements)
Invoke-Checked $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-index', '--find-links', $wheels, '--only-binary=:all:', '--no-compile', '--target', (Join-Path $output 'runtime\python\Lib\site-packages'), '-r', $requirements)

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
Invoke-Checked $dotnetExe @('publish', (Join-Path $repo 'windows\app\LocalDictation.csproj'), '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', ('-p:Version=' + $Version), '-p:PublishSingleFile=false', '-p:DebugType=None', '-p:DebugSymbols=false', '-o', $output)
Invoke-Checked $python @('-B', $helper, 'finish', '--root', $output, '--repo', $repo, '--cache', $cache, '--work', $work, '--version', $Version)
$runtime = Join-Path $output 'runtime\python\python.exe'
Invoke-Checked $runtime @('-B', (Join-Path $PSScriptRoot 'validate_bundle.py'), $output, '--runtime-check')
$selfTest = Join-Path $work 'native-self-test.json'
$process = Start-Process -FilePath (Join-Path $output 'LocalDictation.exe') -ArgumentList @('--self-test', '--result-file', ('"' + $selfTest + '"')) -PassThru -Wait
if ($process.ExitCode -ne 0 -or -not (Test-Path $selfTest)) { throw 'Packaged application self-test failed.' }
if (-not (Get-Content -Raw $selfTest | ConvertFrom-Json).success) { throw 'Packaged application reported a failed self-test.' }
if (-not $SkipArchive) {
    Invoke-Checked $python @('-B', $helper, 'archive', '--root', $output, '--version', $Version)
}
Write-Output "Validated Windows bundle: $output"
Write-Output "Build evidence: $work"
