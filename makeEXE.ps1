# -*- coding: utf-8 -*-
$updateFlag = $true
$analyzeFlag = $false

$OutputEncoding = [System.Text.Encoding]::UTF8

function Sync-Templates {
    param (
        [string[]]$ExcludeModules,
        [string[]]$AddDataArgs,
        [string]$AppName,
        [string]$VCmd
    )

    # YAML template transformation
    $templatePath = "../build.yaml"
    $yamlPath = ".github\workflows\build.yaml"

    if (Test-Path $templatePath) {
        $allYamlArgs = @()
        if ($ExcludeModules) { $allYamlArgs += $ExcludeModules | Select-Object -Unique }
        if ($AddDataArgs)    { $allYamlArgs += $AddDataArgs | Select-Object -Unique }

        $yamlLinesStr = ($allYamlArgs | ForEach-Object { "`"$_`" ``" }) -join "`n            "
        $yamlLinesStr = $yamlLinesStr.TrimEnd(" ``")

        $yamlContent = Get-Content -Path $templatePath -Raw
        $newYaml = $yamlContent -replace '__yaml_args__', $yamlLinesStr

        $targetDir = Split-Path -Path $yamlPath -Parent
        if (-not (Test-Path $targetDir)) {
            $null = New-Item -ItemType Directory -Path $targetDir -Force
        }
        Set-Content -Path $yamlPath -Value $newYaml -NoNewline
    }

    # README.md template transformation
    $readmeTemplatePath = "../README.md"
    $readmePath = "README.md"

    if ((Test-Path $readmeTemplatePath) -and (-not (Test-Path $readmePath))) {
        $readmeContent = Get-Content -Path $readmeTemplatePath -Raw

        $newReadme = $readmeContent -replace '__name__', $AppName
        $newReadme = $newReadme -replace '__pyinstaller__cmd__', $VCmd

        Set-Content -Path $readmePath -Value $newReadme -NoNewline
    }
}

# get application name from current directory name
$pwd = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$appName = Split-Path -Path $pwd -Leaf


# ==============================================================================
# PyInstaller Bootloader 完全隔離型自動ビルドスクリプト
# ==============================================================================

# 1. 一時作業空間の定義（OneDriveの干渉を100%遮断）
$tmpWorkspace = Join-Path $env:TEMP "pyinstaller_build_workspace"
$zipFile = Join-Path $tmpWorkspace "pyinstaller-develop.zip"
$extractedDir = Join-Path $tmpWorkspace "pyinstaller-develop"

Write-Host "--- Step 1: Cleaning and Creating Isolated Workspace ---"
if (Test-Path $tmpWorkspace) { Remove-Item -Recurse -Force $tmpWorkspace }
New-Item -ItemType Directory -Path $tmpWorkspace -Force > $null
Write-Host "Workspace prepared at: $tmpWorkspace"


# 2. $env:TEMP 内へ PyPI から最新安定版のソースをダウンロードして展開
Write-Host "`n--- Step 2: Downloading PyInstaller Stable Source from PyPI ---"

# PyPIの公式APIから PyInstaller のリリース情報を取得
$pypiApiUrl = "https://pypi.org/pypi/pyinstaller/json"
Write-Host "Fetching package metadata from PyPI API..."
$pypiData = Invoke-RestMethod -Uri $pypiApiUrl

# 最新バージョン名（例: "6.21.0"）を動的に特定
$stableVer = $pypiData.info.version
Write-Host "Latest stable version identified: $stableVer"

# リリースファイル一覧から、拡張子が .tar.gz のものを抽出
$sdistFile = $pypiData.urls | Where-Object { $_.filename -like "*$stableVer.tar.gz" } | Select-Object -First 1

if (-not $sdistFile) {
    Write-Error "Could not find .tar.gz archive for version $stableVer on PyPI."
    return
}

$downloadUrl = $sdistFile.url
$targetTarGz = Join-Path $tmpWorkspace $sdistFile.filename

Write-Host "Downloading stable source archive directly..."
Write-Host "URL: $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $targetTarGz

Write-Host "Extracting stable source..."
# tar.exe を捨てて、Pythonの標準ライブラリ（tarfile）で安全に展開
python -c "import tarfile; tarfile.open(r'$targetTarGz').extractall(r'$tmpWorkspace')"
Remove-Item $targetTarGz

# 展開されたフォルダ（例: pyinstaller-6.21.0）を動的に捕捉
$extractedDir = Get-ChildItem $tmpWorkspace -Directory | Select-Object -First 1 | ForEach-Object { $_.FullName }
Write-Host "Source directory prepared at: $extractedDir"


# 3. インストールされている最新の Visual Studio を自動探索
Write-Host "`n--- Step 3: Auto-detecting MSVC from Host System ---"
$vsBaseDir = "C:\Program Files (x86)\Microsoft Visual Studio"
$vcvarsPath = $null

if (Test-Path $vsBaseDir) {
    # 18(2026) などのメジャーバージョン階層を自動ガサ入れ
    $foundBat = Get-ChildItem -Path "$vsBaseDir\*\*\VC\Auxiliary\Build\vcvars64.bat" -ErrorAction SilentlyContinue | 
                 Sort-Object LastWriteTime -Descending | 
                 Select-Object -First 1

    if ($foundBat) { $vcvarsPath = $foundBat.FullName }
}

if (-not $vcvarsPath) {
    Write-Error "vcvars64.bat not found."
    return
}
Write-Host "Auto-detected vcvars64.bat: $vcvarsPath"

# 2026内部に居候している v143 (VS2022ツールセット) の具体的なバージョンを特定
$msvcToolsPath = Join-Path (Split-Path (Split-Path (Split-Path $vcvarsPath))) "Tools\MSVC"
$vcvarsVer = ""

if (Test-Path $msvcToolsPath) {
    $targetVersionDir = Get-ChildItem $msvcToolsPath -Directory | 
                         Where-Object { $_.Name -like "14.4*" } | 
                         Sort-Object Name -Descending | 
                         Select-Object -First 1
                         
    if ($targetVersionDir) { $vcvarsVer = $targetVersionDir.Name }
}

if (-not $vcvarsVer) {
    Write-Error "Compatible MSVC Toolset (14.4x) folder not found."
    return
}
Write-Host "Found compatible MSVC Toolset Version: $vcvarsVer"

# 4. TEMP内で waf ビルドを執行
Write-Host "`n--- Step 4: Building Bootloader Inside TEMP ---"
pushd "$extractedDir\bootloader"

# 実在するコンパイラの絶対パスを組み立てる
$vsInstallDir = Split-Path (Split-Path (Split-Path (Split-Path $vcvarsPath)))
$msvcBinPath = "$vsInstallDir\VC\Tools\MSVC\$vcvarsVer\bin\Hostx64\x64"

if (Test-Path $msvcBinPath) {
    Write-Host "Forcing waf to use specific MSVC compiler by overriding CC/CXX environment variables..."
    
    # 1. PATH の先頭にネジ込む
    $env:PATH = "$msvcBinPath;" + $env:PATH
    
    # 2. 【本命】wafの自動検出をバイパスして、cl.exe の実体を直接指す
    $env:CC  = "$msvcBinPath\cl.exe"
    $env:CXX = "$msvcBinPath\cl.exe"
} else {
    Write-Error "MSVC Compiler executable path not found at: $msvcBinPath"
    popd
    return
}

Write-Host "Configuring and building bootloader inside $env:TEMP..."
# 自動検出を無効化（スルー）させるため、--msvc_targets オプションは外してシンプルに叩く！
python waf configure build install

# 終わったら次のために環境変数を綺麗にしておく
Remove-Item Env:\CC -ErrorAction SilentlyContinue
Remove-Item Env:\CXX -ErrorAction SilentlyContinue

popd

# 5. 最後の仕上げ: ローカルの仮想環境（.venv）にインストール
Write-Host "`n--- Step 5: Finalizing PyInstaller installation to local .venv ---"
pushd $extractedDir

# これで、今MSVCで焼き上げた安定版ブートローダーを含んだ「公式Stable版PyInstaller」が配備されます！
pip install .

popd

# 綺麗に後片付け
Remove-Item -Recurse -Force $tmpWorkspace
Write-Host "`n=== Process Completed Successfully! ==="

# ==============================================================================

# install modules if updated
python -m pip install -U -r .\requirements.txt pip

# select resource_path Assets
$detectedAssets = Get-ChildItem -Filter *.py | Get-Content | ForEach-Object {
    if ($_ -match 'resource_path\s*\(\s*[''"](.+?)[''"]\s*\)') {
        $path = $Matches[1]
        if ($path -match '/|\\') {
            $dest = Split-Path $path -Parent
            "--add-data=${path};${dest}"
        } else {
            "--add-data=${path};."
        }
    }
} | Select-Object -Unique
# build args
$myArgs = @(
    "--onefile",
    "--noconsole",
    "--icon=Assets/sample.ico",

    "--exclude-module=PIL._avif",
    "--exclude-module=PIL._webp",
    "--exclude-module=PIL._imagingcms"
) + $detectedAssets

# verbose
$quotedArgs = foreach ($arg in $myArgs) {
    "`"$($arg.ToString())`""
}
$vCmd = "pyinstaller `"$appName.py`" " + ($quotedArgs -join " ")
Write-Host $vCmd -ForegroundColor Yellow

# templates transformations
$onlyExcludes = $myArgs | Where-Object { $_ -like "--exclude-module=*" }
$onlyAddData  = $myArgs | Where-Object { $_ -like "--add-data=*" }
Sync-Templates -ExcludeModules $onlyExcludes -AddDataArgs $onlyAddData -AppName $appName -VCmd $vCmd

exit

if ($analyzeFlag) {
    Invoke-Expression $vCmd.Replace("onefile", "onedir")

    Get-ChildItem -Path .\dist\ -Filter *.py* -Recurse | Sort-Object Length -Descending |
      Select-Object Name, @{
          Name="Size(MB)"
          Expression={
              [math]::round($_.Length / 1MB, 2)
          }
      } -First 20

    # cleanup
    Remove-Item -Path dist -Recurse -Force -ErrorAction SilentlyContinue
    exit
}

# ======================================================================

# build
try {
    pyinstaller "$appName.py" @myArgs
}
finally {
}

# ======================================================================

# update startup
if ($updateFlag) {
    # kill current process
    Stop-Process -Name $appName -Force -ErrorAction SilentlyContinue

    # copy to startup
    Start-Sleep -Seconds 3
    $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    Copy-Item -Path ".\dist\$appName.exe" -Destination $startupFolder -Force

    # start new process
    Start-Process "$startupFolder\$appName.exe"
}

# cleanup
if ($updateFlag) {
    Start-Sleep -Seconds 3
    Remove-Item -Path build, dist, *.spec -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Remove-Item -Path build, *.spec -Recurse -Force -ErrorAction SilentlyContinue
}

# uninstall non requirements modules

# read modules in requirements.txt
$reqModules = Get-Content .\requirements.txt
# list up installed modules
$allModules = python -m pip list --format=json | ConvertFrom-Json | Select-Object -ExpandProperty name

$keepModules = $reqModules + @("pip")
$targetModules = $allModules | Where-Object { $_ -notin $keepModules }

if ($targetModules) {
    python -m pip uninstall -y $targetModules > $null
}

# compare
$req = (Get-Content .\requirements.txt) + 'pip'
$pip = (python -m pip list --format=json | ConvertFrom-Json).name

Compare-Object $req $pip -IncludeEqual | Sort-Object InputObject | ForEach-Object {
    if ($_.SideIndicator -eq '=>') {
        "+$($_.InputObject)"
    } elseif ($_.SideIndicator -eq '<=') {
        "-$($_.InputObject)"
    }
}
