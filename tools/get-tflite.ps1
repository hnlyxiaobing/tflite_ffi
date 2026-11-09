# get-tflite.ps1 — 真实 tensorflowlite_c 获取脚本（2026-11-08；获取链 D2，见 ../docs/DECISIONS.md §2/§3）
#
# 【获取顺序（D2 冻结）】
#   ① 本地探测：MB_TFLITE_LIB_PATH -> .local/tflite/<platform>/ 缓存
#      -> D:\Android\Sdk -> %USERPROFILE%\.gradle\caches（含 org.tensorflow AAR 内
#      的 libtensorflowlite_c.so 提取）
#   ② 官方可验证渠道：仅限官方发布物（Android 各平台走 Google Maven
#      org.tensorflow/tensorflow-lite AAR；win-x64/linux-x64 无官方预编译
#      tensorflowlite_c -> 按冻结规则「无则跳过，禁止第三方构建/镜像」）
#   ③ 官方源码最小构建：tensorflow 官方 tag 钉版、入口
#      tensorflow/lite/c/CMakeLists.txt（target tensorflowlite_c）、MSVC x64
#      + vcvars64/NMake、XNNPACK=OFF（最小构建；限时约 40 分钟由调用方后台
#      任务控制；超时/失败 -> ④）
#   ④ fail-closed：docs/GAPS.md 缺口登记 + 接线完备（dispatch 已支持 stub 唯一运行
#      路径）+ 脚本保留，exit 3
#
# 【接口（冻结）】
#   [-Platform win-x64|linux-x64|android-arm64|android-armv7] [-Version <tag>]
#   [-LibPath <path>] [-TargetDir <dir>] [-Offline] [-VerifyOnly]
#   默认 TargetDir = tflite_ffi/.local/tflite/<platform>/
#   产出：库文件 + SHA256SUMS.txt + PROVENANCE.md（URL/版本/许可/获取日期
#   2026-11-08/构建方式）。
#   退出码：0=就绪 2=参数错 3=fail-closed 未获取（docs/GAPS.md 追加）4=哈希或导出
#   符号校验失败。
#
# 【红线】真实库二进制禁入库：只落 .local/（gitignore）+ SHA-256 记录。

