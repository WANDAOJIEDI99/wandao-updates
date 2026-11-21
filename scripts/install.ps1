# WandaoHermes installer (Wandao custom, 2026-11-18)
# Contract expected by shell bootstrap-runner:
#   install.ps1 -Manifest [-Commit sha] [-Branch name]
#       -> prints the stages JSON as the LAST line: {"stages":[{name,title,category,needs_user_input},...]}
#   install.ps1 -Stage <name> -NonInteractive -Json [-Commit sha] [-Branch name]
#       -> prints exactly one JSON line: {"ok":true,"stage":"<name>","detail":"..."}
# Sources are OUR public release channel repo, with raw -> jsDelivr -> ghproxy fallback.
param(
  [switch]$Manifest,
  [string]$Stage = '',
  [switch]$NonInteractive,
  [switch]$Json,
  [string]$Commit = '',
  [string]$Branch = ''
)

$ErrorActionPreference = 'Stop'

# 强制 UTF-8 输出（PS 5.1 默认按 GBK 写管道，中文阶段标题会变乱码）
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
# PS 5.1 默认可能用 TLS1.0，下载 GitHub Release 大文件会失败
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Repo = if ($env:WANDAO_INSTALL_REPO) { $env:WANDAO_INSTALL_REPO } else { 'WANDAOJIEDI99/wandao-updates' }
$Ref = if ($Branch) { $Branch } elseif ($env:WANDAO_INSTALL_REF) { $env:WANDAO_INSTALL_REF } else { 'main' }
$InstallDir = if ($env:WANDAO_INSTALL_DIR) { $env:WANDAO_INSTALL_DIR } else { 'D:\WandaoHermes' }
$BaseSources = @(
  "https://raw.githubusercontent.com/$Repo/$Ref",
  "https://cdn.jsdelivr.net/gh/$Repo@$Ref",
  "https://ghproxy.net/https://raw.githubusercontent.com/$Repo/$Ref"
)

function Write-Log([string]$message) {
  if (-not $Json) { Write-Host "[wandao] $message" }
}

