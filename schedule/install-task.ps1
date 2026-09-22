# Windows：用「任务计划程序」定时跑 sync.sh（Docker Desktop 本机场景）
#
# 用法（PowerShell 管理员非必需）：
#   powershell -ExecutionPolicy Bypass -File .\schedule\install-task.ps1
#   powershell -ExecutionPolicy Bypass -File .\schedule\install-task.ps1 -Remove
#
# 前提：本机装有 WSL（Docker Desktop 默认会装）。任务通过
#   wsl -e bash -lc "/mnt/i/MyProjs/stockdb-docker/sync.sh"
# 调用，因此路径必须是 WSL 的 /mnt/... 形式。

param(
    [switch]$Remove,
    [string]$WslScript = "/mnt/i/MyProjs/stockdb-docker/sync.sh",
    [string]$MainTime  = "18:30",
    [string]$CatchTime = "08:30"
)

$ErrorActionPreference = "Stop"

$tasks = @(
    @{ Name = "stockdb-sync-main";  Time = $MainTime  },
    @{ Name = "stockdb-sync-catch"; Time = $CatchTime }
)

if ($Remove) {
    foreach ($t in $tasks) {
        schtasks /Delete /TN $t.Name /F 2>$null | Out-Null
        Write-Host "已删除任务 $($t.Name)"
    }
    exit 0
}

# 检查 WSL 可用
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Write-Error "找不到 wsl 命令，请确认已安装 WSL（Docker Desktop 默认会装）。"
}

foreach ($t in $tasks) {
    # /SC WEEKLY + /D 周一~周五
    $args = @(
        "/Create",
        "/TN", $t.Name,
        "/TR", "wsl -e bash -lc `"$WslScript`"",
        "/SC", "WEEKLY",
        "/D", "MON,TUE,WED,THU,FRI",
        "/ST", $t.Time,
        "/F"
    )
    Write-Host "==> 创建任务 $($t.Name) @ $($t.Time)"
    & schtasks @args | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "创建失败：$($t.Name)" }
}

Write-Host "`n已安装："
foreach ($t in $tasks) { schtasks /Query /TN $t.Name /FO LIST | Select-String "TaskName|Scheduled Task State|Start Time|Days" }

Write-Host "`n手动试跑： schtasks /Run /TN stockdb-sync-main"
Write-Host "查看结果： Get-Content I:\MyProjs\stockdb-docker\sync.log -Tail 30"
