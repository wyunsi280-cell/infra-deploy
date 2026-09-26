param([string]$Message)

# 项目控制脚本——菜单式,不用记命令。覆盖 git 日常操作 + 发布到 devpi +
# 打 tag + 同步 GitHub secret 里的 devpi 密码。
#
# 用法:在这个仓库目录下跑:
#   .\project-ctl.ps1
#
# 想要更短的调用方式,加个 PowerShell 函数(写进 profile 一次就行):
#   notepad $PROFILE
#   加一行: function pctl { & .\project-ctl.ps1 @args }

$ErrorActionPreference = "Stop"

function Test-InRepo {
    git rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "当前目录不是 git 仓库(或者子目录)。"
        exit 1
    }
    $repoRoot = (git rev-parse --show-toplevel).Trim()
    Set-Location $repoRoot
}

function Get-RepoSlug {
    $url = (git remote get-url origin).Trim()
    if ($url -match "github\.com[:/](.+?)(\.git)?$") {
        return $Matches[1]
    }
    return $null
}

function Get-VendorPasswordFromDevpi {
    # 本机(WSL,如果有的话)能不能连到跑 devpi 的那个容器,连得到就直接读,
    # 连不到返回空,不报错——调用方自己决定要不要问人工输入。这是唯一还会
    # 碰 WSL 的地方,而且是纯粹的"有就顺手用,没有就问人"的小便利,不是硬依赖
    # (跟发布用的 docker 编译不一样,那个是真的需要 docker,已经改成完全走
    # GitHub Actions 远程编译,不再依赖本机 WSL)。
    try {
        $pw = wsl bash -lc "docker inspect devpi-devpi-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^DEVPI_PASSWORD=' | head -1 | cut -d= -f2-" 2>$null
        return $pw.Trim()
    } catch {
        return $null
    }
}

function Invoke-CommitPush {
    param([string]$CommitMessage)

    $changes = git status --short
    if (-not $changes) {
        Write-Host "没有改动,不用提交。"
        Write-Host "==> 检查有没有落后远程分支"
        git pull --ff-only
        return
    }

    Write-Host "本次要提交的改动:"
    $changes | ForEach-Object { Write-Host $_ }
    Write-Host ""

    if (-not $CommitMessage) {
        $CommitMessage = Read-Host "提交信息(直接回车取消)"
    }
    if (-not $CommitMessage) {
        Write-Host "取消。"
        return
    }

    Write-Host "==> git add -A"
    git add -A
    if ($LASTEXITCODE -ne 0) { return }

    Write-Host "==> git commit"
    git commit -m "$CommitMessage"
    if ($LASTEXITCODE -ne 0) { return }

    Write-Host "==> git pull(先拉一下,避免推送时跟远程冲突)"
    git pull --no-edit
    if ($LASTEXITCODE -ne 0) { return }

    Write-Host "==> git push"
    git push
    if ($LASTEXITCODE -ne 0) { return }

    Write-Host ""
    Write-Host "完成。"
}

function Show-Status { git status }
function Show-Diff { git diff }
function Invoke-Pull { git pull --no-edit }
function Show-Log { git log --oneline -20 }

function Invoke-TestPublish {
    # 走 GitHub Actions 手动触发(workflow_dispatch),不依赖本机有没有装
    # docker/WSL——编译在 GitHub 的远程 runner 上跑,跟正式发布(打 tag)用的
    # 是同一套远程机制,只是发到 vendor/test 索引,不影响 vendor/prod。
    $slug = Get-RepoSlug
    if (-not $slug) {
        Write-Host "读不到 GitHub 仓库信息(origin 不是 github.com 地址?)。"
        return
    }
    if (-not (Test-Path ".github/workflows/test-publish.yml")) {
        Write-Host "这个仓库没有 .github/workflows/test-publish.yml,跳过。"
        return
    }
    Write-Host "==> 触发 GitHub Actions 测试发布(发到 vendor/test)"
    gh workflow run test-publish.yml --repo $slug
    if ($LASTEXITCODE -ne 0) { return }
    Write-Host "已触发,去这里看进度:"
    Write-Host "  https://github.com/$slug/actions/workflows/test-publish.yml"
}

