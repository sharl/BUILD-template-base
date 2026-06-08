# -*- coding: utf-8 -*-
$updateFlag = $true

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

# install modules if updated
python -m pip install -U -r .\requirements.txt pip pyinstaller

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

$analyzeFlag = $false
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

# build
try {
    pyinstaller "$appName.py" @myArgs
}
finally {
}

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