function Emit([string]$stageName, [bool]$ok, [string]$detail) {
  $obj = [ordered]@{ ok = $ok; stage = $stageName; detail = $detail }
  # 必须直写控制台：Write-Output 会被 `$code = Invoke-Stage ...` 捕获，阶段就什么都不打印了
  [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
}

function Get-RemoteFile([string]$relPath, [string]$outFile) {
  $errors = @()
  foreach ($base in $BaseSources) {
    $url = "$base/$relPath"
    try {
      Write-Log "GET $url"
      Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec 900
      if ((Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) { return $url }
      $errors += "$url -> empty body"
    } catch {
      $errors += "$url -> $($_.Exception.Message)"
    }
  }
  throw ("download failed for $relPath`n" + ($errors -join "`n"))
}

function Get-Payload {
  $payloadFile = Join-Path $env:TEMP 'wandao-payload.json'
  if (Test-Path $payloadFile) { Remove-Item $payloadFile -Force }
  $payloadUrl = if ($env:WANDAO_PAYLOAD_URL) { $env:WANDAO_PAYLOAD_URL } else { '' }
  if ($payloadUrl) {
    Write-Log "payload override $payloadUrl"
    Invoke-WebRequest -Uri $payloadUrl -OutFile $payloadFile -UseBasicParsing -TimeoutSec 120
  } else {
    Get-RemoteFile 'scripts/payload.json' $payloadFile | Out-Null
  }
  return (Get-Content $payloadFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Find-LocalPackage($payload) {
  # 依次在这些位置找 WandaoHermes-kernel-*.7z，sha256 对得上才算数
  $dirs = @()
  if ($env:WANDAO_LOCAL_PKG) {
    if (Test-Path $env:WANDAO_LOCAL_PKG) { return $env:WANDAO_LOCAL_PKG }
  }
  $dirs += @(
    (Join-Path $env:USERPROFILE 'Downloads'),
    'D:\WandaoHermes_share_build',
    'D:\WandaoHermes',
    'C:\WandaoHermes_share_build',
    $env:TEMP
  )
  foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { continue }
    $files = Get-ChildItem -Path $d -Filter 'WandaoHermes-kernel-*.7z' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
      if ($payload.bytes -and $f.Length -ne [int64]$payload.bytes) { continue }
      if ($payload.sha256) {
        try {
          $h = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
          if ($h -ne $payload.sha256.ToLower()) { continue }
        } catch { continue }
      }
      return $f.FullName
    }
  }
  return $null
}

function Get-SevenZip {
  $candidates = @(
    'D:\7-Zip\7z.exe',
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $onPath = Get-Command 7z.exe -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  # fall back to the standalone console build shipped in our repo
  $sevenZr = Join-Path $env:TEMP 'wandao-7zr.exe'
  if (-not (Test-Path $sevenZr)) { Get-RemoteFile 'scripts/7zr.exe' $sevenZr | Out-Null }
  return $sevenZr
}

$Stages = @(
  [ordered]@{ name = 'prepare';  title = '检查环境与磁盘空间';       category = 'preflight'; needs_user_input = $false },
  [ordered]@{ name = 'download'; title = '下载万道内核';               category = 'download';  needs_user_input = $false },
  [ordered]@{ name = 'extract';  title = '解压到目标目录';           category = 'extract';   needs_user_input = $false },
  [ordered]@{ name = 'finalize'; title = '写入版本信息并完成安装';   category = 'finalize';  needs_user_input = $false }
)

function Invoke-Stage([string]$name) {
  switch ($name) {
    'prepare' {
      $fullTarget = [System.IO.Path]::GetFullPath($InstallDir)
      $root = [System.IO.Path]::GetPathRoot($fullTarget)
      $drive = Get-PSDrive -Name ($root.TrimEnd(':\'))
      $freeGb = [math]::Round($drive.Free / 1GB, 2)
      $payload = Get-Payload
      $needGb = if ($payload.required_bytes) { [math]::Round([double]$payload.required_bytes / 1GB, 2) } else { 12 }
      if ($freeGb -lt $needGb) {
        Emit $name $false "目标盘可用 ${freeGb} GB，需要 ${needGb} GB"
        return 1
      }
      $parentDir = Split-Path -Parent $fullTarget
      if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
      }
      Emit $name $true "可用 ${freeGb} GB / 需要 ${needGb} GB；目标 $fullTarget；版本 $($payload.version)"
      return 0
    }
    'download' {
      $payload = Get-Payload
      $sizeMb = 0
      $ok = $false
      $errors = @()

      # ① 先找本地已下载好的内核包（离线/内网/之前下过一半也算）：
      #    找到且 sha256 对得上就直接用，完全不联网。
      $local = Find-LocalPackage $payload
      if ($local) {
        $target = $local
        $ok = $true
        Write-Log "使用本地安装包 $target"
      }

      # ② 本地没有才联网下载。注意：临时文件名必须每次唯一，
      #    否则上次失败残留的文件被别的进程占用时会永远报"正由另一进程使用"。
      if (-not $ok) {
        $target = Join-Path $env:TEMP ("wandao-" + $payload.version + "-" + [guid]::NewGuid().ToString('N') + ".7z")
        # 顺手清掉旧的固定名残留，避免占用/占空间
        Get-ChildItem -Path $env:TEMP -Filter ("wandao-" + $payload.version + "*.7z") -ErrorAction SilentlyContinue |
          ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
        Write-Log "downloading $($payload.version) -> $target"
        foreach ($url in @($payload.mirrors)) {
          foreach ($attempt in 1..2) {
            try {
              Write-Log "GET $url (try $attempt)"
              if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
              Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -TimeoutSec 3600
              if ((Get-Item $target).Length -gt 0) { $ok = $true; break }
            } catch {
              $errors += "$url -> $($_.Exception.Message)"
            }
          }
          if ($ok) { break }
        }
        if (-not $ok) {
          try { if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue } } catch { }
          Emit $name $false ("全部下载源失败（可把内核 7z 放到下载目录或 D:\\WandaoHermes_share_build 再重试）: " + ($errors -join ' | '))
          return 1
        }
      }
      $sizeMb = [math]::Round((Get-Item $target).Length / 1MB, 1)
      if ($payload.sha256) {
        $actual = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $payload.sha256.ToLower()) {
          Emit $name $false "sha256 不匹配: 期望 $($payload.sha256) 实际 $actual"
          return 1
        }
      }
      $env:WANDAO_PKG_PATH = $target
      Emit $name $true "$target ($sizeMb MB) sha256 ok"
      return 0
    }
    'extract' {
      $pkg = $env:WANDAO_PKG_PATH
      if (-not $pkg) {
        $payload = Get-Payload
        $pkg = Join-Path $env:TEMP ("wandao-" + $payload.version + ".7z")
      }
      if (-not (Test-Path $pkg)) { Emit $name $false "安装包不存在: $pkg"; return 1 }
      $sevenZip = Get-SevenZip
      # 2026-11-19：解压到临时目录再搬进 InstallDir —— 包内顶层可能有 WandaoHermes 外壳目录，
      # 也可能直接是 kernel/tools（无壳），两种都要落到用户选定的安装根。
      $tmpDir = Join-Path $env:TEMP ("wandao-x-" + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
      Write-Log "extract $pkg -> $tmpDir"
      & $sevenZip x $pkg "-o$tmpDir" -y -bsp0 -bso0 | Out-Null
      if ($LASTEXITCODE -ne 0) { Emit $name $false "7z 退出码 $LASTEXITCODE"; return 1 }
      $srcRoot = $tmpDir
      $wrapped = Join-Path $tmpDir 'WandaoHermes'
      if (Test-Path (Join-Path $wrapped 'start-wandao.bat')) { $srcRoot = $wrapped }
      if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
      Write-Log "move $srcRoot\* -> $InstallDir"
      Copy-Item -Path (Join-Path $srcRoot '*') -Destination $InstallDir -Recurse -Force
      Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
      # 启动器位置可能不同：根目录 start-wandao.bat / kernel\start.bat / shell\app\start-wandao-gui.bat
      $launchers = @(
        (Join-Path $InstallDir 'start-wandao.bat'),
        (Join-Path $InstallDir 'kernel\start.bat'),
        (Join-Path $InstallDir 'shell\app\start-wandao-gui.bat')
      )
      $found = $launchers | Where-Object { Test-Path $_ } | Select-Object -First 1
      if (-not $found) {
        Emit $name $false ("解压后没找到启动脚本（查过: " + ($launchers -join ', ') + "）")
        return 1
      }
      Write-Log "launcher: $found"
      # 根目录没有 start-wandao.bat 时，补一个转发脚本，方便双击启动
      $rootBat = Join-Path $InstallDir 'start-wandao.bat'
      if (-not (Test-Path $rootBat)) {
        $kbat = Join-Path $InstallDir 'kernel\start.bat'
        if (Test-Path $kbat) {
          $batLines = @(
            '@echo off',
            'setlocal',
            'set "ROOT=%~dp0"',
            'if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"',
            'set "WANDAO_ROOT=%ROOT%"',
            'set "WANDAO_HOME=%ROOT%\data\_wandao"',
            'set "WANDAO_GW=http://127.0.0.1:42200"',
            'set "WANDAO_SINGLE_SESSION=1"',
            'call "%ROOT%\kernel\start.bat" %*'
          )
          try { Set-Content -Path $rootBat -Value ($batLines -join "`r`n") -Encoding ASCII -Force } catch { }
        }
      }
      Emit $name $true "$InstallDir 已就绪"
      return 0
    }
    'finalize' {
      $payload = Get-Payload
      $stamp = [ordered]@{
        version     = $payload.version
        installedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        source      = $Repo
        installDir  = $InstallDir
      }
      $stampFile = Join-Path $InstallDir 'installed-version.json'
      $stamp | ConvertTo-Json | Set-Content -Path $stampFile -Encoding UTF8
      Emit $name $true "版本 $($payload.version) 已记录到 $stampFile"
      return 0
    }
    default {
      Emit $name $false "未知阶段: $name"
      return 1
    }
  }
}

if ($Manifest) {
  $manifestPayload = [ordered]@{ stages = $Stages }
  Write-Output ($manifestPayload | ConvertTo-Json -Depth 5 -Compress)
  exit 0
}

if ($Stage) {
  $code = Invoke-Stage $Stage
  exit $code
}

# No -Stage and no -Manifest: run the whole thing (manual / debugging use).
$failed = $null
foreach ($s in $Stages) {
  $code = Invoke-Stage $s.name
  if ($code -ne 0) { $failed = $s.name; break }
}
if ($failed) { exit 1 }
Write-Log "安装完成：$InstallDir"
exit 0