param(
  [ValidateSet("win-x64", "linux-x64", "android-arm64", "android-armv7")]
  [string]$Platform = "win-x64",
  [string]$Version = "v2.14.0",
  [string]$LibPath = "",
  [string]$TargetDir = "",
  [switch]$Offline,
  [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$acquireDate = "2026-11-09"

# ---------------- 参数与目录 ----------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgRoot = Split-Path -Parent $scriptDir
if ($TargetDir -eq "") {
  $TargetDir = Join-Path $pkgRoot ".local\tflite\$Platform"
}
if ($Version -notmatch '^v?\d+\.\d+(\.\d+)?(-[\w.]+)?$') {
  Write-Error "版本标签非法: $Version（期望形如 v2.14.0）"
  exit 2
}
$libName = if ($Platform -eq "win-x64") { "tensorflowlite_c.dll" }
elseif ($Platform -eq "linux-x64") { "libtensorflowlite_c.so" }
else { "libtensorflowlite_c.so" }

$requiredSymbols = @(
  "TfLiteVersion", "TfLiteSchemaVersion", "TfLiteModelCreate", "TfLiteModelDelete",
  "TfLiteInterpreterOptionsCreate", "TfLiteInterpreterOptionsDelete",
  "TfLiteInterpreterOptionsSetNumThreads", "TfLiteInterpreterCreate",
  "TfLiteInterpreterDelete", "TfLiteInterpreterGetInputTensorCount",
  "TfLiteInterpreterGetOutputTensorCount", "TfLiteInterpreterGetInputTensor",
  "TfLiteInterpreterGetOutputTensor", "TfLiteInterpreterResizeInputTensor",
  "TfLiteInterpreterAllocateTensors", "TfLiteInterpreterInvoke",
  "TfLiteTensorType", "TfLiteTensorNumDims", "TfLiteTensorDim",
  "TfLiteTensorByteSize", "TfLiteTensorName", "TfLiteTensorQuantizationParams",
  "TfLiteTensorCopyFromBuffer", "TfLiteTensorCopyToBuffer"
)

# ---------------- 工具函数 ----------------
function Get-Sha256Hex([string]$path) {
  (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

function Test-ExportSymbols([string]$path) {
  # 导出符号存在性校验：必需符号名以 NUL 结尾字节序列出现于映像
  #（PE 导出名表 / ELF dynstr 均为该形态；运行期真导出校验由 dispatch 层
  # GetProcAddress 完成，见 docs/DESIGN.md）。
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $missing = @()
  foreach ($sym in $requiredSymbols) {
    if (-not $text.Contains($sym + [char]0)) {
      $missing += $sym
    }
  }
  ,$missing
}

function Write-Provenance([string]$targetDir, [string]$libFile, [string]$source, [string]$method) {
  $hash = Get-Sha256Hex $libFile
  $name = Split-Path -Leaf $libFile
  $lines = @(
    "# PROVENANCE — $name",
    "",
    "- 文件：$name",
    "- SHA-256：$hash",
    "- 来源 URL/探测：$source",
    "- 版本：$Version",
    "- 许可：Apache-2.0（TensorFlow / LiteRT，见 tensorflow/lite/LICENSE）",
    "- 获取日期：$acquireDate",
    "- 构建方式：$method",
    "- 平台：$Platform",
    "- 校验：SHA-256 + 必需导出符号存在性（$($requiredSymbols.Count) 项）；",
    "  运行期 GetProcAddress 全量解析见 native/mb_tfl_real.c。",
    "- 红线：真实库二进制不入库（仅 .local/ 本地链接 + 本记录）。",
    ""
  )
  [System.IO.File]::WriteAllText((Join-Path $targetDir "PROVENANCE.md"), ($lines -join "`n"), $utf8Bom)
  $sums = "$hash  $name"
  [System.IO.File]::WriteAllText((Join-Path $targetDir "SHA256SUMS.txt"), $sums + "`n", $utf8NoBom)
}

function Register-Gap([string]$detail) {
  $gaps = Join-Path $pkgRoot "docs/GAPS.md"
  $entry = "- [ ] $acquireDate get-tflite($Platform/$Version)：$detail（fail-closed：stub 为唯一运行路径；接线完备，脚本保留）`n"
  if (Test-Path -LiteralPath $gaps) {
    [System.IO.File]::AppendAllText($gaps, $entry, $utf8NoBom)
  } else {
    [System.IO.File]::WriteAllText($gaps, $entry, $utf8NoBom)
  }
}

function Import-MsvcEnv([string]$vcvarsPath) {
  # 把 vcvars64.bat 设置的 PATH/INCLUDE/LIB 导入当前 PowerShell 进程，
  # 使 NMake 生成器能找到 cl.exe/link.exe（VS 2026 不被 CMake 3.31 的
  # "Visual Studio 17 2022" 生成器识别，故用 NMake + vcvars 兜底）。
  $lines = & cmd.exe /c "call `"$vcvarsPath`" >nul 2>&1 && set"
  foreach ($line in $lines) {
    if ($line -match '^([^=]+)=(.*)$') {
      Set-Item -Path ("env:" + $matches[1]) -Value $matches[2]
    }
  }
}

function Install-Lib([string]$srcPath, [string]$source, [string]$method) {
  if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
  }
  $dst = Join-Path $TargetDir $libName
  Copy-Item -LiteralPath $srcPath -Destination $dst -Force
  $missing = Test-ExportSymbols $dst
  if ($missing.Count -gt 0) {
    Write-Output ("fail: 必需导出符号缺失: " + ($missing -join ", "))
    exit 4
  }
  Write-Provenance $TargetDir $dst $source $method
  $hash = Get-Sha256Hex $dst
  Write-Output ("ready: " + $dst)
  Write-Output ("sha256: " + $hash)
  exit 0
}

# ---------------- -VerifyOnly：只校验既有产物 ----------------
if ($VerifyOnly) {
  $candidate = if ($LibPath -ne "") { $LibPath } else { Join-Path $TargetDir $libName }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    Write-Output ("verify: 缺库 " + $candidate)
    exit 3
  }
  $missing = Test-ExportSymbols $candidate
  if ($missing.Count -gt 0) {
    Write-Output ("verify: 导出符号缺失 " + ($missing -join ", "))
    exit 4
  }
  $sumFile = Join-Path (Split-Path -Parent $candidate) "SHA256SUMS.txt"
  $hash = Get-Sha256Hex $candidate
  if (Test-Path -LiteralPath $sumFile) {
    $recorded = (Get-Content -LiteralPath $sumFile -Raw).Trim().Split(" ")[0].ToLower()
    if ($recorded -ne $hash) {
      Write-Output ("verify: SHA-256 不符 recorded=" + $recorded + " actual=" + $hash)
      exit 4
    }
    Write-Output ("verify: sha256 一致 " + $hash)
  } else {
    Write-Output ("verify: 无 SHA256SUMS.txt，仅符号校验通过；sha256=" + $hash)
  }
  exit 0
}

# ---------------- ① 本地探测 ----------------
Write-Output ("probe: 目标 " + $libName + " @ " + $TargetDir)

if ($LibPath -ne "") {
  if (Test-Path -LiteralPath $LibPath -PathType Leaf) {
    Install-Lib $LibPath ("-LibPath 显式指定: " + $LibPath) "本地文件复制"
  } else {
    Write-Error "-LibPath 指向的文件不存在: $LibPath"
    exit 2
  }
}

if ($env:MB_TFLITE_LIB_PATH -and (Test-Path -LiteralPath $env:MB_TFLITE_LIB_PATH -PathType Leaf)) {
  Write-Output ("probe: MB_TFLITE_LIB_PATH -> " + $env:MB_TFLITE_LIB_PATH)
  Install-Lib $env:MB_TFLITE_LIB_PATH ("MB_TFLITE_LIB_PATH: " + $env:MB_TFLITE_LIB_PATH) "本地文件复制"
}

$cached = Join-Path $TargetDir $libName
if (Test-Path -LiteralPath $cached -PathType Leaf) {
  Write-Output ("probe: .local 缓存 -> " + $cached)
  Install-Lib $cached (".local/tflite/<platform> 缓存: " + $cached) "本地缓存命中"
}

foreach ($probeRoot in @("D:\Android\Sdk", (Join-Path $env:USERPROFILE ".gradle\caches"))) {
  if (-not (Test-Path -LiteralPath $probeRoot)) { continue }
  Write-Output ("probe: 搜索 " + $probeRoot)
  $hit = Get-ChildItem -Path $probeRoot -Recurse -Filter $libName -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($hit) {
    Install-Lib $hit.FullName ($probeRoot + " 探测: " + $hit.FullName) "本地探测命中"
  }
  # AAR（zip）内 jni/<abi>/libtensorflowlite_c.so 提取（android 平台才有意义）
  if ($Platform -like "android*") {
    $aars = Get-ChildItem -Path $probeRoot -Recurse -Filter "tensorflow-lite*.aar" -ErrorAction SilentlyContinue
    foreach ($aar in $aars) {
      try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($aar.FullName)
        foreach ($entry in $zip.Entries) {
          if ($entry.FullName -like "jni/*/$libName") {
            $tmp = Join-Path $env:TEMP $libName
            $entry.ExtractToFile($tmp, $true)
            $zip.Dispose()
            Install-Lib $tmp ($probeRoot + " AAR: " + $aar.FullName + "!" + $entry.FullName) ("AAR 内提取（" + $aar.Name + "）")
          }
        }
        $zip.Dispose()
      } catch {
        Write-Output ("probe: AAR 读取失败（跳过）: " + $aar.FullName)
      }
    }
  }
}

# ---------------- ② 官方可验证渠道 ----------------
if (-not $Offline) {
  if ($Platform -eq "win-x64" -or $Platform -eq "linux-x64") {
    Write-Output "step2: 跳过——win-x64/linux-x64 无官方预编译 tensorflowlite_c 发布渠道（契约：无则跳过，禁止第三方）"
  } else {
    $mavenVer = $Version -replace '^v', ''
    $abi = if ($Platform -eq "android-arm64") { "arm64-v8a" } else { "armeabi-v7a" }
    $url = "https://dl.google.com/android/maven2/org/tensorflow/tensorflow-lite/$mavenVer/tensorflow-lite-$mavenVer.aar"
    Write-Output ("step2: 官方 Maven 获取 " + $url)
    try {
      $tmpAar = Join-Path $env:TEMP "tflite-official.aar"
      Invoke-WebRequest -Uri $url -OutFile $tmpAar -UseBasicParsing
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpAar)
      foreach ($entry in $zip.Entries) {
        if ($entry.FullName -eq "jni/$abi/$libName") {
          $tmp = Join-Path $env:TEMP $libName
          $entry.ExtractToFile($tmp, $true)
          $zip.Dispose()
          Install-Lib $tmp ("Google Maven 官方 AAR: " + $url) ("官方预编译 AAR 内提取（" + $mavenVer + "）")
        }
      }
      $zip.Dispose()
      Write-Output "step2: 官方 AAR 内未含 libtensorflowlite_c（仅 jni 包装层）-> 继续 ③/④"
    } catch {
      Write-Output ("step2: 官方渠道获取失败（" + $_.Exception.Message + "）-> 继续 ③/④")
    }
  }
} else {
  Write-Output "step2: -Offline 跳过网络获取"
}

# ---------------- ③ 官方源码最小构建（MSVC + CMake tensorflowlite_c）----------------
if ($Platform -eq "win-x64") {
  $git = Get-Command git -ErrorAction SilentlyContinue
  $cmake = Get-Command cmake -ErrorAction SilentlyContinue
  if (-not $cmake) {
    # VS 自带 CMake（Common7/IDE/CommonExtensions/Microsoft/CMake）
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
      $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
      if ($vsRoot) {
        $vsCmake = Join-Path $vsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        if (Test-Path $vsCmake) {
          $cmake = Get-Item $vsCmake
          Write-Output ("step3: 使用 VS 自带 cmake " + $vsCmake)
        }
      }
    }
  }
  if (-not $cmake) {
    # 本地工具目录（.local/tools/cmake*/bin，官方 Kitware 发行包解压；不入库）
    $localCmake = Get-ChildItem -Path (Join-Path $pkgRoot ".local\tools") -Directory -Filter "cmake*" -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName "bin\cmake.exe" } |
      Where-Object { Test-Path -LiteralPath $_ } |
      Select-Object -First 1
    if ($localCmake) {
      $cmake = Get-Item $localCmake
      Write-Output ("step3: 使用 .local/tools 本地 cmake " + $localCmake)
    }
  }
  if ($git -and $cmake) {
    $srcDir = Join-Path $pkgRoot ".local\src\tensorflow"
    $cmakeExe = if ($cmake -is [System.Management.Automation.CommandInfo]) { $cmake.Source } else { $cmake.FullName }
    Write-Output ("step3: 官方源码构建 tag=" + $Version + " dir=" + $srcDir)
    # vcvars64：VS 2026（18.x）不被 CMake 3.31 的 "Visual Studio 17 2022"
    # 生成器识别，默认生成器会退化为 NMake 且找不到 cl.exe；先导入 MSVC 环境，
    # 再用 NMake Makefiles。找不到 vcvars 时回退旧行为（-A x64）。
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsRoot = ""
    if (Test-Path -LiteralPath $vswhere) {
      $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    $vcvars = if ($vsRoot) { Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat" } else { "" }
    try {
      if (-not (Test-Path -LiteralPath (Join-Path $srcDir ".git"))) {
        & git clone --depth 1 --branch $Version https://github.com/tensorflow/tensorflow.git $srcDir
        if ($LASTEXITCODE -ne 0) { throw "git clone 失败 exit=$LASTEXITCODE" }
      }
      # 构建入口是 tensorflow/lite/c/CMakeLists.txt（定义 target tensorflowlite_c）；
      # 直接配置 tensorflow/lite 只会得到 tensorflow-lite 静态库，没有 C API DLL。
      $srcCmake = Join-Path $srcDir "tensorflow\lite\c"
      $buildDir = Join-Path $srcDir "out_c"
      # 导出修复：tensorflow-lite 以静态库构建时会把 TFL_STATIC_LIBRARY_BUILD
      # 作为 PUBLIC 定义传播给 tensorflowlite_c，使 TFL_CAPI_EXPORT 退化为空，
      # 生成的 DLL **没有任何导出**（实测 dumpbin /exports 为空，DLL 仅 47 KB）。
      # 用 .def 强制导出 dispatch 所需的 24 个稳定 C API 符号（官方 c_api.h 子集）；
      # 实测导出后 DLL 2.24 MB、dumpbin 列出 24 个 TfLite* 符号。
      $defFile = Join-Path $srcDir "tensorflowlite_c_exports.def"
      $defLines = @("EXPORTS") + ($requiredSymbols | ForEach-Object { "    " + $_ })
      [System.IO.File]::WriteAllLines($defFile, $defLines, $utf8NoBom)
      $defFlag = '/DEF:"' + $defFile + '"'
      if ($vcvars -and (Test-Path -LiteralPath $vcvars)) {
        Import-MsvcEnv $vcvars
        Write-Output ("step3: 使用 vcvars64 + NMake Makefiles: " + $vcvars)
        & $cmakeExe -S $srcCmake -B $buildDir -G "NMake Makefiles" `
          -DCMAKE_BUILD_TYPE=Release -DTFLITE_ENABLE_XNNPACK=OFF `
          "-DCMAKE_SHARED_LINKER_FLAGS=$defFlag"
      } else {
        Write-Output "step3: 未找到 vcvars64，回退 -A x64（需 CMake 支持的 VS 生成器）"
        & $cmakeExe -S $srcCmake -B $buildDir -A x64 `
          -DCMAKE_BUILD_TYPE=Release -DTFLITE_ENABLE_XNNPACK=OFF `
          "-DCMAKE_SHARED_LINKER_FLAGS=$defFlag"
      }
      if ($LASTEXITCODE -ne 0) { throw "cmake configure 失败 exit=$LASTEXITCODE" }
      & $cmakeExe --build $buildDir --config Release --target tensorflowlite_c
      if ($LASTEXITCODE -ne 0) { throw "cmake build tensorflowlite_c 失败 exit=$LASTEXITCODE" }
      $built = Get-ChildItem -Path $buildDir -Recurse -Filter "tensorflowlite_c.dll" -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($built) {
        Install-Lib $built.FullName ("官方源码构建: https://github.com/tensorflow/tensorflow @$Version") ("CMake 入口 tensorflow/lite/c、target tensorflowlite_c（MSVC x64 Release、NMake、XNNPACK=OFF）")
      }
      Write-Output "step3: 构建完成但未找到 tensorflowlite_c.dll -> ④"
    } catch {
      Write-Output ("step3: 构建失败（" + $_.Exception.Message + "）-> ④")
    }
  } else {
    Write-Output "step3: 跳过——需要 git 与 cmake（MSVC 工具链缺失时 CMake 配置阶段报错）"
  }
} else {
  Write-Output "step3: 非 win-x64 平台不在本轮构建范围（脚本保留，构建步骤按平台扩展）"
}

# ---------------- ④ fail-closed ----------------
$detail = "D2 链（①本地探测 ②官方预编译 ③源码构建）均未取得可用 $libName"
Register-Gap $detail
Write-Output ("fail-closed: " + $detail)
Write-Output "fail-closed: 已登记 docs/GAPS.md；stub 为唯一运行路径（dispatch 回退接线完备）"
exit 3