function Invoke-TagRelease {
    if (-not (Test-Path "pyproject.toml")) {
        Write-Host "这个仓库里没有 pyproject.toml,不知道版本号,跳过。"
        return
    }
    $versionLine = Get-Content pyproject.toml | Where-Object { $_ -match '^version = "(.+)"' } | Select-Object -First 1
    if (-not $versionLine) {
        Write-Host "pyproject.toml 里没找到 version 字段。"
        return
    }
    $version = $Matches[1]
    $tag = "v$version"

    $existing = git tag -l $tag
    if ($existing) {
        Write-Host "tag $tag 已经存在了——是不是忘了先改 pyproject.toml 里的 version?"
        return
    }

    Write-Host "当前 pyproject.toml 版本: $version"
    $confirm = Read-Host "打 tag $tag 并推送,触发正式发布?(y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "取消。"
        return
    }

    git tag $tag
    if ($LASTEXITCODE -ne 0) { return }
    git push origin $tag
    if ($LASTEXITCODE -ne 0) { return }

    Write-Host ""
    Write-Host "已推送 $tag,去 GitHub Actions 看 CI 跑没跑起来:"
    $slug = Get-RepoSlug
    if ($slug) {
        Write-Host "  https://github.com/$slug/actions"
    }
}

function Invoke-SyncDevpiSecret {
    $slug = Get-RepoSlug
    if (-not $slug) {
        Write-Host "读不到 GitHub 仓库信息(origin 不是 github.com 地址?)。"
        return
    }

    Write-Host "==> 尝试从本机 devpi 容器自动读取当前密码"
    $password = Get-VendorPasswordFromDevpi
    if ($password) {
        Write-Host "读到了(不显示明文),要用这个同步到 $slug 的 DEVPI_PASSWORD secret 吗?"
        $confirm = Read-Host "确认吗?(y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            $password = $null
        }
    }
    if (-not $password) {
        $secure = Read-Host "手动输入 devpi vendor 密码" -AsSecureString
        $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )
    }
    if (-not $password) {
        Write-Host "没有密码,取消。"
        return
    }

    gh secret set DEVPI_PASSWORD --repo $slug --body "$password"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "已同步 $slug 的 DEVPI_PASSWORD secret。"
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "================ 项目操作 ================"
        Write-Host "--- Git ---"
        Write-Host "1) 提交并推送(add + commit + pull + push)"
        Write-Host "2) 查看状态"
        Write-Host "3) 查看改动详情(diff)"
        Write-Host "4) 拉取远程最新"
        Write-Host "5) 查看提交历史(最近20条)"
        Write-Host "--- 发布(都走 GitHub Actions 远程编译,不依赖本机 docker/WSL) ---"
        Write-Host "6) 触发测试发布(发到 vendor/test,不用改版本号/打 tag)"
        Write-Host "7) 打 tag 触发正式发布(发到 vendor/prod,先改好 pyproject.toml 版本号)"
        Write-Host "8) 同步 devpi 密码到 GitHub secret(devpi 密码换了就用这个)"
        Write-Host "0) 退出"
        Write-Host "==========================================="
        $choice = Read-Host "请输入序号"
        switch ($choice) {
            "1" { Invoke-CommitPush }
            "2" { Show-Status }
            "3" { Show-Diff }
            "4" { Invoke-Pull }
            "5" { Show-Log }
            "6" { Invoke-TestPublish }
            "7" { Invoke-TagRelease }
            "8" { Invoke-SyncDevpiSecret }
            "0" { return }
            default { Write-Host "无效选项,请重新输入。" }
        }
    }
}

Test-InRepo

Write-Host "==================================================="
Write-Host " $(git rev-parse --show-toplevel)"
Write-Host "==================================================="

if ($Message) {
    Invoke-CommitPush -CommitMessage $Message
} else {
    Show-Menu
}
