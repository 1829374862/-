# ============================================================
#  短信转发 —— 发布脚本
#
#  做四件事：
#    1. 改 app/build.gradle.kts 里的版本号
#    2. 编译 APK
#    3. 生成/更新 release/update.json
#    4. 打印上传步骤与 jsDelivr 缓存刷新地址
#
#  用法：
#    双击 publish.bat            （交互式，一路回车即可）
#    或 powershell -File publish.ps1 -VersionName 1.1.0 -VersionCode 2 -Yes
# ============================================================
param(
    [string]$VersionName,
    [int]$VersionCode = 0,
    [string]$Changelog,
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
# ---------------- 改成你自己的仓库 ----------------
$GitHubUser   = "1829374862"
$GitHubRepo   = "-"
$GitHubBranch = "main"
# --------------------------------------------------
$CdnBase = "https://cdn.jsdelivr.net/gh/$GitHubUser/$GitHubRepo@$GitHubBranch"
$root           = $PSScriptRoot
$gradleFile     = Join-Path $root "app\build.gradle.kts"
$releaseDir     = Join-Path $root "release"
$releaseJson    = Join-Path $releaseDir "update.json"
$builtApk       = Join-Path $root "app\build\outputs\apk\debug\app-debug.apk"
$envRoot        = Split-Path $root -Parent
$javaHome       = Join-Path $envRoot ".android-env\jdk"
$sdkHome        = Join-Path $envRoot ".android-env\sdk"
$gradleHome     = Join-Path $envRoot ".android-env\gradle-home"
Write-Host ""
Write-Host "=== 短信转发 · 发布 ===" -ForegroundColor Cyan
Write-Host ""
# ---------------- 1. 读取当前版本 ----------------
if (-not (Test-Path $gradleFile)) {
    Write-Host "找不到 $gradleFile" -ForegroundColor Red
    exit 1
}
$content = [System.IO.File]::ReadAllText($gradleFile, [System.Text.Encoding]::UTF8)
$codeMatch = [regex]::Match($content, 'versionCode\s*=\s*(\d+)')
$nameMatch = [regex]::Match($content, 'versionName\s*=\s*"([^"]+)"')
if (-not $codeMatch.Success -or -not $nameMatch.Success) {
    Write-Host "无法从 app/build.gradle.kts 解析出版本号" -ForegroundColor Red
    exit 1
}
$currentCode = [int]$codeMatch.Groups[1].Value
$currentName = $nameMatch.Groups[1].Value
Write-Host "当前版本：$currentName ($currentCode)" -ForegroundColor Gray
# ---------------- 2. 确定新版本号 ----------------
if (-not $VersionName) {
    $input = Read-Host "新版本号（直接回车保持 $currentName）"
    $VersionName = if ($input.Trim()) { $input.Trim() } else { $currentName }
}
if ($VersionCode -le 0) {
    $input = Read-Host "新 versionCode（直接回车用 $($currentCode + 1)，必须大于手机上的版本）"
    $VersionCode = if ($input.Trim()) { [int]$input.Trim() } else { $currentCode + 1 }
}
if ($VersionCode -le $currentCode -and -not $Yes) {
    Write-Host ""
    Write-Host "提醒：新 versionCode ($VersionCode) 不大于当前值 ($currentCode)，" -ForegroundColor Yellow
    Write-Host "App 不会把它识别为「可更新」。确认继续？" -ForegroundColor Yellow
    if ((Read-Host "(y/N)") -notmatch '^[Yy]') { exit 0 }
}
# ---------------- 3. 写入 build.gradle.kts ----------------
$updated = $content -replace 'versionCode\s*=\s*\d+', "versionCode = $VersionCode"
$updated = $updated -replace 'versionName\s*=\s*"[^"]+"', "versionName = `"$VersionName`""
[System.IO.File]::WriteAllText($gradleFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已更新版本号：$VersionName ($VersionCode)" -ForegroundColor Gray
# ---------------- 4. 编译 ----------------
if (-not (Test-Path "$javaHome\bin\java.exe")) {
    Write-Host "找不到 JDK：$javaHome" -ForegroundColor Red
    Write-Host "请改用 Android Studio 构建，或修正脚本里的路径。" -ForegroundColor Red
    exit 1
}
$env:JAVA_HOME        = $javaHome
$env:ANDROID_HOME     = $sdkHome
$env:ANDROID_SDK_ROOT = $sdkHome
$env:GRADLE_USER_HOME = $gradleHome
Write-Host ""
Write-Host "正在编译…" -ForegroundColor Gray
Push-Location $root
& ".\gradlew.bat" assembleDebug --console=plain
$buildExit = $LASTEXITCODE
Pop-Location
if ($buildExit -ne 0 -or -not (Test-Path $builtApk)) {
    Write-Host ""
    Write-Host "编译失败，发布中止。" -ForegroundColor Red
    exit 1
}
# ---------------- 5. 收集待上传文件 ----------------
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$apkName = "SmsForwarder-$VersionName.apk"
$apkDest = Join-Path $releaseDir $apkName
Copy-Item $builtApk $apkDest -Force
$apkSizeMb = [math]::Round((Get-Item $apkDest).Length / 1MB, 2)
# ---------------- 6. 生成 update.json ----------------
$versions = @()
if (Test-Path $releaseJson) {
    try {
        $existing = [System.IO.File]::ReadAllText($releaseJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $versions = @($existing.versions)
    } catch {
        Write-Host "已有 update.json 解析失败，将重新生成" -ForegroundColor Yellow
        $versions = @()
    }
}
# 同一个 versionCode 只保留一条
$versions = @($versions | Where-Object { $_.versionCode -ne $VersionCode })
if (-not $Changelog) {
    $Changelog = "（请在这里补上本次更新说明）"
}
$versions += [pscustomobject]@{
    versionCode = $VersionCode
    versionName = $VersionName
    url         = "$CdnBase/$apkName"
    changelog   = $Changelog
}
$versions = @($versions | Sort-Object -Property versionCode -Descending)
$json = [pscustomobject]@{ versions = $versions } | ConvertTo-Json -Depth 6
# 必须无 BOM，否则 Android 的 JSONObject 解析会失败
[System.IO.File]::WriteAllText($releaseJson, $json, (New-Object System.Text.UTF8Encoding($false)))
# ---------------- 7. 顺带同步到本机更新服务目录 ----------------
$serverDir = Join-Path $root "update-server"
if (Test-Path $serverDir) {
    Copy-Item $apkDest (Join-Path $serverDir $apkName) -Force
    Copy-Item $builtApk (Join-Path $serverDir "SmsForwarder-1.0.0-debug.apk") -Force -ErrorAction SilentlyContinue
}
# ---------------- 8. 输出指引 ----------------
Write-Host ""
Write-Host "=== 编译完成 ===" -ForegroundColor Green
Write-Host "待上传的 APK    : release\$apkName   ($apkSizeMb MB)"
Write-Host "待上传的更新信息: release\update.json"
Write-Host ""
Write-Host "本次生成的 JSON：" -ForegroundColor Gray
Get-Content -Raw -Encoding UTF8 $releaseJson | Write-Host -ForegroundColor DarkGray
if (-not $Yes) {
    $edit = Read-Host "现在用记事本打开 update.json 补更新说明？(y/N)"
    if ($edit -match '^[Yy]') {
        Start-Process notepad.exe $releaseJson -Wait
        Write-Host "已保存。" -ForegroundColor Gray
    }
}
Write-Host ""
Write-Host "接下来手动做两步：" -ForegroundColor Yellow
Write-Host "  1. 把 release\$apkName 上传到仓库根目录"
Write-Host "  2. 把 release\update.json 覆盖上传到仓库根目录"
Write-Host ""
Write-Host "上传完成后，访问一次下面这个地址刷新 CDN 缓存" -ForegroundColor Yellow
Write-Host "（否则 App 最长 12 小时内仍会读到旧内容）：" -ForegroundColor Yellow
Write-Host ""
Write-Host "  https://purge.jsdelivr.net/gh/$GitHubUser/$GitHubRepo@$GitHubBranch/update.json" -ForegroundColor Cyan
Write-Host ""
Write-Host "App 里的更新信息地址始终不变：" -ForegroundColor Gray
Write-Host "  $CdnBase/update.json" -ForegroundColor Cyan
Write-Host ""
