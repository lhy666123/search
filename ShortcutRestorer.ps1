# ============================================================
# 快捷方式恢复助手 Shortcut Restorer
# 面向 Windows 7 / 10 / 11（PowerShell 2.0+）
# 用途：重装系统后桌面/开始菜单快捷方式丢失时，快速扫描磁盘
#       找到应用主程序(.exe)，批量重建桌面或开始菜单快捷方式。
# ============================================================
param(
    [switch]$SelfTest,
    [string]$HeadlessScan = "",
    [string]$OutFile = "",
    [switch]$InstalledApps
)

$script:CSharpCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Diagnostics;

public class ScanResult {
    public string Path = "";
    public string Name = "";
    public string Product = "";
    public string Company = "";
    public string Version = "";
    public long Size = 0;
    public DateTime Modified;
}

public static class ScanEngine {
    private static readonly object _lock = new object();
    private static readonly Queue<ScanResult> _queue = new Queue<ScanResult>();
    private static readonly List<Thread> _threads = new List<Thread>();
    private static volatile bool _running = false;
    private static volatile bool _cancel = false;
    private static int _foundCount = 0;
    private static int _dirCount = 0;
    private static volatile string _currentDir = "";

    public static void Start(string[] roots, string[] excludedTokens, bool skipInstaller) {
        if (_running) return;
        _cancel = false;
        _running = true;
        lock (_lock) { _queue.Clear(); }
        _foundCount = 0;
        _dirCount = 0;
        _currentDir = "";
        _threads.Clear();
        foreach (string root in roots) {
            if (string.IsNullOrEmpty(root)) continue;
            string r = root;
            string[] toks = excludedTokens;
            bool skip = skipInstaller;
            Thread t = new Thread(delegate() { ScanRoot(r, toks, skip); });
            t.IsBackground = true;
            t.Start();
            _threads.Add(t);
        }
    }

    private static void ScanRoot(string root, string[] excludedTokens, bool skipInstaller) {
        try {
            if (Directory.Exists(root)) Walk(root, excludedTokens, skipInstaller);
        } catch { }
    }

    private static void Walk(string dir, string[] excludedTokens, bool skipInstaller) {
        if (_cancel || !_running) return;
        _currentDir = dir;
        string[] dirs = null;
        try { dirs = Directory.GetDirectories(dir); } catch { }
        if (dirs != null) {
            foreach (string d in dirs) {
                if (_cancel || !_running) return;
                if (IsExcluded(d, excludedTokens)) continue;
                Walk(d, excludedTokens, skipInstaller);
                Interlocked.Increment(ref _dirCount);
            }
        }
        string[] files = null;
        try { files = Directory.GetFiles(dir, "*.exe"); } catch { }
        if (files != null && files.Length > 0) {
            foreach (string f in files) {
                if (_cancel || !_running) return;
                string name = Path.GetFileName(f);
                if (skipInstaller && IsInstallerName(name)) continue;
                if (!IsGuiExe(f)) continue;
                ScanResult sr = new ScanResult();
                sr.Path = f.Replace('/', '\\');
                sr.Name = name;
                try {
                    FileInfo fi = new FileInfo(f);
                    if (!fi.Exists) continue;
                    sr.Size = fi.Length;
                    sr.Modified = fi.LastWriteTime;
                    FileVersionInfo vi = FileVersionInfo.GetVersionInfo(f);
                    if (vi.ProductName != null && vi.ProductName.Trim().Length > 0) sr.Product = vi.ProductName.Trim();
                    if (vi.CompanyName != null && vi.CompanyName.Trim().Length > 0) sr.Company = vi.CompanyName.Trim();
                    if (vi.FileVersion != null && vi.FileVersion.Trim().Length > 0) sr.Version = vi.FileVersion.Trim();
                } catch { }
                lock (_lock) { _queue.Enqueue(sr); }
                Interlocked.Increment(ref _foundCount);
            }
        }
    }

    private static bool IsExcluded(string dir, string[] tokens) {
        if (tokens == null || tokens.Length == 0) return false;
        foreach (string tok in tokens) {
            if (string.IsNullOrEmpty(tok)) continue;
            if (dir.IndexOf(tok, StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        return false;
    }

    private static bool IsInstallerName(string name) {
        string n = name.ToLowerInvariant();
        if (n.StartsWith("setup") || n.StartsWith("install") || n.Contains("unins") || n.StartsWith("uninstall")
            || n.StartsWith("msiexec") || n.Contains("vcredist") || n.Contains("dotnetfx") || n.Contains("redist")
            || n.Contains("_uninstall")) return true;
        return false;
    }

    private static bool IsGuiExe(string file) {
        try {
            using (FileStream fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                byte[] hdr = new byte[4096];
                int read = fs.Read(hdr, 0, hdr.Length);
                if (read < 0x40) return false;
                int peOff = BitConverter.ToInt32(hdr, 0x3C);
                if (peOff < 0 || peOff + 96 > read) return false;
                if (hdr[peOff] != (byte)'P' || hdr[peOff + 1] != (byte)'E' || hdr[peOff + 2] != 0 || hdr[peOff + 3] != 0) return false;
                ushort magic = BitConverter.ToUInt16(hdr, peOff + 24);
                if (magic != 0x10B && magic != 0x20B) return false;
                ushort subsystem = BitConverter.ToUInt16(hdr, peOff + 24 + 68);
                return subsystem == 2;
            }
        } catch {
            return false;
        }
    }

    public static bool PeIsGui(string file) { return IsGuiExe(file); }

    public static bool IsRunning { get { return _running; } }
    public static bool CancelRequested { get { return _cancel; } }
    public static int FoundCount { get { return _foundCount; } }
    public static int DirCount { get { return _dirCount; } }
    public static string CurrentDir { get { return _currentDir; } }

    public static void Stop() { _cancel = true; }

    public static bool IsIdle() {
        foreach (Thread t in _threads) { if (t.IsAlive) return false; }
        lock (_lock) { return _queue.Count == 0; }
    }

    public static int QueueSize {
        get { lock (_lock) { return _queue.Count; } }
    }

    public static void Finish() { _running = false; }

    public static ScanResult[] DequeueBatch(int max) {
        List<ScanResult> list = new List<ScanResult>();
        lock (_lock) {
            while (list.Count < max && _queue.Count > 0) list.Add(_queue.Dequeue());
        }
        return list.ToArray();
    }
}
'@

# ---------------- 通用函数 ----------------

function Add-ScanEngine {
    if ('ScanEngine' -as [type]) { return }
    try {
        Add-Type -TypeDefinition $script:CSharpCode -Language CSharp -ErrorAction Stop | Out-Null
    } catch {
        Write-Error ('扫描引擎编译失败：' + $_.Exception.Message)
        exit 1
    }
}

function Get-FixedDrives {
    $result = New-Object System.Collections.ArrayList
    $drives = [System.IO.DriveInfo]::GetDrives()
    foreach ($d in $drives) {
        if ($d.DriveType -eq [System.IO.DriveType]::Fixed -and $d.IsReady) {
            [void]$result.Add($d.Name)
        }
    }
    return $result
}

function Get-QuickRoots {
    $roots = New-Object System.Collections.ArrayList
    $drives = Get-FixedDrives
    foreach ($d in $drives) {
        $pf = Join-Path $d 'Program Files'
        if (Test-Path -LiteralPath $pf) { [void]$roots.Add($pf) }
        $pf86 = Join-Path $d 'Program Files (x86)'
        if (Test-Path -LiteralPath $pf86) { [void]$roots.Add($pf86) }
        # 新增：扫描磁盘根目录下包含 exe 的非系统目录（覆盖非标准安装路径）
        try {
            $excludeExact = @('windows','$recycle.bin','system volume information','recovery','programdata','users','documents and settings','setup','installer')
            $excludeLike = @('*temp*','*cache*','*logs*','*download*','*music*','*video*','*pictures*','*documents*','*games*','*steam*','*backup*','*winpe*','*iso*','*windows ?*','*windows 1?*')
            $items = Get-ChildItem -LiteralPath $d -ErrorAction SilentlyContinue
            $count = 0
            foreach ($item in $items) {
                if ($count -ge 15) { break }
                if (-not $item.PSIsContainer) { continue }
                $lower = $item.Name.ToLowerInvariant()
                $skip = $false
                foreach ($e in $excludeExact) { if ($lower -eq $e) { $skip = $true; break } }
                if (-not $skip) {
                    foreach ($e in $excludeLike) { if ($lower -like $e) { $skip = $true; break } }
                }
                if ($skip) { continue }
                try {
                    $hasExe = $false
                    $childExes = Get-ChildItem -LiteralPath $item.FullName -Filter '*.exe' -ErrorAction SilentlyContinue
                    if ($childExes) {
                        foreach ($ce in $childExes) { $hasExe = $true; break }
                    }
                    if ($hasExe) {
                        [void]$roots.Add($item.FullName)
                        $count++
                    }
                } catch {}
            }
        } catch {}
    }
    if ($env:LOCALAPPDATA) {
        $lp = Join-Path $env:LOCALAPPDATA 'Programs'
        if (Test-Path -LiteralPath $lp) { [void]$roots.Add($lp) }
        # 新增：扫描 LOCALAPPDATA 根目录下包含 exe 的非数据目录（覆盖 Electron/绿色应用）
        try {
            $localExclude = @('temp','cache','logs','cookies','history','microsoft','packages','nvidia','amd','intel','google','chrome','opera','mozilla')
            $items = Get-ChildItem -LiteralPath $env:LOCALAPPDATA -ErrorAction SilentlyContinue
            $count = 0
            foreach ($item in $items) {
                if ($count -ge 15) { break }
                if (-not $item.PSIsContainer) { continue }
                $lower = $item.Name.ToLowerInvariant()
                $skip = $false
                foreach ($e in $localExclude) { if ($lower -eq $e) { $skip = $true; break } }
                if ($skip) { continue }
                try {
                    $hasExe = $false
                    $childExes = Get-ChildItem -LiteralPath $item.FullName -Filter '*.exe' -ErrorAction SilentlyContinue
                    if ($childExes) {
                        foreach ($ce in $childExes) { $hasExe = $true; break }
                    }
                    if ($hasExe) {
                        [void]$roots.Add($item.FullName)
                        $count++
                    }
                } catch {}
            }
        } catch {}
    }
    return $roots
}

function Get-DefaultTokens {
    return @('\Windows\', '\$Recycle.Bin\', 'System Volume Information', '\Recovery\', '\node_modules\', '\.git\', '\ProgramData\Package Cache\', '\WindowsApps\')
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

# 产品分组键：优先按产品名，无产品名时按文件名（单独成组，不去重）
function Get-ProductKey {
    param($r)
    $p = ''
    if ($r.Product) { $p = [string]$r.Product }
    $p = $p.Trim()
    if ($p.Length -gt 0) { return ('p|' + $p.ToLowerInvariant()) }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension([string]$r.Name)
    return ('f|' + $stem.ToLowerInvariant())
}

function Get-PathDepth {
    param([string]$path)
    return ($path -split '\\').Count
}

# 判断 exe 是否更像是「能打开图形界面的主程序」：得分高者优先
function Get-MainScore {
    param($r)
    $score = 0
    $clean = { param($s) ($s -replace '[^a-zA-Z0-9\u4e00-\u9fff]', '').ToLowerInvariant() }
    $nClean = & $clean ([System.IO.Path]::GetFileNameWithoutExtension([string]$r.Name))
    $pClean = & $clean ([string]$r.Product)
    if ($pClean.Length -gt 0) {
        if ($nClean -eq $pClean) { $score += 80 }
        elseif ($nClean.Length -ge 4 -and $pClean.IndexOf($nClean) -ge 0) { $score += 50 }
        elseif ($pClean.Length -ge 4 -and $nClean.IndexOf($pClean) -ge 0) { $score += 40 }
    }
    $low = ([string]$r.Name).ToLowerInvariant()
    if ($low -match 'update|updater|unins|repair|crash|helper|report|host|daemon|service|background') { $score -= 40 }
    if ($low -match '^unins|^uninstall') { $score -= 80 }
    $lpath = ([string]$r.Path).ToLowerInvariant()
    if ($lpath -match '\\update\\|\\updater\\|\\unins|\\plugins\\|\\runtime\\|\\resources\\|\\addon|\\bin\\|\\upgrade\\') { $score -= 50 }
    if ($r.Company -and ([string]$r.Company).Trim().Length -gt 0) { $score += 5 }
    return $score
}

# 隐藏系统/自带/附带的安装、更新与后台组件目录（只保留真正的图形界面应用）
function Test-BuiltIn {
    param([string]$path)
    $lp = $path.ToLowerInvariant()
    $markers = @(
        '\microsoft\edge\', '\microsoft\edgewebview\', '\edgecore\', '\edgeupdate\',
        '\microsoft\onedrive\', '\microsoft\teams\', '\copilot\',
        '\windows media player\', '\microsoft\windows defender\', '\microsoft\windows security\', '\windowsapps\',
        '\windows defender\', '\internet explorer\', '\javapath', '\windows mail\', '\awccplugins\',
        '\windows photo viewer\', '\program files\java\', '\microsoft shared\',
        '\installer\', '\.install4j\', '\downloaded installations\', '\mingw64\', '\usr\bin\',
        '\updater\', '\unins', '\update\', '\updateservice\',
        'installation information\', '\common files\steam\', '\vmware\usb\'
    )
    foreach ($m in $markers) { if ($lp.IndexOf($m) -ge 0) { return $true } }
    return $false
}

# 文件名一眼即知是后台服务/守护进程/加载动画/广告优惠等附属程序
function Test-HelperName {
    param([string]$name)
    $n = $name.ToLowerInvariant()
    if ($n.EndsWith('service.exe') -or $n.EndsWith('service32.exe')) { return $true }
    if ($n.IndexOf('subagent') -ge 0) { return $true }
    if ($n.IndexOf('daemon') -ge 0) { return $true }
    if ($n.EndsWith('stressor.exe')) { return $true }
    if ($n.Contains('loading')) { return $true }
    if ($n.Contains('coupon')) { return $true }
    if ($n.EndsWith('trayhelper.exe')) { return $true }
    if ($n.IndexOf('vpndownloader') -ge 0) { return $true }
    if ($n.IndexOf('check for update') -ge 0) { return $true }
    if ($n.IndexOf('notification_helper') -ge 0) { return $true }
    if ($n.IndexOf('mousemux-v2-loader') -ge 0) { return $true }
    if ($n.IndexOf('serviceshell') -ge 0) { return $true }
    if ($n.IndexOf('installer') -ge 0) { return $true }
    return $false
}

# 产品名为更新器/安装器/运行时组件时视为噪音（如“江下产品更新”“Windows App SDK”）
function Test-NoiseProduct {
    param($r)
    $p = ([string]$r.Product).ToLowerInvariant()
    if ($p.Length -eq 0) { return $false }
    if ($p -match 'update|updater|installer|uninstall|app sdk') { return $true }
    if ($p.IndexOf('更新') -ge 0 -or $p.IndexOf('升级') -ge 0 -or $p.IndexOf('卸载') -ge 0) { return $true }
    return $false
}

# 把一条结果放进“产品→最佳主程序”的映射，返回是否取代了当前最佳
function Update-BestMap {
    param($map, $r)
    if (Test-BuiltIn ([string]$r.Path)) { return $false }
    if (Test-HelperName ([string]$r.Name)) { return $false }
    if (Test-NoiseProduct $r) { return $false }
    $key = Get-ProductKey $r
    $score = Get-MainScore $r
    $depth = Get-PathDepth ([string]$r.Path)
    $cur = $null
    if ($map.ContainsKey($key)) { $cur = $map[$key] }
    $replace = $false
    if (-not $cur) { $replace = $true }
    elseif ($score -gt $cur.Score) { $replace = $true }
    elseif ($score -eq $cur.Score -and $depth -lt $cur.Depth) { $replace = $true }
    elseif ($score -eq $cur.Score -and $depth -eq $cur.Depth -and $r.Size -gt $cur.Size) { $replace = $true }
    if ($replace) { $map[$key] = @{ R = $r; Score = $score; Depth = $depth; Size = $r.Size; Item = $null; Key = $key } }
    return $replace
}

function New-Shortcut {
    param([string]$TargetPath, [string]$DestDir, [string]$BaseName)
    $cleanBase = $BaseName -replace '[\\/:*?"<>|]', ' '
    $cleanBase = $cleanBase.Trim()
    if ([string]::IsNullOrEmpty($cleanBase)) { $cleanBase = 'Application' }
    $shell = New-Object -ComObject WScript.Shell
    $link = Join-Path $DestDir ($cleanBase + '.lnk')
    $i = 2
    while (Test-Path -LiteralPath $link) {
        $link = Join-Path $DestDir ($cleanBase + " ($i).lnk")
        $i++
    }
    $sc = $shell.CreateShortcut($link)
    $sc.TargetPath = $TargetPath
    $sc.WorkingDirectory = Split-Path -Parent $TargetPath
    $sc.IconLocation = "$TargetPath,0"
    $sc.Description = '由快捷方式恢复助手创建'
    $sc.Save()
    return $link
}

# ---------------- 界面构建 ----------------

# 选择界面字体：优先微软雅黑 UI（Win8.1+），其次微软雅黑（Win7），都没有时回退到 Tahoma
function Get-UI-Font {
    $cands = @('Microsoft YaHei UI', 'Microsoft YaHei', 'Tahoma')
    foreach ($name in $cands) {
        foreach ($f in [System.Drawing.FontFamily]::Families) {
            if ($f.Name -ieq $name) { return New-Object System.Drawing.Font($name, 9) }
        }
    }
    return New-Object System.Drawing.Font('Tahoma', 9)
}

function Build-MainForm {
    $uiFont = Get-UI-Font
    $script:form = New-Object System.Windows.Forms.Form
    $script:form.Text = '快捷方式恢复助手'
    $script:form.Size = New-Object System.Drawing.Size(1070, 722)
    $script:form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $script:form.MinimumSize = New-Object System.Drawing.Size(1000, 652)
    $script:form.Font = $uiFont

    # 模式选择行
    $script:rModeScan = New-Object System.Windows.Forms.RadioButton
    $script:rModeScan.Text = '扫描程序模式'
    $script:rModeScan.Location = New-Object System.Drawing.Point(14, 10)
    $script:rModeScan.AutoSize = $true
    $script:rModeScan.Checked = $true

    $script:rModeApps = New-Object System.Windows.Forms.RadioButton
    $script:rModeApps.Text = '已安装应用模式'
    $script:rModeApps.Location = New-Object System.Drawing.Point(150, 10)
    $script:rModeApps.AutoSize = $true

    $script:lblModeTip = New-Object System.Windows.Forms.Label
    $script:lblModeTip.Text = '扫描程序模式：在磁盘上查找主程序；已安装应用模式：与系统设置的已安装应用一致，左侧显示应用图标。'
    $script:lblModeTip.Location = New-Object System.Drawing.Point(300, 12)
    $script:lblModeTip.AutoSize = $true

    # 扫描范围区
    $script:gbScope = New-Object System.Windows.Forms.GroupBox
    $script:gbScope.Text = '扫描范围'
    $script:gbScope.Location = New-Object System.Drawing.Point(12, 40)
    $script:gbScope.Size = New-Object System.Drawing.Size(1036, 118)

    $script:rFast = New-Object System.Windows.Forms.RadioButton
    $script:rFast.Text = '快速扫描（常用安装目录）'
    $script:rFast.Location = New-Object System.Drawing.Point(20, 26)
    $script:rFast.Size = New-Object System.Drawing.Size(200, 26)
    $script:rFast.Checked = $true

    $script:rFull = New-Object System.Windows.Forms.RadioButton
    $script:rFull.Text = '全盘扫描'
    $script:rFull.Location = New-Object System.Drawing.Point(228, 26)
    $script:rFull.Size = New-Object System.Drawing.Size(110, 26)

    $script:rDir = New-Object System.Windows.Forms.RadioButton
    $script:rDir.Text = '选择目录'
    $script:rDir.Location = New-Object System.Drawing.Point(344, 26)
    $script:rDir.Size = New-Object System.Drawing.Size(120, 26)

    $script:txtDir = New-Object System.Windows.Forms.TextBox
    $script:txtDir.Location = New-Object System.Drawing.Point(470, 22)
    $script:txtDir.Size = New-Object System.Drawing.Size(400, 28)
    $script:txtDir.ReadOnly = $true

    $script:btnBrowse = New-Object System.Windows.Forms.Button
    $script:btnBrowse.Text = '浏览...'
    $script:btnBrowse.Location = New-Object System.Drawing.Point(878, 21)
    $script:btnBrowse.Size = New-Object System.Drawing.Size(84, 30)

    $script:lblDrives = New-Object System.Windows.Forms.Label
    $script:lblDrives.Text = '可选磁盘：'
    $script:lblDrives.Location = New-Object System.Drawing.Point(20, 62)
    $script:lblDrives.Size = New-Object System.Drawing.Size(96, 24)

    $script:clbDrives = New-Object System.Windows.Forms.CheckedListBox
    $script:clbDrives.Location = New-Object System.Drawing.Point(120, 58)
    $script:clbDrives.Size = New-Object System.Drawing.Size(256, 54)
    $script:clbDrives.CheckOnClick = $true

    $script:chkExclude = New-Object System.Windows.Forms.CheckBox
    $script:chkExclude.Text = '排除系统自带程序'
    $script:chkExclude.Location = New-Object System.Drawing.Point(392, 62)
    $script:chkExclude.AutoSize = $true
    $script:chkExclude.Checked = $true

    $script:chkOnlyProduct = New-Object System.Windows.Forms.CheckBox
    $script:chkOnlyProduct.Text = '隐藏无产品名称的程序'
    $script:chkOnlyProduct.Location = New-Object System.Drawing.Point(392, 90)
    $script:chkOnlyProduct.AutoSize = $true
    $script:chkOnlyProduct.Checked = $true

    $script:btnStart = New-Object System.Windows.Forms.Button
    $script:btnStart.Text = '开始扫描'
    $script:btnStart.Location = New-Object System.Drawing.Point(864, 102)
    $script:btnStart.Size = New-Object System.Drawing.Size(100, 38)
    $script:btnStart.Font = New-Object System.Drawing.Font($uiFont, [System.Drawing.FontStyle]::Bold)

    $script:btnStop = New-Object System.Windows.Forms.Button
    $script:btnStop.Text = '停止'
    $script:btnStop.Location = New-Object System.Drawing.Point(970, 102)
    $script:btnStop.Size = New-Object System.Drawing.Size(84, 38)
    $script:btnStop.Enabled = $false

    $script:gbScope.Controls.Add($script:rFast)
    $script:gbScope.Controls.Add($script:rFull)
    $script:gbScope.Controls.Add($script:rDir)
    $script:gbScope.Controls.Add($script:txtDir)
    $script:gbScope.Controls.Add($script:btnBrowse)
    $script:gbScope.Controls.Add($script:lblDrives)
    $script:gbScope.Controls.Add($script:clbDrives)
    $script:gbScope.Controls.Add($script:chkExclude)
    $script:gbScope.Controls.Add($script:chkOnlyProduct)
    $script:form.Controls.Add($script:btnStart)
    $script:form.Controls.Add($script:btnStop)

    # 状态区
    $script:progress = New-Object System.Windows.Forms.ProgressBar
    $script:progress.Location = New-Object System.Drawing.Point(12, 166)
    $script:progress.Size = New-Object System.Drawing.Size(1036, 18)
    $script:progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:progress.MarqueeAnimationSpeed = 0

    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.Text = '就绪。扫描时只列出常用的图形界面程序，系统自带与后台组件会自动隐藏。'
    $script:lblStatus.Location = New-Object System.Drawing.Point(12, 188)
    $script:lblStatus.Size = New-Object System.Drawing.Size(1036, 24)

    # 过滤行
    $script:lblFilter = New-Object System.Windows.Forms.Label
    $script:lblFilter.Text = '搜索：'
    $script:lblFilter.Location = New-Object System.Drawing.Point(12, 218)
    $script:lblFilter.Size = New-Object System.Drawing.Size(50, 26)

    $script:txtFilter = New-Object System.Windows.Forms.TextBox
    $script:txtFilter.Location = New-Object System.Drawing.Point(64, 216)
    $script:txtFilter.Size = New-Object System.Drawing.Size(660, 28)

    $script:lblCount = New-Object System.Windows.Forms.Label
    $script:lblCount.Text = '共 0 项'
    $script:lblCount.Location = New-Object System.Drawing.Point(738, 218)
    $script:lblCount.Size = New-Object System.Drawing.Size(310, 26)

    # 结果列表（应用模式通过 SmallImageList 在左侧缩略显示应用图标）
    $script:iconList = New-Object System.Windows.Forms.ImageList
    $script:iconList.ImageSize = New-Object System.Drawing.Size(16, 16)
    $script:iconList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

    $script:listView = New-Object System.Windows.Forms.ListView
    $script:listView.Location = New-Object System.Drawing.Point(12, 248)
    $script:listView.Size = New-Object System.Drawing.Size(1036, 342)
    $script:listView.View = [System.Windows.Forms.View]::Details
    $script:listView.FullRowSelect = $true
    $script:listView.CheckBoxes = $true
    $script:listView.MultiSelect = $true
    $script:listView.HideSelection = $false
    $script:listView.GridLines = $true
    $script:listView.ShowItemToolTips = $true
    $script:listView.SmallImageList = $script:iconList
    [void]$script:listView.Columns.Add('应用名称', 240)
    [void]$script:listView.Columns.Add('路径', 380)
    [void]$script:listView.Columns.Add('公司', 180)
    [void]$script:listView.Columns.Add('版本', 100)
    [void]$script:listView.Columns.Add('大小', 100)

    # 操作按钮
    $script:btnSelectAll = New-Object System.Windows.Forms.Button
    $script:btnSelectAll.Text = '全选'
    $script:btnSelectAll.Location = New-Object System.Drawing.Point(12, 598)
    $script:btnSelectAll.Size = New-Object System.Drawing.Size(80, 34)

    $script:btnInvert = New-Object System.Windows.Forms.Button
    $script:btnInvert.Text = '反选'
    $script:btnInvert.Location = New-Object System.Drawing.Point(100, 598)
    $script:btnInvert.Size = New-Object System.Drawing.Size(80, 34)

    $script:btnDesktop = New-Object System.Windows.Forms.Button
    $script:btnDesktop.Text = '添加到桌面'
    $script:btnDesktop.Location = New-Object System.Drawing.Point(188, 598)
    $script:btnDesktop.Size = New-Object System.Drawing.Size(130, 34)

    $script:btnStartMenuUser = New-Object System.Windows.Forms.Button
    $script:btnStartMenuUser.Text = '添加到开始菜单'
    $script:btnStartMenuUser.Location = New-Object System.Drawing.Point(326, 598)
    $script:btnStartMenuUser.Size = New-Object System.Drawing.Size(170, 34)

    $script:btnStartMenuAll = New-Object System.Windows.Forms.Button
    $script:btnStartMenuAll.Text = '所有用户开始菜单'
    $script:btnStartMenuAll.Location = New-Object System.Drawing.Point(504, 598)
    $script:btnStartMenuAll.Size = New-Object System.Drawing.Size(170, 34)

    $script:btnOpenDir = New-Object System.Windows.Forms.Button
    $script:btnOpenDir.Text = '打开所在文件夹'
    $script:btnOpenDir.Location = New-Object System.Drawing.Point(682, 598)
    $script:btnOpenDir.Size = New-Object System.Drawing.Size(130, 34)

    $script:btnExport = New-Object System.Windows.Forms.Button
    $script:btnExport.Text = '导出CSV'
    $script:btnExport.Location = New-Object System.Drawing.Point(820, 598)
    $script:btnExport.Size = New-Object System.Drawing.Size(100, 34)

    $script:lblTip = New-Object System.Windows.Forms.Label
    $script:lblTip.Text = '提示：勾选需要的程序，再点「添加到桌面」或「添加到开始菜单」；重复文件名会自动加序号。'
    $script:lblTip.Location = New-Object System.Drawing.Point(12, 642)
    $script:lblTip.Size = New-Object System.Drawing.Size(1036, 24)

    # 悬停提示
    $script:tip = New-Object System.Windows.Forms.ToolTip
    $script:tip.SetToolTip($script:btnStartMenuUser, '只对当前登录用户生效，不需要管理员权限')
    $script:tip.SetToolTip($script:btnStartMenuAll, '对所有用户生效，需要以管理员身份运行本程序')
    $script:tip.SetToolTip($script:btnBrowse, '选择指定目录进行扫描')
    $script:tip.SetToolTip($script:chkOnlyProduct, '勾选后只显示可读取到产品名称的程序，隐藏杂项')

    # 组装
    $script:form.Controls.Add($script:rModeScan)
    $script:form.Controls.Add($script:rModeApps)
    $script:form.Controls.Add($script:lblModeTip)
    $script:form.Controls.Add($script:gbScope)
    $script:form.Controls.Add($script:progress)
    $script:form.Controls.Add($script:lblStatus)
    $script:form.Controls.Add($script:lblFilter)
    $script:form.Controls.Add($script:txtFilter)
    $script:form.Controls.Add($script:lblCount)
    $script:form.Controls.Add($script:listView)
    $script:form.Controls.Add($script:btnSelectAll)
    $script:form.Controls.Add($script:btnInvert)
    $script:form.Controls.Add($script:btnDesktop)
    $script:form.Controls.Add($script:btnStartMenuUser)
    $script:form.Controls.Add($script:btnStartMenuAll)
    $script:form.Controls.Add($script:btnOpenDir)
    $script:form.Controls.Add($script:btnExport)
    $script:form.Controls.Add($script:lblTip)

    # ---- 状态变量 ----
    $script:AllItems = New-Object System.Collections.ArrayList
    $script:BestByKey = @{}
    $script:Scanning = $false
    $script:IconIndexByPath = @{}

    # ---- 事件 ----
    $script:btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择要扫描的目录'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:txtDir.Text = $dlg.SelectedPath
        }
    })

    $script:btnStart.Add_Click({ Start-Scan })

    $script:btnStop.Add_Click({
        if ($script:Scanning) {
            [ScanEngine]::Stop()
            $script:lblStatus.Text = '正在停止扫描，请稍候...'
        }
    })

    $script:txtFilter.Add_TextChanged({ Update-ListView })

    $script:chkOnlyProduct.Add_CheckedChanged({ Update-ListView })

    $script:btnSelectAll.Add_Click({
        foreach ($item in $script:listView.Items) { $item.Checked = $true }
    })

    $script:btnInvert.Add_Click({
        foreach ($item in $script:listView.Items) {
            if ($item.Checked) { $item.Checked = $false } else { $item.Checked = $true }
        }
    })

    $script:btnDesktop.Add_Click({ Add-Shortcuts-Common ([Environment]::GetFolderPath('Desktop')) })

    $script:btnStartMenuUser.Add_Click({ Add-Shortcuts-Common ([Environment]::GetFolderPath('Programs')) })

    $script:btnStartMenuAll.Add_Click({
        $dir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        Add-Shortcuts-Common $dir
    })

    $script:btnOpenDir.Add_Click({
        foreach ($item in $script:listView.SelectedItems) {
            $tag = $item.Tag
            if ($tag -and $tag.Path -and (Test-Path -LiteralPath $tag.Path)) {
                Start-Process explorer.exe -ArgumentList ("/select,`"$($tag.Path)`"")
            }
        }
    })

    $script:btnExport.Add_Click({ Export-Results })

    $script:form.Add_Shown({
        $drives = [System.IO.DriveInfo]::GetDrives()
        foreach ($d in $drives) {
            if ($d.DriveType -eq [System.IO.DriveType]::Fixed -and $d.IsReady) {
                [void]$script:clbDrives.Items.Add($d.Name, $true)
            }
        }
        $script:rFull.Add_CheckedChanged({ Update-Scope-UI })
        $script:rDir.Add_CheckedChanged({ Update-Scope-UI })
        $script:rModeScan.Add_CheckedChanged({ Update-Scope-UI })
        $script:rModeApps.Add_CheckedChanged({ Update-Scope-UI })
        Update-Scope-UI
    })

    $script:form.Add_FormClosing({
        if ($script:Scanning) { [ScanEngine]::Stop() }
    })

    # 扫描轮询计时器
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 300
    $script:timer.Add_Tick({ Poll-Scan })

    return $script:form
}

function Update-Scope-UI {
    $appsMode = $script:rModeApps.Checked
    $script:gbScope.Enabled = -not $appsMode
    $script:txtDir.Enabled = (-not $appsMode) -and $script:rDir.Checked
    $script:btnBrowse.Enabled = (-not $appsMode) -and $script:rDir.Checked
    $script:clbDrives.Enabled = (-not $appsMode) -and $script:rFull.Checked
    $script:lblDrives.Enabled = (-not $appsMode) -and $script:rFull.Checked
    if ($appsMode) {
        $script:btnStart.Text = '加载应用'
    } else {
        $script:btnStart.Text = '开始扫描'
    }
}

function Start-Scan {
    if ($script:Scanning) { return }
    # 已安装应用模式：直接读取与「设置 > 应用 > 已安装的应用」一致的应用列表
    if ($script:rModeApps.Checked) {
        Load-InstalledApps
        return
    }
    $roots = $null
    if ($script:rFast.Checked) {
        $roots = Get-QuickRoots
        if (-not $roots -or $roots.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('未找到常见的程序安装目录，请选择「全盘扫描」或「选择目录」。', '提示')
            return
        }
    } elseif ($script:rFull.Checked) {
        $temp = New-Object System.Collections.ArrayList
        foreach ($item in $script:clbDrives.CheckedItems) { [void]$temp.Add($item) }
        $roots = $temp
        if ($roots.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('请至少勾选一个磁盘。', '提示')
            return
        }
    } else {
        if ([string]::IsNullOrEmpty($script:txtDir.Text.Trim())) {
            [System.Windows.Forms.MessageBox]::Show('请先选择要扫描的目录。', '提示')
            return
        }
        $roots = @($script:txtDir.Text.Trim())
    }

    # 去重
    $uniq = @{}
    $roots2 = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        $key = $r.ToLowerInvariant()
        if (-not $uniq.ContainsKey($key)) { $uniq[$key] = 1; [void]$roots2.Add($r) }
    }

    $tokens = @()
    if ($script:chkExclude.Checked) { $tokens = Get-DefaultTokens }

    $script:AllItems.Clear()
    $script:BestByKey.Clear()
    $script:listView.BeginUpdate()
    $script:listView.Items.Clear()
    $script:listView.EndUpdate()
    $script:lblCount.Text = '共 0 项'

    [ScanEngine]::Start([string[]]$roots2, [string[]]$tokens, $true)

    $script:Scanning = $true
    $script:btnStart.Enabled = $false
    $script:btnStop.Enabled = $true
    $script:progress.MarqueeAnimationSpeed = 30
    $script:lblStatus.Text = '正在扫描...（可随时点击「停止」）'
    $script:timer.Start()
}

function Poll-Scan {
    if (-not $script:Scanning) { return }
    $batch = [ScanEngine]::DequeueBatch(400)
    if ($batch.Length -gt 0) { Add-ResultRows $batch }
    $script:lblStatus.Text = ('已发现 {0} 个程序，正在扫描：{1}' -f [ScanEngine]::FoundCount, [ScanEngine]::CurrentDir)
    if ([ScanEngine]::IsIdle()) {
        [ScanEngine]::Finish()
        $script:Scanning = $false
        $script:timer.Stop()
        $script:btnStart.Enabled = $true
        $script:btnStop.Enabled = $false
        $script:progress.MarqueeAnimationSpeed = 0
        Update-ListView
        $script:lblStatus.Text = ('扫描完成，共发现 {0} 个程序。勾选后即可添加桌面/开始菜单快捷方式。' -f $script:AllItems.Count)
    }
}

function Add-ResultRows {
    param($rows)
    $script:listView.BeginUpdate()
    foreach ($r in $rows) {
        if (-not (Update-BestMap $script:BestByKey $r)) { continue }
        $entry = $script:BestByKey[(Get-ProductKey $r)]
        $dispName = $r.Name
        if (-not [string]::IsNullOrEmpty($r.Product)) { $dispName = $r.Product }
        $company = ''
        if ($r.Company) { $company = [string]$r.Company }
        if ($entry.Item) {
            # 已有该产品的行：原位更新为更优的主程序，保留勾选状态
            $item = $entry.Item
            $item.Text = $dispName
            $item.SubItems[1].Text = [string]$r.Path
            $item.SubItems[2].Text = $company
            $item.SubItems[3].Text = [string]$r.Version
            $item.SubItems[4].Text = (Format-Size $r.Size)
            $item.Tag = @{ Path = $r.Path; Product = $r.Product }
            $item.ToolTipText = [string]$r.Path
        } else {
            $item = New-Object System.Windows.Forms.ListViewItem
            $item.Text = $dispName
            [void]$item.SubItems.Add([string]$r.Path)
            [void]$item.SubItems.Add($company)
            [void]$item.SubItems.Add([string]$r.Version)
            [void]$item.SubItems.Add((Format-Size $r.Size))
            $item.Tag = @{ Path = $r.Path; Product = $r.Product }
            $item.ToolTipText = [string]$r.Path
            [void]$script:AllItems.Add($item)
            $entry.Item = $item
            if (-not ($script:txtFilter.Text.Trim().Length -gt 0)) {
                [void]$script:listView.Items.Add($item)
            }
        }
    }
    $script:listView.EndUpdate()
    $script:lblCount.Text = ('共 {0} 项' -f $script:AllItems.Count)
}

# 汉字拼音数据：每条为“汉字+其拼音”连续拼接，字与拼音之间无分隔符（覆盖 GB2312 常用汉字）
$script:PinyinData = @(
        '啊a阿a埃ai挨ai哎ai唉ai哀ai皑ai癌ai蔼ai矮ai艾ai碍ai爱ai隘ai鞍an氨an安an俺an按an暗an岸an胺an案an肮ang昂ang盎ang凹ao敖ao熬ao翱ao袄ao傲ao奥ao懊ao澳ao芭ba捌ba扒ba叭ba吧ba笆ba八ba疤ba巴ba拔ba跋ba靶ba把ba耙ba坝ba霸ba罢ba爸ba白bai柏bai百bai摆bai佰bai败bai拜bai稗bai斑ban班ban搬ban扳ban般ban颁ban板ban版ban扮ban拌ban伴ban瓣ban半ban办ban绊ban邦bang帮bang梆bang榜bang膀bang绑bang棒bang磅bang蚌bang镑bang傍bang谤bang苞bao胞bao包bao褒bao剥bo薄bao雹bao保bao堡bao饱bao宝bao抱bao报bao暴bao豹bao鲍bao爆bao杯bei碑bei悲bei卑bei北bei辈bei背bei贝bei钡bei倍bei狈bei备bei惫bei焙bei被bei奔ben苯ben本ben笨ben崩beng绷beng甭beng泵beng蹦beng迸beng逼bi鼻bi比bi鄙bi笔bi彼bi碧bi蓖bi蔽bi毕bi毙bi毖bi币bi庇bi痹bi闭bi敝bi弊bi必bi辟pi壁bi臂bi避bi陛bi鞭bian边bian编bian贬bian扁bian便bian变bian卞bian辨bian辩bian辫bian遍bian标biao彪biao膘biao表biao鳖bie憋bie别bie瘪bie彬bin斌bin濒bin滨bin宾bin摈bin兵bing冰bing柄bing丙bing秉bing饼bing炳bing病bing并bing玻bo菠bo播bo拨bo钵bo波bo博bo勃bo搏bo铂bo箔bo伯bo帛bo舶bo脖bo膊bo渤bo泊po驳bo捕bu卜bo哺bu补bu埠bu不bu布bu步bu簿bu部bu怖bu擦ca猜cai裁cai材cai才cai财cai睬cai踩cai采cai彩cai菜cai蔡cai餐can参can蚕can残can惭can惨can灿can苍cang舱cang仓cang沧cang藏cang操cao糙cao槽cao曹cao草cao厕ce策ce侧ce册ce测ce层ceng蹭ceng插cha叉cha茬cha茶cha查cha碴cha搽cha察cha岔cha差cha诧cha拆chai柴chai豺chai搀chan掺can蝉chan馋chan谗chan缠chan铲chan产chan阐chan颤chan昌chang猖chang场chang尝chang常chang长zhang偿chang肠chang厂chang敞chang畅chang唱chang倡chang超chao抄chao钞chao朝chao嘲chao潮chao巢chao吵chao炒chao车che扯che撤che掣che彻che澈che郴chen臣chen辰chen尘chen晨chen忱chen沉chen陈chen趁chen衬chen撑cheng称cheng城cheng橙cheng成cheng呈cheng乘cheng程cheng惩cheng澄cheng诚cheng承cheng逞cheng骋cheng秤cheng吃chi痴chi持chi匙shi池chi迟chi弛chi驰chi耻chi齿chi侈chi'
        '尺chi赤chi翅chi斥chi炽chi充chong冲chong虫chong崇chong宠chong抽chou酬chou畴chou踌chou稠chou愁chou筹chou仇chou绸chou瞅chou丑chou臭chou初chu出chu橱chu厨chu躇chu锄chu雏chu滁chu除chu楚chu础chu储chu矗chu搐chu触chu处chu揣chuai川chuan穿chuan椽chuan传chuan船chuan喘chuan串chuan疮chuang窗chuang幢chuang床chuang闯chuang创chuang吹chui炊chui捶chui锤chui垂chui春chun椿chun醇chun唇chun淳chun纯chun蠢chun戳chuo绰chuo疵ci茨ci磁ci雌ci辞ci慈ci瓷ci词ci此ci刺ci赐ci次ci聪cong葱cong囱cong匆cong从cong丛cong凑cou粗cu醋cu簇cu促cu蹿cuan篡cuan窜cuan摧cui崔cui催cui脆cui瘁cui粹cui淬cui翠cui村cun存cun寸cun磋cuo撮cuo搓cuo措cuo挫cuo错cuo搭da达da答da瘩da打da大da呆dai歹dai傣dai戴dai带dai殆dai代dai贷dai袋dai待dai逮dai怠dai耽dan担dan丹dan单dan郸dan掸dan胆dan旦dan氮dan但dan惮dan淡dan诞dan弹dan蛋dan当dang挡dang党dang荡dang档dang刀dao捣dao蹈dao倒dao岛dao祷dao导dao到dao稻dao悼dao道dao盗dao德de得de的de蹬deng灯deng登deng等deng瞪deng凳deng邓deng堤di低di滴di迪di敌di笛di狄di涤di翟di嫡di抵di底di地di蒂di第di帝di弟di递di缔di颠dian掂dian滇dian碘dian点dian典dian靛dian垫dian电dian佃dian甸dian店dian惦dian奠dian淀dian殿dian碉diao叼diao雕diao凋diao刁diao掉diao吊diao钓diao调diao跌die爹die碟die蝶die迭die谍die叠die丁ding盯ding叮ding钉ding顶ding鼎ding锭ding定ding订ding丢diu东dong冬dong董dong懂dong动dong栋dong侗dong恫dong冻dong洞dong兜dou抖dou斗dou陡dou豆dou逗dou痘dou都dou督du毒du犊du独du读du堵du睹du赌du杜du镀du肚du度du渡du妒du端duan短duan锻duan段duan断duan缎duan堆dui兑dui队dui对dui墩dun吨dun蹲dun敦dun顿dun囤dun钝dun盾dun遁dun掇duo哆duo多duo夺duo垛duo躲duo朵duo跺duo舵duo剁duo惰duo堕duo蛾e峨e鹅e俄e额e讹e娥e恶e厄e扼e遏e鄂e饿e恩en而er儿er耳er尔er饵er洱er二er贰er发fa罚fa筏fa伐fa乏fa阀fa法fa珐fa藩fan帆fan番fan翻fan樊fan矾fan钒fan繁fan凡fan烦fan反fan返fan范fan贩fan犯fan饭fan泛fan'
        '坊fang芳fang方fang肪fang房fang防fang妨fang仿fang访fang纺fang放fang菲fei非fei啡fei飞fei肥fei匪fei诽fei吠fei肺fei废fei沸fei费fei芬fen酚fen吩fen氛fen分fen纷fen坟fen焚fen汾fen粉fen奋fen份fen忿fen愤fen粪fen丰feng封feng枫feng蜂feng峰feng锋feng风feng疯feng烽feng逢feng冯feng缝feng讽feng奉feng凤feng佛fu否fou夫fu敷fu肤fu孵fu扶fu拂fu辐fu幅fu氟fu符fu伏fu俘fu服fu浮fu涪fu福fu袱fu弗fu甫fu抚fu辅fu俯fu釜fu斧fu脯pu腑fu府fu腐fu赴fu副fu覆fu赋fu复fu傅fu付fu阜fu父fu腹fu负fu富fu讣fu附fu妇fu缚fu咐fu噶ga嘎ga该gai改gai概gai钙gai盖gai溉gai干gan甘gan杆gan柑gan竿gan肝gan赶gan感gan秆gan敢gan赣gan冈gang刚gang钢gang缸gang肛gang纲gang岗gang港gang杠gang篙gao皋gao高gao膏gao羔gao糕gao搞gao镐gao稿gao告gao哥ge歌ge搁ge戈ge鸽ge胳ge疙ge割ge革ge葛ge格ge蛤ha阁ge隔ge铬ge个ge各ge给gei根gen跟gen耕geng更geng庚geng羹geng埂geng耿geng梗geng工gong攻gong功gong恭gong龚gong供gong躬gong公gong宫gong弓gong巩gong汞gong拱gong贡gong共gong钩gou勾gou沟gou苟gou狗gou垢gou构gou购gou够gou辜gu菇gu咕gu箍gu估gu沽gu孤gu姑gu鼓gu古gu蛊gu骨gu谷gu股gu故gu顾gu固gu雇gu刮gua瓜gua剐gua寡gua挂gua褂gua乖guai拐guai怪guai棺guan关guan官guan冠guan观guan管guan馆guan罐guan惯guan灌guan贯guan光guang广guang逛guang瑰gui规gui圭gui硅gui归gui龟gui闺gui轨gui鬼gui诡gui癸gui桂gui柜gui跪gui贵gui刽gui辊gun滚gun棍gun锅guo郭guo国guo果guo裹guo过guo哈ha骸hai孩hai海hai氦hai亥hai害hai骇hai酣han憨han邯han韩han含han涵han寒han函han喊han罕han翰han撼han捍han旱han憾han悍han焊han汗han汉han夯hang杭hang航hang壕hao嚎hao豪hao毫hao郝hao好hao耗hao号hao浩hao呵he喝he荷he菏he核he禾he和he何he合he盒he貉hao阂he河he涸he赫he褐he鹤he贺he嘿hei黑hei痕hen很hen狠hen恨hen哼heng亨heng横heng衡heng恒heng轰hong哄hong烘hong虹hong鸿hong洪hong宏hong弘hong红hong喉hou侯hou猴hou吼hou厚hou候hou后hou呼hu乎hu忽hu瑚hu壶hu葫hu胡hu蝴hu狐hu糊hu湖hu弧hu虎hu唬hu护hu互hu沪hu'
        '户hu花hua哗hua华hua猾hua滑hua画hua划hua化hua话hua槐huai徊huai怀huai淮huai坏huai欢huan环huan桓huan还hai缓huan换huan患huan唤huan痪huan豢huan焕huan涣huan宦huan幻huan荒huang慌huang黄huang磺huang蝗huang簧huang皇huang凰huang惶huang煌huang晃huang幌huang恍huang谎huang灰hui挥hui辉hui徽hui恢hui蛔hui回hui毁hui悔hui慧hui卉hui惠hui晦hui贿hui秽hui会hui烩hui汇hui讳hui诲hui绘hui荤hun昏hun婚hun魂hun浑hun混hun豁huo活huo伙huo火huo获huo或huo惑huo霍huo货huo祸huo击ji圾ji基ji机ji畸ji稽ji积ji箕ji肌ji饥ji迹ji激ji讥ji鸡ji姬ji绩ji缉ji吉ji极ji棘ji辑ji籍ji集ji及ji急ji疾ji汲ji即ji嫉ji级ji挤ji几ji脊ji己ji蓟ji技ji冀ji季ji伎ji祭ji剂ji悸ji济ji寄ji寂ji计ji记ji既ji忌ji际ji妓ji继ji纪ji嘉jia枷jia夹jia佳jia家jia加jia荚jia颊jia贾jia甲jia钾jia假jia稼jia价jia架jia驾jia嫁jia歼jian监jian坚jian尖jian笺jian间jian煎jian兼jian肩jian艰jian奸jian缄jian茧jian检jian柬jian碱jian硷jian拣jian捡jian简jian俭jian剪jian减jian荐jian槛kan鉴jian践jian贱jian见jian键jian箭jian件jian健jian舰jian剑jian饯jian渐jian溅jian涧jian建jian僵jiang姜jiang将jiang浆jiang江jiang疆jiang蒋jiang桨jiang奖jiang讲jiang匠jiang酱jiang降jiang蕉jiao椒jiao礁jiao焦jiao胶jiao交jiao郊jiao浇jiao骄jiao娇jiao嚼jue搅jiao铰jiao矫jiao侥jiao脚jiao狡jiao角jiao饺jiao缴jiao绞jiao剿jiao教jiao酵jiao轿jiao较jiao叫jiao窖jiao揭jie接jie皆jie秸jie街jie阶jie截jie劫jie节jie桔ju杰jie捷jie睫jie竭jie洁jie结jie解jie姐jie戒jie藉ji芥jie界jie借jie介jie疥jie诫jie届jie巾jin筋jin斤jin金jin今jin津jin襟jin紧jin锦jin仅jin谨jin进jin靳jin晋jin禁jin近jin烬jin浸jin尽jin劲jin荆jing兢jing茎jing睛jing晶jing鲸jing京jing惊jing精jing粳jing经jing井jing警jing景jing颈jing静jing境jing敬jing镜jing径jing痉jing靖jing竟jing竞jing净jing炯jiong窘jiong揪jiu究jiu纠jiu玖jiu韭jiu久jiu灸jiu九jiu酒jiu厩jiu救jiu旧jiu臼jiu舅jiu咎jiu就jiu疚jiu'
        '鞠ju拘ju狙ju疽ju居ju驹ju菊ju局ju咀ju矩ju举ju沮ju聚ju拒ju据ju巨ju具ju距ju踞ju锯ju俱ju句ju惧ju炬ju剧ju捐juan鹃juan娟juan倦juan眷juan卷juan绢juan撅jue攫jue抉jue掘jue倔jue爵jue觉jue决jue诀jue绝jue均jun菌jun钧jun军jun君jun峻jun俊jun竣jun浚jun郡jun骏jun喀ka咖ka卡ka咯ge开kai揩kai楷kai凯kai慨kai刊kan堪kan勘kan坎kan砍kan看kan康kang慷kang糠kang扛kang抗kang亢kang炕kang考kao拷kao烤kao靠kao坷ke苛ke柯ke棵ke磕ke颗ke科ke壳ke咳ke可ke渴ke克ke刻ke客ke课ke肯ken啃ken垦ken恳ken坑keng吭keng空kong恐kong孔kong控kong抠kou口kou扣kou寇kou枯ku哭ku窟ku苦ku酷ku库ku裤ku夸kua垮kua挎kua跨kua胯kua块kuai筷kuai侩kuai快kuai宽kuan款kuan匡kuang筐kuang狂kuang框kuang矿kuang眶kuang旷kuang况kuang亏kui盔kui岿kui窥kui葵kui奎kui魁kui傀gui馈kui愧kui溃kui坤kun昆kun捆kun困kun括kuo扩kuo廓kuo阔kuo垃la拉la喇la蜡la腊la辣la啦la莱lai来lai赖lai蓝lan婪lan栏lan拦lan篮lan阑lan兰lan澜lan谰lan揽lan览lan懒lan缆lan烂lan滥lan琅lang榔lang狼lang廊lang郎lang朗lang浪lang捞lao劳lao牢lao老lao佬lao姥lao酪lao烙lao涝lao勒lei乐le雷lei镭lei蕾lei磊lei累lei儡lei垒lei擂lei肋le类lei泪lei棱leng楞leng冷leng厘li梨li犁li黎li篱li狸li离li漓li理li李li里li鲤li礼li莉li荔li吏li栗li丽li厉li励li砾li历li利li傈li例li俐li痢li立li粒li沥li隶li力li璃li哩li俩lia联lian莲lian连lian镰lian廉lian怜lian涟lian帘lian敛lian脸lian链lian恋lian炼lian练lian粮liang凉liang梁liang粱liang良liang两liang辆liang量liang晾liang亮liang谅liang撩liao聊liao僚liao疗liao燎liao寥liao辽liao潦lao了le撂liao镣liao廖liao料liao列lie裂lie烈lie劣lie猎lie琳lin林lin磷lin霖lin临lin邻lin鳞lin淋lin凛lin赁lin吝lin拎lin玲ling菱ling零ling龄ling铃ling伶ling羚ling凌ling灵ling陵ling岭ling领ling另ling令ling溜liu琉liu榴liu硫liu馏liu留liu刘liu瘤liu流liu柳liu六liu龙long聋long咙long笼long窿long隆long垄long拢long陇long楼lou娄lou搂lou篓lou漏lou陋lou芦lu卢lu颅lu庐lu'
        '炉lu掳lu卤lu虏lu鲁lu麓lu碌lu露lu路lu赂lu鹿lu潞lu禄lu录lu陆lu戮lu驴lv吕lv铝lv侣lv旅lv履lv屡lv缕lv虑lv氯lv律lv率lv滤lv绿lv峦luan挛luan孪luan滦luan卵luan乱luan掠lve略lve抡lun轮lun伦lun仑lun沦lun纶lun论lun萝luo螺luo罗luo逻luo锣luo箩luo骡luo裸luo落luo洛luo骆luo络luo妈ma麻ma玛ma码ma蚂ma马ma骂ma嘛ma吗ma埋mai买mai麦mai卖mai迈mai脉mai瞒man馒man蛮man满man蔓man曼man慢man漫man谩man芒mang茫mang盲mang氓mang忙mang莽mang猫mao茅mao锚mao毛mao矛mao铆mao卯mao茂mao冒mao帽mao貌mao贸mao么me玫mei枚mei梅mei酶mei霉mei煤mei没mei眉mei媒mei镁mei每mei美mei昧mei寐mei妹mei媚mei门men闷men们men萌meng蒙meng檬meng盟meng锰meng猛meng梦meng孟meng眯mi醚mi靡mi糜mi迷mi谜mi弥mi米mi秘mi觅mi泌mi蜜mi密mi幂mi棉mian眠mian绵mian冕mian免mian勉mian娩mian缅mian面mian苗miao描miao瞄miao藐miao秒miao渺miao庙miao妙miao蔑mie灭mie民min抿min皿min敏min悯min闽min明ming螟ming鸣ming铭ming名ming命ming谬miu摸mo摹mo蘑mo模mo膜mo磨mo摩mo魔mo抹mo末mo莫mo墨mo默mo沫mo漠mo寞mo陌mo谋mou牟mou某mou拇mu牡mu亩mu姆mu母mu墓mu暮mu幕mu募mu慕mu木mu目mu睦mu牧mu穆mu拿na哪na呐na钠na那na娜na纳na氖nai乃nai奶nai耐nai奈nai南nan男nan难nan囊nang挠nao脑nao恼nao闹nao淖nao呢ne馁nei内nei嫩nen能neng妮ni霓ni倪ni泥ni尼ni拟ni你ni匿ni腻ni逆ni溺ni蔫nian拈nian年nian碾nian撵nian捻nian念nian娘niang酿niang鸟niao尿niao捏nie聂nie孽nie啮nie镊nie镍nie涅nie您nin柠ning狞ning凝ning宁ning拧ning泞ning牛niu扭niu钮niu纽niu脓nong浓nong农nong弄nong奴nu努nu怒nu女nv暖nuan虐nve疟nve挪nuo懦nuo糯nuo诺nuo哦o欧ou鸥ou殴ou藕ou呕ou偶ou沤ou啪pa趴pa爬pa帕pa怕pa琶pa拍pai排pai牌pai徘pai湃pai派pai攀pan潘pan盘pan磐pan盼pan畔pan判pan叛pan乓pang庞pang旁pang耪pang胖pang抛pao咆pao刨pao炮pao袍pao跑pao泡pao呸pei胚pei培pei裴pei赔pei陪pei配pei佩pei沛pei喷pen盆pen砰peng抨peng烹peng澎peng彭peng蓬peng棚peng硼peng篷peng膨peng朋peng鹏peng捧peng碰peng坯pi砒pi霹pi批pi披pi劈pi'
        '琵pi毗pi啤pi脾pi疲pi皮pi匹pi痞pi僻pi屁pi譬pi篇pian偏pian片pian骗pian飘piao漂piao瓢piao票piao撇pie瞥pie拼pin频pin贫pin品pin聘pin乒ping坪ping苹ping萍ping平ping凭ping瓶ping评ping屏ping坡po泼po颇po婆po破po魄po迫po粕po剖pou扑pu铺pu仆pu莆pu葡pu菩pu蒲pu埔pu朴pu圃pu普pu浦pu谱pu曝pu瀑pu期qi欺qi栖qi戚qi妻qi七qi凄qi漆qi柒qi沏qi其qi棋qi奇qi歧qi畦qi崎qi脐qi齐qi旗qi祈qi祁qi骑qi起qi岂qi乞qi企qi启qi契qi砌qi器qi气qi迄qi弃qi汽qi泣qi讫qi掐qia恰qia洽qia牵qian扦qian钎qian铅qian千qian迁qian签qian仟qian谦qian乾qian黔qian钱qian钳qian前qian潜qian遣qian浅qian谴qian堑qian嵌qian欠qian歉qian枪qiang呛qiang腔qiang羌qiang墙qiang蔷qiang强qiang抢qiang橇qiao锹qiao敲qiao悄qiao桥qiao瞧qiao乔qiao侨qiao巧qiao鞘qiao撬qiao翘qiao峭qiao俏qiao窍qiao切qie茄jia且qie怯qie窃qie钦qin侵qin亲qin秦qin琴qin勤qin芹qin擒qin禽qin寝qin沁qin青qing轻qing氢qing倾qing卿qing清qing擎qing晴qing氰qing情qing顷qing请qing庆qing琼qiong穷qiong秋qiu丘qiu邱qiu球qiu求qiu囚qiu酋qiu泅qiu趋qu区qu蛆qu曲qu躯qu屈qu驱qu渠qu取qu娶qu龋qu趣qu去qu圈quan颧quan权quan醛quan泉quan全quan痊quan拳quan犬quan券quan劝quan缺que炔gui瘸que却que鹊que榷que确que雀que裙qun群qun然ran燃ran冉ran染ran瓤rang壤rang攘rang嚷rang让rang饶rao扰rao绕rao惹re热re壬ren仁ren人ren忍ren韧ren任ren认ren刃ren妊ren纫ren扔reng仍reng日ri戎rong茸rong蓉rong荣rong融rong熔rong溶rong容rong绒rong冗rong揉rou柔rou肉rou茹ru蠕ru儒ru孺ru如ru辱ru乳ru汝ru入ru褥ru软ruan阮ruan蕊rui瑞rui锐rui闰run润run若ruo弱ruo撒sa洒sa萨sa腮sai鳃sai塞sai赛sai三san叁san伞san散san桑sang嗓sang丧sang搔sao骚sao扫sao嫂sao瑟se色se涩se森sen僧seng莎sha砂sha杀sha刹sha沙sha纱sha傻sha啥sha煞sha筛shai晒shai珊shan苫shan杉shan山shan删shan煽shan衫shan闪shan陕shan擅shan赡shan膳shan善shan汕shan扇shan缮shan墒shang伤shang商shang赏shang晌shang上shang尚shang裳shang梢shao捎shao稍shao'
        '烧shao芍shao勺shao韶shao少shao哨shao邵shao绍shao奢she赊she蛇she舌she舍she赦she摄she射she慑she涉she社she设she砷shen申shen呻shen伸shen身shen深shen娠shen绅shen神shen沈shen审shen婶shen甚shen肾shen慎shen渗shen声sheng生sheng甥sheng牲sheng升sheng绳sheng省sheng盛sheng剩sheng胜sheng圣sheng师shi失shi狮shi施shi湿shi诗shi尸shi虱shi十shi石shi拾shi时shi什shen食shi蚀shi实shi识shi史shi矢shi使shi屎shi驶shi始shi式shi示shi士shi世shi柿shi事shi拭shi誓shi逝shi势shi是shi嗜shi噬shi适shi仕shi侍shi释shi饰shi氏shi市shi恃shi室shi视shi试shi收shou手shou首shou守shou寿shou授shou售shou受shou瘦shou兽shou蔬shu枢shu梳shu殊shu抒shu输shu叔shu舒shu淑shu疏shu书shu赎shu孰shu熟shu薯shu暑shu曙shu署shu蜀shu黍shu鼠shu属shu术shu述shu树shu束shu戍shu竖shu墅shu庶shu数shu漱shu恕shu刷shua耍shua摔shuai衰shuai甩shuai帅shuai栓shuan拴shuan霜shuang双shuang爽shuang谁shui水shui睡shui税shui吮shun瞬shun顺shun舜shun说shuo硕shuo朔shuo烁shuo斯si撕si嘶si思si私si司si丝si死si肆si寺si嗣si四si伺ci似shi饲si巳si松song耸song怂song颂song送song宋song讼song诵song搜sou艘sou擞sou嗽sou苏su酥su俗su素su速su粟su僳su塑su溯su宿su诉su肃su酸suan蒜suan算suan虽sui隋sui随sui绥sui髓sui碎sui岁sui穗sui遂sui隧sui祟sui孙sun损sun笋sun蓑suo梭suo唆suo缩suo琐suo索suo锁suo所suo塌ta他ta它ta她ta塔ta獭ta挞ta蹋ta踏ta胎tai苔tai抬tai台tai泰tai酞tai太tai态tai汰tai坍tan摊tan贪tan瘫tan滩tan坛tan檀tan痰tan潭tan谭tan谈tan坦tan毯tan袒tan碳tan探tan叹tan炭tan汤tang塘tang搪tang堂tang棠tang膛tang唐tang糖tang倘tang躺tang淌tang趟tang烫tang掏tao涛tao滔tao绦tao萄tao桃tao逃tao淘tao陶tao讨tao套tao特te藤teng腾teng疼teng誊teng梯ti剔ti踢ti锑ti提ti题ti蹄ti啼ti体ti替ti嚏ti惕ti涕ti剃ti屉ti天tian添tian填tian田tian甜tian恬tian舔tian腆tian挑tiao条tiao迢tiao眺tiao跳tiao贴tie铁tie帖tie厅ting听ting烃ting汀ting廷ting停ting亭ting'
        '庭ting挺ting艇ting通tong桐tong酮tong瞳tong同tong铜tong彤tong童tong桶tong捅tong筒tong统tong痛tong偷tou投tou头tou透tou凸tu秃tu突tu图tu徒tu途tu涂tu屠tu土tu吐tu兔tu湍tuan团tuan推tui颓tui腿tui蜕tui褪tui退tui吞tun屯tun臀tun拖tuo托tuo脱tuo鸵tuo陀tuo驮tuo驼tuo椭tuo妥tuo拓tuo唾tuo挖wa哇wa蛙wa洼wa娃wa瓦wa袜wa歪wai外wai豌wan弯wan湾wan玩wan顽wan丸wan烷wan完wan碗wan挽wan晚wan皖wan惋wan宛wan婉wan万wan腕wan汪wang王wang亡wang枉wang网wang往wang旺wang望wang忘wang妄wang威wei巍wei微wei危wei韦wei违wei桅wei围wei唯wei惟wei为wei潍wei维wei苇wei萎wei委wei伟wei伪wei尾wei纬wei未wei蔚wei味wei畏wei胃wei喂wei魏wei位wei渭wei谓wei尉wei慰wei卫wei瘟wen温wen蚊wen文wen闻wen纹wen吻wen稳wen紊wen问wen嗡weng翁weng瓮weng挝wo蜗wo涡wo窝wo我wo斡wo卧wo握wo沃wo巫wu呜wu钨wu乌wu污wu诬wu屋wu无wu芜wu梧wu吾wu吴wu毋wu武wu五wu捂wu午wu舞wu伍wu侮wu坞wu戊wu雾wu晤wu物wu勿wu务wu悟wu误wu昔xi熙xi析xi西xi硒xi矽xi晰xi嘻xi吸xi锡xi牺xi稀xi息xi希xi悉xi膝xi夕xi惜xi熄xi烯xi溪xi汐xi犀xi檄xi袭xi席xi习xi媳xi喜xi铣xi洗xi系xi隙xi戏xi细xi瞎xia虾xia匣xia霞xia辖xia暇xia峡xia侠xia狭xia下xia厦sha夏xia吓xia掀xian锨xian先xian仙xian鲜xian纤xian咸xian贤xian衔xian舷xian闲xian涎xian弦xian嫌xian显xian险xian现xian献xian县xian腺xian馅xian羡xian宪xian陷xian限xian线xian相xiang厢xiang镶xiang香xiang箱xiang襄xiang湘xiang乡xiang翔xiang祥xiang详xiang想xiang响xiang享xiang项xiang巷xiang橡xiang像xiang向xiang象xiang萧xiao硝xiao霄xiao削xue哮xiao嚣xiao销xiao消xiao宵xiao淆xiao晓xiao小xiao孝xiao校xiao肖xiao啸xiao笑xiao效xiao楔xie些xie歇xie蝎xie鞋xie协xie挟xie携xie邪xie斜xie胁xie谐xie写xie械xie卸xie蟹xie懈xie泄xie泻xie谢xie屑xie薪xin芯xin锌xin欣xin辛xin新xin忻xin心xin信xin衅xin星xing腥xing猩xing惺xing兴xing刑xing型xing形xing邢xing行xing醒xing幸xing杏xing性xing姓xing兄xiong凶xiong胸xiong匈xiong汹xiong雄xiong'
        '熊xiong休xiu修xiu羞xiu朽xiu嗅xiu锈xiu秀xiu袖xiu绣xiu墟xu戌xu需xu虚xu嘘xu须xu徐xu许xu蓄xu酗xu叙xu旭xu序xu畜chu恤xu絮xu婿xu绪xu续xu轩xuan喧xuan宣xuan悬xuan旋xuan玄xuan选xuan癣xuan眩xuan绚xuan靴xue薛xue学xue穴xue雪xue血xue勋xun熏xun循xun旬xun询xun寻xun驯xun巡xun殉xun汛xun训xun讯xun逊xun迅xun压ya押ya鸦ya鸭ya呀ya丫ya芽ya牙ya蚜ya崖ya衙ya涯ya雅ya哑ya亚ya讶ya焉yan咽yan阉yan烟yan淹yan盐yan严yan研yan蜒yan岩yan延yan言yan颜yan阎yan炎yan沿yan奄yan掩yan眼yan衍yan演yan艳yan堰yan燕yan厌yan砚yan雁yan唁yan彦yan焰yan宴yan谚yan验yan殃yang央yang鸯yang秧yang杨yang扬yang佯yang疡yang羊yang洋yang阳yang氧yang仰yang痒yang养yang样yang漾yang邀yao腰yao妖yao瑶yao摇yao尧yao遥yao窑yao谣yao姚yao咬yao舀yao药yao要yao耀yao椰ye噎ye耶ye爷ye野ye冶ye也ye页ye掖ye业ye叶ye曳ye腋ye夜ye液ye一yi壹yi医yi揖yi铱yi依yi伊yi衣yi颐yi夷yi遗yi移yi仪yi胰yi疑yi沂yi宜yi姨yi彝yi椅yi蚁yi倚yi已yi乙yi矣yi以yi艺yi抑yi易yi邑yi屹yi亿yi役yi臆yi逸yi肄yi疫yi亦yi裔yi意yi毅yi忆yi义yi益yi溢yi诣yi议yi谊yi译yi异yi翼yi翌yi绎yi茵yin荫yin因yin殷yin音yin阴yin姻yin吟yin银yin淫yin寅yin饮yin尹yin引yin隐yin印yin英ying樱ying婴ying鹰ying应ying缨ying莹ying萤ying营ying荧ying蝇ying迎ying赢ying盈ying影ying颖ying硬ying映ying哟yo拥yong佣yong臃yong痈yong庸yong雍yong踊yong蛹yong咏yong泳yong涌yong永yong恿yong勇yong用yong幽you优you悠you忧you尤you由you邮you铀you犹you油you游you酉you有you友you右you佑you釉you诱you又you幼you迂yu淤yu于yu盂yu榆yu虞yu愚yu舆yu余yu俞yu逾yu鱼yu愉yu渝yu渔yu隅yu予yu娱yu雨yu与yu屿yu禹yu宇yu语yu羽yu玉yu域yu芋yu郁yu吁xu遇yu喻yu峪yu御yu愈yu欲yu狱yu育yu誉yu浴yu寓yu裕yu预yu豫yu驭yu鸳yuan渊yuan冤yuan元yuan垣yuan袁yuan原yuan援yuan辕yuan园yuan员yuan圆yuan猿yuan源yuan缘yuan远yuan苑yuan愿yuan怨yuan院yuan曰yue约yue越yue跃yue钥yao岳yue粤yue月yue悦yue阅yue耘yun云yun郧yun匀yun陨yun允yun运yun蕴yun酝yun晕yun韵yun孕yun匝za砸za'
        '杂za栽zai哉zai灾zai宰zai载zai再zai在zai咱zan攒zan暂zan赞zan赃zang脏zang葬zang遭zao糟zao凿zao藻zao枣zao早zao澡zao蚤zao躁zao噪zao造zao皂zao灶zao燥zao责ze择ze则ze泽ze贼zei怎zen增zeng憎zeng曾ceng赠zeng扎zha喳zha渣zha札zha轧ya铡zha闸zha眨zha栅zha榨zha咋za乍zha炸zha诈zha摘zhai斋zhai宅zhai窄zhai债zhai寨zhai瞻zhan毡zhan詹zhan粘zhan沾zhan盏zhan斩zhan辗nian崭zhan展zhan蘸zhan栈zhan占zhan战zhan站zhan湛zhan绽zhan樟zhang章zhang彰zhang漳zhang张zhang掌zhang涨zhang杖zhang丈zhang帐zhang账zhang仗zhang胀zhang瘴zhang障zhang招zhao昭zhao找zhao沼zhao赵zhao照zhao罩zhao兆zhao肇zhao召zhao遮zhe折zhe哲zhe蛰zhe辙zhe者zhe锗zhe蔗zhe这zhe浙zhe珍zhen斟zhen真zhen甄zhen砧zhen臻zhen贞zhen针zhen侦zhen枕zhen疹zhen诊zhen震zhen振zhen镇zhen阵zhen蒸zheng挣zheng睁zheng征zheng狰zheng争zheng怔zheng整zheng拯zheng正zheng政zheng帧zhen症zheng郑zheng证zheng芝zhi枝zhi支zhi吱zhi蜘zhi知zhi肢zhi脂zhi汁zhi之zhi织zhi职zhi直zhi植zhi殖zhi执zhi值zhi侄zhi址zhi指zhi止zhi趾zhi只zhi旨zhi纸zhi志zhi挚zhi掷zhi至zhi致zhi置zhi帜zhi峙zhi制zhi智zhi秩zhi稚zhi质zhi炙zhi痔zhi滞zhi治zhi窒zhi中zhong盅zhong忠zhong钟zhong衷zhong终zhong种zhong肿zhong重zhong仲zhong众zhong舟zhou周zhou州zhou洲zhou诌zhou粥zhou轴zhou肘zhou帚zhou咒zhou皱zhou宙zhou昼zhou骤zhou珠zhu株zhu蛛zhu朱zhu猪zhu诸zhu诛zhu逐zhu竹zhu烛zhu煮zhu拄zhu瞩zhu嘱zhu主zhu著zhu柱zhu助zhu蛀zhu贮zhu铸zhu筑zhu住zhu注zhu祝zhu驻zhu抓zhua爪zhao拽zhuai专zhuan砖zhuan转zhuan撰zhuan赚zhuan篆zhuan桩zhuang庄zhuang装zhuang妆zhuang撞zhuang壮zhuang状zhuang椎chui锥zhui追zhui赘zhui坠zhui缀zhui谆zhun准zhun捉zhuo拙zhuo卓zhuo桌zhuo琢zuo茁zhuo酌zhuo啄zhuo着zhe灼zhuo浊zhuo兹zi咨zi资zi姿zi滋zi淄zi孜zi紫zi仔zai籽zi滓zi子zi自zi渍zi字zi鬃zong棕zong踪zong宗zong综zong总zong纵zong邹zou走zou奏zou揍zou租zu足zu卒zu族zu祖zu诅zu阻zu'
        '组zu钻zuan纂zuan嘴zui醉zui最zui罪zui尊zun遵zun昨zuo左zuo佐zuo柞zha做zuo作zuo坐zuo座zuo亍chu丌ji兀wu丐gai廿nian卅sa丕pi亘gen丞cheng鬲ge孬nao噩e丨gun禺yu丿pie匕bi乇tuo夭yao爻yao卮zhi氐di囟xin胤yin馗kui毓yu睾gao鼗tao丶zhu亟ji鼐nai乜mie乩ji亓qi芈mi孛bei啬se嘏gu仄ze厍she厝cuo厣yan厥jue厮si靥ye赝yan匚fang叵po匦gui匮kui匾bian赜ze卦gua卣you刂dao刈yi刎wen刭jing刳ku刿gui剀kai剌la剞ji剡shan剜wan蒯kuai剽piao劂jue劁qiao劐huo劓yi冂jiong罔wang亻ren仃ding仉zhang仂le仨sa仡ge仫mu仞ren伛yu仳pi伢ya佤wa仵wu伥chang伧cang伉kang伫zhu佞ning佧ka攸you佚yi佝gou佟tong佗tuo伲ni伽ga佶ji佴er侑you侉kua侃kan侏zhu佾yi佻tiao侪chai佼jiao侬nong侔mou俦chou俨yan俪li俅qiu俚li俣yu俜ping俑yong俟qi俸feng倩qian偌ruo俳pai倬zhuo倏shu倮luo倭wo俾bi倜ti倌guan倥kong倨ju偾fen偃yan偕xie偈ji偎wei偬zong偻lou傥tang傧bin傩nuo傺chi僖xi儆jing僭jian僬jiao僦jiu僮tong儇xuan儋dan仝tong氽tun佘she佥qian俎zu龠yue汆cuan籴di兮xi巽xun黉hong馘guo冁chan夔kui勹bao匍pu訇hong匐fu凫fu夙su兕si亠tou兖yan亳bo衮gun袤mao亵xie脔luan裒pou禀bing嬴ying蠃luo羸lei冫bing冱hu冽lie冼xian凇song冖mi冢zhong冥ming讠yan讦jie讧hong讪shan讴ou讵ju讷ne诂gu诃he诋di诏zhao诎qu诒yi诓kuang诔lei诖gua诘ji诙hui诜shen诟gou诠quan诤zheng诨hun诩xu诮qiao诰gao诳kuang诶ei诹zou诼zhuo诿wei谀yu谂shen谄chan谇sui谌chen谏jian谑xue谒ye谔e谕yu谖xuan谙an谛di谘zi谝pian谟mo谠dang谡su谥shi谧mi谪zhe谫jian谮zen谯qiao谲jue谳yan谵zhan谶chen卩jie卺jin阝fu阢wu阡qian阱jing阪ban阽dian阼zuo陂bei陉xing陔gai陟zhi陧nie陬zou陲chui陴pi隈wei隍huang隗kui隰xi邗han邛qiong邝kuang邙mang邬wu邡fang邴bing邳pi邶bei邺ye邸di邰tai郏jia郅zhi邾zhu郐kuai郄qie郇huan郓yun郦li郢ying郜gao郗xi郛fu郫pi郯tan郾yan鄄juan鄢yan鄞yin鄣zhang鄱po鄯shan鄹zou酃ling酆feng刍chu奂huan劢mai劬qu劭shao劾he哿ge勐meng勖xu勰xie叟sou燮xie矍jue廴yin凵qian凼dang鬯chang厶si弁bian畚ben巯qiu坌ben垩e'
        '垡fa塾shu墼ji壅yong壑he圩wei圬wu圪ge圳zhen圹kuang圮pi圯yi坜li圻qi坂ban坩gan垅long坫dian垆lu坼che坻chi坨tuo坭ni坶mu坳ao垭ya垤die垌dong垲kai埏shan垧shang垴nao垓gai垠yin埕cheng埘shi埚guo埙xun埒lie垸yuan埴zhi埯an埸yi埤pi埝nian堋peng堍tu埽sao埭dai堀ku堞die堙yin塄leng堠hou塥ge塬yuan墁man墉yong墚liang墀chi馨xin鼙pi懿yi艹cao艽jiao艿nai芏du芊qian芨ji芄wan芎qiong芑qi芗xiang芙fu芫yan芸yun芾fei芰ji苈li苊e苣ju芘pi芷zhi芮rui苋xian苌chang苁cong芩qin芴wu芡qian芪qi芟shan苄bian苎zhu芤kou苡yi茉mo苷gan苤pie茏long茇ba苜mu苴ju苒ran苘qing茌chi苻fu苓ling茑niao茚yin茆mao茔ying茕qiong苠min苕shao茜qian荑ti荛rao荜bi茈ci莒ju茼tong茴hui茱zhu莛ting荞qiao茯fu荏ren荇xing荃quan荟hui荀xun茗ming荠ji茭jiao茺chong茳jiang荦luo荥xing荨xun茛gen荩jin荬mai荪sun荭hong荮zhou莰kan荸bi莳shi莴wo莠you莪e莓mei莜you莅li荼tu莶xian莩fu荽sui莸you荻di莘shen莞guan莨lang莺ying莼chun菁jing萁qi菥xi菘song堇jin萘nai萋qi菝ba菽shu菖chang萜tie萸yu萑huan萆bi菔fu菟tu萏dan萃cui菸yan菹ju菪dang菅jian菀wan萦ying菰gu菡han葜qia葑feng葚ren葙xiang葳wei蒇chan蒈kai葺qi蒉kui葸xi萼e葆bao葩pa葶ting蒌lou蒎pai萱xuan葭jia蓁zhen蓍shi蓐ru蓦mo蒽en蓓bei蓊weng蒿hao蒺ji蓠li蒡bang蒹jian蒴shuo蒗lang蓥ying蓣yu蔌su甍meng蔸dou蓰xi蔹lian蔟cu蔺lin蕖qu蔻kou蓿xu蓼liao蕙hui蕈xun蕨jue蕤rui蕞zui蕺ji瞢meng蕃fan蕲qi蕻hong薤xie薨hong薇wei薏yi蕹weng薮sou薜bi薅hao薹tai薷ru薰xun藓xian藁gao藜li藿huo蘧qu蘅heng蘩fan蘖nie蘼mi廾gong弈yi夼kuang奁lian耷da奕yi奚xi奘zang匏pao尢you尥liao尬ga尴gan扌shou扪men抟tuan抻chen拊fu拚pan拗ao拮jie挢jiao拶za挹yi捋lv捃jun掭tian揶ye捱ai捺na掎ji掴guai捭bai掬ju掊pou捩lie掮qian掼guan揲die揸zha揠ya揿qin揄yu揞an揎xuan摒bing揆kui掾yuan摅shu摁en搋chuai搛jian搠shuo搌zhan搦nuo搡sang摞luo撄ying摭zhi撖han摺zhe撷xie撸lu撙zun撺cuan擀gan擐huan擗pi擤xing擢zhuo攉huo攥zuan攮nang弋yi忒te甙dai弑shi卟bu叱chi叽ji'
        '叩kou叨dao叻le吒zha吖ya吆yao呋fu呒wu呓yi呔dai呖li呃e吡bi呗bei呙guo吣qin吲yin咂za咔ka呷ga呱gu呤ling咚dong咛ning咄duo呶nao呦you咝si哐kuang咭ji哂shen咴hui哒da咧lie咦yi哓xiao哔bi呲ci咣guang哕hui咻xiu咿yi哌pai哙kuai哚duo哜ji咩mie咪mi咤zha哝nong哏gen哞mou唛ma哧chi唠lao哽geng唔wu哳zha唢suo唣zao唏xi唑zuo唧ji唪feng啧ze喏nuo喵miao啉lin啭zhuan啁zhao啕tao唿hu啐cui唼sha唷yo啖dan啵bo啶ding啷lang唳li唰shua啜chuai喋die嗒da喃nan喱li喹kui喈jie喁yong喟kui啾jiu嗖sou喑yin啻chi嗟jie喽lou喾ku喔o喙hui嗪qin嗷ao嗉su嘟du嗑ke嗫nie嗬he嗔chen嗦suo嗝ge嗄a嗯n嗥hao嗲die嗳ai嗌ai嗍suo嗨hai嗵tong嗤chi辔pei嘞lei嘈cao嘌piao嘁qi嘤ying嘣beng嗾sou嘀di嘧mi嘭peng噘jue嘹liao噗pu嘬chuai噍jiao噢o噙qin噜lu噌ceng噔deng嚆hao噤jin噱jue噫yi噻sai噼pi嚅ru嚓ca嚯huo囔nang囗wei囝jian囡nan囵lun囫hu囹ling囿you圄yu圊qing圉yu圜huan帏wei帙zhi帔pei帑tang帱chou帻ze帼guo帷wei幄wo幔man幛zhang幞fu幡fan岌ji屺qi岍qian岐qi岖qu岈ya岘xian岙ao岑cen岚lan岜ba岵hu岢ke岽dong岬jia岫xiu岱dai岣gou峁mao岷min峄yi峒dong峤jiao峋xun峥zheng崂lao崃lai崧song崦yan崮gu崤xiao崞guo崆kong崛jue嵘rong崾yao崴wai崽zai嵬wei嵛yu嵯cuo嵝lou嵫zi嵋mei嵊sheng嵩song嵴ji嶂zhang嶙lin嶝deng豳bin嶷yi巅dian彳chi彷pang徂cu徇xun徉yang後hou徕lai徙xi徜chang徨huang徭yao徵zheng徼jiao衢qu彡shan犭quan犰qiu犴an犷guang犸ma狃niu狁yun狎xia狍pao狒fei狨rong狯kuai狩shou狲sun狴bi狷juan猁li狳yu猃xian狺yin狻suan猗yi猓guo猡luo猊ni猞she猝cu猕mi猢hu猹cha猥wei猬wei猸mei猱nao獐zhang獍jing獗jue獠liao獬xie獯xun獾huan舛chuan夥huo飧sun夤yin夂zhi饣shi饧tang饨tun饩xi饪ren饫yu饬chi饴yi饷xiang饽bo馀yu馄hun馇cha馊sou馍mo馐xiu馑jin馓san馔zhuan馕nang庀pi庑wu庋gui庖pao庥xiu庠xiang庹tuo庵an庾yu庳bi赓geng廒ao廑jin廛chan廨xie廪lin膺ying忄xin忉dao忖cun忏chan怃wu忮zhi怄ou忡chong忤wu忾kai怅chang怆chuang忪song忭bian忸niu怙hu怵chu怦peng怛da怏yang怍zuo怩ni怫fu怊chao怿yi'
        '怡yi恸tong恹yan恻ce恺kai恂xun恪ke恽yun悖bei悚song悭qian悝kui悃kun悒yi悌ti悛quan惬qie悻xing悱fei惝chang惘wang惆chou惚hu悴cui愠yun愦kui愕e愣leng惴zhui愀qiao愎bi愫su慊qian慵yong憬jing憔qiao憧chong憷chu懔lin懵meng忝tian隳hui闩shuan闫yan闱wei闳hong闵min闶kang闼ta闾lv阃kun阄jiu阆lang阈yu阊chang阋xi阌wen阍hun阏e阒qu阕que阖he阗tian阙que阚han丬qiang爿pan戕qiang氵shui汔qi汜si汊cha沣feng沅yuan沐mu沔mian沌dun汨mi汩gu汴bian汶wen沆hang沩wei泐le泔gan沭shu泷long泸lu泱yang泗si沲tuo泠ling泖mao泺luo泫xuan泮pan沱tuo泓hong泯min泾jing洹huan洧wei洌lie浃jia浈zhen洇yin洄hui洙zhu洎ji洫xu浍hui洮tao洵xun洚jiang浏liu浒hu浔xun洳ru涑su浯wu涞lai涠wei浞zhuo涓juan涔cen浜bang浠xi浼mei浣huan渚zhu淇qi淅xi淞song渎du涿zhuo淠pi渑mian淦gan淝fei淙cong渖shen涫guan渌lu涮shuan渫xie湮yan湎mian湫jiao溲sou湟huang溆xu湓pen湔jian渲xuan渥wo湄mei滟yan溱qin溘ke滠she漭mang滢ying溥pu溧li溽ru溻ta溷hun滗bi溴xiu滏fu溏tang滂pang溟ming潢huang潆ying潇xiao漤lan漕cao滹hu漯luo漶huan潋lian潴zhu漪yi漉lu漩xuan澉gan澍shu澌si潸shan潲shao潼tong潺chan濑lai濉sui澧li澹dan澶chan濂lian濡ru濮pu濞bi濠hao濯zhuo瀚han瀣xie瀛ying瀹yue瀵fen灏hao灞ba宀mian宄gui宕dang宓mi宥you宸chen甯ning骞qian搴qian寤wu寮liao褰qian寰huan蹇jian謇jian辶chuo迓ya迕wu迥jiong迮ze迤yi迩er迦jia迳jing迨dai逅hou逄pang逋bu逦li逑qiu逍xiao逖ti逡qun逵kui逶wei逭huan逯lu遄chuan遑huang遒qiu遐xia遨ao遘gou遢ta遛liu暹xian遴lin遽ju邂xie邈miao邃sui邋la彐ji彗hui彖tuan彘zhi尻kao咫zhi屐ji屙e孱can屣xi屦ju羼chan弪jing弩nu弭mi艴fu弼bi鬻yu屮che妁shuo妃fei妍yan妩wu妪yu妣bi妗jin姊zi妫gui妞niu妤yu姒si妲da妯zhou姗shan妾qie娅ya娆rao姝shu娈luan姣jiao姘pin姹cha娌li娉ping娲wa娴xian娑suo娣di娓wei婀e婧jing婊biao婕jie娼chang婢bi婵chan胬nu媪ao媛yuan婷ting婺wu媾gou嫫mo媲pi嫒ai嫔pin媸chi嫠li嫣yan嫱qiang嫖piao嫦chang嫘lei嫜zhang嬉xi嬗shan嬖bi嬲niao嬷ma'
        '孀shuang尕ga尜ga孚fu孥nu孳zi孑jie孓jue孢bao驵zang驷si驸fu驺zou驿yi驽nu骀dai骁xiao骅hua骈pian骊li骐qi骒ke骓zhui骖can骘zhi骛wu骜ao骝liu骟shan骠biao骢cong骣chan骥ji骧xiang纟si纡yu纣zhou纥ge纨wan纩kuang纭yun纰pi纾shu绀gan绁xie绂fu绉zhou绋fu绌chu绐dai绔ku绗hang绛jiang绠geng绡xiao绨ti绫ling绮qi绯fei绱shang绲gun缍duo绶shou绺liu绻quan绾wan缁zi缂ke缃xiang缇ti缈miao缋hui缌si缏bian缑gou缒zhui缗min缙jin缜zhen缛ru缟gao缡li缢yi缣jian缤bin缥piao缦man缧lei缪mou缫sao缬xie缭liao缯zeng缰jiang缱qian缲qiao缳huan缵zuan幺yao畿ji巛chuan甾zai邕yong玎ding玑ji玮wei玢bin玟wen珏jue珂ke珑long玷dian玳dai珀po珉min珈jia珥er珙gong顼xu琊ya珩hang珧yao珞luo玺xi珲hui琏lian琪qi瑛ying琦qi琥hu琨kun琰yan琮cong琬wan琛chen琚ju瑁mao瑜yu瑗yuan瑕xia瑙nao瑷ai瑭tang瑾jin璜huang璎ying璀cui璁cong璇xuan璋zhang璞pu璨can璩qu璐lu璧bi瓒zan璺wen韪wei韫yun韬tao杌wu杓biao杞qi杈cha杩ma枥li枇pi杪miao杳yao枘rui枧jian杵chu枨cheng枞cong枭xiao枋fang杷pa杼zhu柰nai栉zhi柘zhe栊long柩jiu枰ping栌lu柙xia枵xiao柚you枳zhi柝tuo栀zhi柃ling枸gou柢di栎li柁duo柽cheng栲kao栳lao桠ya桡rao桎zhi桢zhen桄guang桤qi梃ting栝gua桕jiu桦hua桁heng桧gui桀jie栾luan桊juan桉an栩xu梵fan梏gu桴fu桷jue梓zi桫suo棂ling楮chu棼fen椟du椠qian棹zhao椤luo棰chui椋liang椁guo楗jian棣di椐ju楱zou椹shen楠nan楂zha楝lian榄lan楫ji榀pin榘ju楸qiu椴duan槌chui榇chen榈lv槎cha榉ju楦xuan楣mei楹ying榛zhen榧fei榻ta榫sun榭xie槔gao榱cui槁gao槊shuo槟bin榕rong槠zhu榍xie槿jin樯qiang槭qi樗chu樘tang橥zhu槲hu橄gan樾yue檠qing橐tuo橛jue樵qiao檎qin橹lu樽zun樨xi橘ju橼yuan檑lei檐yan檩lin檗bo檫cha猷you獒ao殁mo殂cu殇shang殄tian殒yun殓lian殍piao殚dan殛ji殡bin殪yi轫ren轭e轱gu轲ke轳lu轵zhi轶yi轸zhen轷hu轹li轺yao轼shi轾zhi辁quan辂lu辄zhe辇nian辋wang辍chuo辎zi辏cou辘lu辚lin軎wei戋jian戗qiang戛jia戟ji戢ji戡kan戥deng戤gai戬jian臧zang瓯ou瓴ling瓿bu甏beng甑zeng'
        '甓pi攴pu旮ga旯la旰gan昊hao昙tan杲gao昃ze昕xin昀yun炅jiong曷he昝zan昴mao昱yu昶chang昵ni耆qi晟cheng晔ye晁chao晏yan晖hui晡bu晗han晷gui暄xuan暌kui暧ai暝ming暾tun曛xun曜yao曦xi曩nang贲ben贳shi贶kuang贻yi贽zhi赀zi赅gai赆jin赈zhen赉lai赇qiu赍ji赕dan赙fu觇chan觊ji觋xi觌di觎yu觏gou觐jin觑qu牮jian犟jiang牝pin牦mao牯gu牾wu牿gu犄ji犋ju犍jian犏pian犒kao挈qie挲sa掰bai搿ge擘bai耄mao毪mu毳cui毽jian毵san毹shu氅chang氇lu氆pu氍qu氕pie氘dao氙xian氚chuan氡dong氩ya氤yin氪ke氲yun攵pu敕chi敫jiao牍du牒die牖you爰yuan虢guo刖yue肟wo肜rong肓huang肼jing朊ruan肽tai肱gong肫zhun肭na肴yao肷qian胧long胨dong胩ka胪lu胛jia胂shen胄zhou胙zuo胍gua胗zhen朐qu胝zhi胫jing胱guang胴dong胭yan脍kuai脎sa胲hai胼pian朕zhen脒mi豚tun脶luo脞cuo脬pao脘wan脲niao腈jing腌yan腓fei腴yu腙zong腚ding腱jian腠cou腩nan腼mian腽wa腭e腧shu塍cheng媵ying膈ge膂lv膑bin滕teng膣zhi膪chuai臌gu朦meng臊sao膻shan臁lian膦lin欤yu欷xi欹yi歃sha歆xin歙she飑biao飒sa飓ju飕sou飙biao飚biao殳shu彀gou毂gu觳hu斐fei齑ji斓lan於yu旆pei旄mao旃zhan旌jing旎ni旒liu旖yi炀yang炜wei炖dun炝qiang炻shi烀hu炷zhu炫xuan炱tai烨ye烊yang焐wu焓han焖men焯chao焱yan煳hu煜yu煨wei煅duan煲bao煊xuan煸bian煺tui熘liu熳man熵shang熨yun熠yi燠yu燔fan燧sui燹xian爝jue爨cuan灬biao焘dao煦xu熹xi戾li戽hu扃jiong扈hu扉fei礻shi祀si祆xian祉zhi祛qu祜hu祓fu祚zuo祢mi祗zhi祠ci祯zhen祧tiao祺qi禅chan禊xi禚zhuo禧xi禳rang忑te忐tan怼dui恝jia恚hui恧nv恁nen恙yang恣zi悫que愆qian愍min慝te憩qi憝dui懋mao懑men戆gang肀yu聿yu沓da泶xue淼miao矶ji矸gan砀dang砉huo砗che砘dun砑ya斫zhuo砭bian砜feng砝fa砹ai砺li砻long砟zha砼tong砥di砬la砣tuo砩fu硎xing硭mang硖xia硗qiao砦zhai硐dong硇nao硌ge硪wo碛qi碓dui碚bei碇ding碜chen碡du碣jie碲di碹xuan碥bian磔zhe磙gun磉sang磬qing磲qu礅dun磴deng礓jiang礤ca礞meng礴bo龛kan黹zhi黻fu黼fu盱xu眄mian眍kou盹dun眇miao眈dan眚sheng眢yuan眙yi眭sui眦zi眵chi'
        '眸mou睐lai睑jian睇di睃suo睚ya睨ni睢sui睥pi睿rui瞍sou睽kui瞀mao瞌ke瞑ming瞟piao瞠cheng瞰kan瞵lin瞽gu町ting畀bi畎quan畋tian畈fan畛zhen畲she畹wan疃tuan罘fu罡gang罟gu詈li罨yan罴pi罱lan罹li羁ji罾zeng盍he盥guan蠲juan钅jin钆ga钇yi钋po钊zhao钌liao钍tu钏chuan钐shan钔men钗chai钕nv钚bu钛tai钜ju钣ban钤qian钫fang钪kang钭tou钬huo钯ba钰yu钲zheng钴gu钶ke钷po钸bu钹bo钺yue钼mu钽tan钿dian铄shuo铈shi铉xuan铊ta铋bi铌ni铍pi铎duo铐kao铑lao铒er铕you铖cheng铗jia铙nao铘ye铛dang铞diao铟yin铠kai铢zhu铤ding铥diu铧hua铨quan铪ha铩sha铫diao铮zheng铯se铳chong铴tang铵an铷ru铹lao铼lai铽te铿keng锃zeng锂li锆gao锇e锉cuo锊lve锍liu锎kai锏jian锒lang锓qin锔ju锕a锖qiang锘nuo锛ben锝de锞ke锟kun锢gu锪huo锫pei锩juan锬tan锱zi锲qie锴kai锶si锷e锸cha锼sou锾huan锿ai镂lou锵qiang镄fei镅mei镆mo镉ge镌juan镎na镏liu镒yi镓jia镔bin镖biao镗tang镘man镙luo镛yong镞zu镟xuan镝di镡chan镢jue镤pu镥lu镦dui镧lan镨pu镩cuan镪qiang镫deng镬huo镯zhuo镱yi镲cha镳biao锺zhong矧shen矬cuo雉zhi秕bi秭zi秣mo秫shu稆lv嵇ji稃fu稂lang稞ke稔ren稹zhen稷ji穑se黏nian馥fu穰rang皈gui皎jiao皓hao皙xi皤po瓞die瓠hu甬yong鸠jiu鸢yuan鸨bao鸩zhen鸪gu鸫dong鸬lu鸲qu鸱chi鸶si鸸er鸷zhi鸹gua鸺xiu鸾luan鹁bo鹂li鹄gu鹆yu鹇xian鹈ti鹉wu鹋miao鹌an鹎bei鹑chun鹕hu鹗e鹚ci鹛mei鹜wu鹞yao鹣jian鹦ying鹧zhe鹨liu鹩liao鹪jiao鹫jiu鹬yu鹱hu鹭lu鹳guan疒ne疔ding疖jie疠li疝shan疬li疣you疳gan疴ke疸dan痄zha疱pao疰zhu痃xuan痂jia痖ya痍yi痣zhi痨lao痦wu痤cuo痫xian痧sha瘃zhu痱fei痼gu痿wei瘐yu瘀yu瘅dan瘌la瘗yi瘊hou瘥chai瘘lou瘕jia瘙sao瘛chi瘼mo瘢ban瘠ji癀huang瘭biao瘰luo瘿ying瘵zhai癃long瘾yin瘳chou癍ban癞lai癔yi癜dian癖pi癫dian癯qu翊yi竦song穸xi穹qiong窀zhun窆bian窈yao窕tiao窦dou窠ke窬yu窨xun窭ju窳yu衤yi衩cha衲na衽ren衿jin袂mei袢pan裆dang袷jia袼ge裉ken裢lian裎cheng裣lian裥jian裱biao褚chu裼ti裨bi裾ju裰duo褡da褙bei褓bao褛lv褊bian褴lan褫chi褶zhe襁qiang襦ru襻pan'
        '疋pi胥xu皲jun皴cun矜jin耒lei耔zi耖chao耜si耠huo耢lao耥tang耦ou耧lou耩jiang耨nou耱mo耋die耵ding聃dan聆ling聍ning聒gua聩kui聱ao覃tan顸han颀qi颃hang颉jie颌he颍ying颏ke颔han颚e颛zhuan颞nie颟man颡sang颢hao颥ru颦pin虍hu虔qian虬qiu虮ji虿chai虺hui虼ge虻meng蚨fu蚍pi蚋rui蚬xian蚝hao蚧jie蚣gong蚪dou蚓yin蚩chi蚶han蛄gu蚵he蛎li蚰you蚺ran蚱zha蚯qiu蛉ling蛏cheng蚴you蛩qiong蛱jia蛲nao蛭zhi蛳si蛐qu蜓ting蛞kuo蛴qi蛟jiao蛘yang蛑mou蜃shen蜇zhe蛸shao蜈wu蜊li蜍chu蜉fu蜣qiang蜻qing蜞qi蜥xi蜮yu蜚fei蜾guo蝈guo蜴yi蜱pi蜩tiao蜷quan蜿wan螂lang蜢meng蝽chun蝾rong蝻nan蝠fu蝰kui蝌ke蝮fu螋sou蝓yu蝣you蝼lou蝤qiu蝙bian蝥mao螓qin螯ao螨man蟒mang蟆ma螈yuan螅xi螭chi螗tang螃pang螫shi蟥huang螬cao螵piao螳tang蟋xi蟓xiang螽zhong蟑zhang蟀shuai蟊mao蟛peng蟪hui蟠pan蟮shan蠖huo蠓meng蟾chan蠊lian蠛mie蠡li蠹du蠼qu缶fou罂ying罄qing罅xia舐shi竺zhu竽yu笈ji笃du笄ji笕jian笊zhao笫zi笏hu筇qiong笸po笪da笙sheng笮ze笱gou笠li笥si笤tiao笳jia笾bian笞chi筘kou筚bi筅xian筵yan筌quan筝zheng筠yun筮shi筻gang筢pa筲shao筱xiao箐qing箦ze箧qie箸zhu箬ruo箝qian箨tuo箅bi箪dan箜kong箢yuan箫xiao箴zhen篑kui篁huang篌hou篝gou篚fei篥li篦bi篪chi簌su篾mie篼dou簏lu簖duan簋gui簟dian簪zan簦deng簸bo籁lai籀zhou臾yu舁yu舂chong舄xi臬nie衄nv舡chuan舢shan舣yi舭bi舯zhong舨ban舫fang舸ge舻lu舳zhu舴ze舾xi艄shao艉wei艋meng艏shou艚cao艟chong艨meng衾qin袅niao袈jia裘qiu裟sha襞bi羝di羟qiang羧suo羯jie羰tang羲xi籼xian敉mi粑ba粝li粜tiao粞xi粢zi粲can粼lin粽zong糁san糇hou糌zan糍ci糈xu糅rou糗qiu糨jiang艮gen暨ji羿yi翎ling翕xi翥zhu翡fei翦jian翩pian翮he翳yi糸mi絷zhi綦qi綮qi繇yao纛dao麸fu麴qu赳jiu趄ju趔lie趑zi趱zan赧nan赭zhe豇jiang豉shi酊ding酐gan酎zhou酏yi酤gu酢cu酡tuo酰xian酩ming酯zhi酽yan酾shai酲cheng酴tu酹lei醌kun醅pei醐hu醍ti醑xu醢hai醣tang醪lao醭bu醮jiao醯xi醵ju醴li醺xun豕shi鹾cuo趸dun跫qiong踅xue蹙cu蹩bie趵bao趿ta趼jian'
        '趺fu跄qiang跖zhi跗fu跚shan跞li跎tuo跏jia跛bo跆tai跬kui跷qiao跸bi跣xian跹xian跻ji跤jiao踉liang跽ji踔chuo踝huai踟chi踬zhi踮dian踣bo踯zhi踺jian蹀die踹chuai踵zhong踽ju踱duo蹉cuo蹁pian蹂rou蹑nie蹒pan蹊qi蹰chu蹶jue蹼pu蹯fan蹴cu躅zhu躏lin躔chan躐lie躜zuan躞xie豸zhi貂diao貊mo貅xiu貘mo貔pi斛hu觖jue觞shang觚gu觜zi觥gong觫su觯zhi訾zi謦qing靓jing雩yu雳li雯wen霆ting霁ji霈pei霏fei霎sha霪yin霭ai霰xian霾mai龀chen龃ju龅bao龆tiao龇zi龈ken龉yu龊chuo龌wo黾min鼋yuan鼍tuo隹zhui隼sun隽juan雎ju雒luo瞿qu雠chou銎qiong銮luan鋈wu錾zan鍪mou鏊ao鎏liu鐾bei鑫xin鱿you鲂fang鲅ba鲆ping鲇nian鲈lu稣su鲋fu鲎hou鲐tai鲑gui鲒jie鲔wei鲕er鲚ji鲛jiao鲞xiang鲟xun鲠geng鲡li鲢lian鲣jian鲥shi鲦tiao鲧gun鲨sha鲩huan鲫ji鲭qing鲮ling鲰zou鲱fei鲲kun鲳chang鲴gu鲵ni鲶nian鲷diao鲺shi鲻zi鲼fen鲽die鳄e鳅qiu鳆fu鳇huang鳊bian鳋sao鳌ao鳍qi鳎ta鳏guan鳐yao鳓le鳔biao鳕xue鳗man鳘min鳙yong鳜gui鳝shan鳟zun鳢li靼da鞅yang鞑da鞒qiao鞔man鞯jian鞫ju鞣rou鞲gou鞴bei骱jie骰tou骷ku鹘gu骶di骺hou骼ge髁ke髀bi髅lou髂qia髋kuan髌bin髑du魅mei魃ba魇yan魉liang魈xiao魍wang魑chi飨xiang餍yan餮tie饕tao饔yong髟biao髡kun髦mao髯ran髫tiao髻ji髭zi髹xiu鬈quan鬏jiu鬓bin鬟huan鬣lie麽mo麾hui縻mi麂ji麇jun麈zhu麋mi麒qi鏖ao麝she麟lin黛dai黜chu黝you黠xia黟yi黢qu黩du黧li黥qing黪can黯an鼢fen鼬you鼯wu鼹yan鼷xi鼽qiu鼾han齄zha'
)

# 汉字拼音表：每条数据形如“字拼音”，字与拼音之间无需分隔符，
# 运行时按“一个汉字 + 其后连续的 ASCII 字母”切分。覆盖 GB2312 常用汉字。
function Get-PinyinTable {
    if ($script:PinyinTable) { return $script:PinyinTable }
    $t = @{}
    foreach ($chunk in $script:PinyinData) {
        $chars = $chunk.ToCharArray()
        $i = 0
        $n = $chars.Length
        while ($i -lt $n) {
            $key = [string]$chars[$i]
            $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $n -and [int]$chars[$i] -lt 0x80) {
                [void]$sb.Append($chars[$i])
                $i++
            }
            $t[$key] = $sb.ToString()
        }
    }
    $script:PinyinTable = $t
    return $t
}

# 取字符串里汉字的拼音全拼与首字母（非汉字忽略），用于搜索时按拼音匹配中文名
function Get-SearchKeys {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return @('', '') }
    $tbl = Get-PinyinTable
    $py = New-Object System.Text.StringBuilder
    $ini = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 0x4E00 -and $code -le 0x9FFF) {
            $k = [string]$ch
            $p = ''
            if ($tbl.ContainsKey($k)) { $p = [string]$tbl[$k] }
            if ($p.Length -gt 0) {
                [void]$py.Append($p)
                [void]$ini.Append($p.Substring(0, 1))
            }
        }
    }
    return @($py.ToString(), $ini.ToString())
}

# 常见应用的“中文名 / 英文名 / 拼音”对照，用于搜索时中英文互通
$script:AliasGroups = @(
    @('微信', 'wechat', 'weixin'),
    @('企业微信', 'wecom', 'wxwork', 'qywx'),
    @('微信开发者工具', 'wechatdevtools', 'wedeveloper'),
    @('钉钉', 'dingtalk'),
    @('腾讯', 'tencent'),
    @('腾讯会议', 'wemeet', 'tencentmeeting'),
    @('腾讯qq', 'tencentqq', 'qq'),
    @('网易', 'netease'),
    @('网易云音乐', 'cloudmusic', 'neteasecloudmusic'),
    @('火绒', 'huorong'),
    @('百度', 'baidu'),
    @('百度网盘', 'baidunetdisk', 'netdisk'),
    @('夸克', 'quark'),
    @('阿里云盘', 'aliyundrive', 'alipan'),
    @('迅雷', 'thunder', 'xunlei'),
    @('哔哩哔哩', 'bilibili'),
    @('知乎', 'zhihu'),
    @('小红书', 'xiaohongshu', 'rednote'),
    @('淘宝', 'taobao'),
    @('支付宝', 'alipay'),
    @('抖音', 'douyin', 'tiktok'),
    @('剪映', 'capcut', 'jianying'),
    @('飞书', 'feishu', 'lark'),
    @('字节跳动', 'bytedance'),
    @('金山', 'kingsoft'),
    @('金山办公', 'wps', 'wpsoffice'),
    @('搜狗', 'sogou'),
    @('向日葵', 'sunlogin', 'oray'),
    @('美图', 'meitu'),
    @('快手', 'kuaishou'),
    @('滴滴', 'didi'),
    @('美团', 'meituan'),
    @('京东', 'jingdong'),
    @('拼多多', 'pinduoduo', 'pdd'),
    @('高德', 'amap', 'gaode'),
    @('百度地图', 'baidumap'),
    @('火狐', 'firefox'),
    @('谷歌', 'google'),
    @('微软', 'microsoft'),
    @('360安全卫士', '360safe'),
    @('鲁大师', 'ludashi')
)

# 关键字命中任一对照项时，返回该组的全部写法作为备选关键字
function Get-AliasKeywords {
    param([string]$kw)
    $out = @()
    if ($kw.Length -lt 2) { return $out }
    foreach ($g in $script:AliasGroups) {
        $hit = $false
        foreach ($t in $g) {
            if ($t.Length -lt 2) { continue }
            if ($t -eq $kw -or $t.IndexOf($kw) -ge 0) { $hit = $true; break }
            if ($kw.Length -ge 4 -and $kw.IndexOf($t) -ge 0) { $hit = $true; break }
        }
        if ($hit) {
            foreach ($t in $g) { if ($t.Length -ge 2) { $out += $t } }
        }
    }
    return $out
}

# 全角字符转半角（全角字母/数字/符号换算，全角空格转普通空格），用于搜索时忽略全角/半角差异
function ConvertTo-HalfWidth {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x3000) { [void]$sb.Append(' ') }
        elseif ($code -ge 0xFF01 -and $code -le 0xFF5E) { [void]$sb.Append([char]($code - 0xFEE0)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Update-ListView {
    $script:listView.BeginUpdate()
    $script:listView.Items.Clear()
    $kw = (ConvertTo-HalfWidth $script:txtFilter.Text.Trim()).ToLowerInvariant()
    $onlyProduct = $script:chkOnlyProduct.Checked
    $altKw = @()
    $usePinyin = $false
    if ($kw.Length -gt 0) {
        $altKw = Get-AliasKeywords $kw
        if ($kw -match '^[a-z0-9]+$') { $usePinyin = $true }
    }
    $shown = 0
    foreach ($item in $script:AllItems) {
        $tag = $item.Tag
        $ok = $true
        if ($onlyProduct) {
            $prod = ''
            if ($tag -and $tag.Product) { $prod = [string]$tag.Product }
            if ([string]::IsNullOrEmpty($prod)) { $ok = $false }
        }
        if ($ok -and $kw.Length -gt 0) {
            $name = (ConvertTo-HalfWidth $item.Text).ToLowerInvariant()
            $path = (ConvertTo-HalfWidth ([string]$item.SubItems[1].Text)).ToLowerInvariant()
            $hit = ($name.IndexOf($kw) -ge 0) -or ($path.IndexOf($kw) -ge 0)
            if (-not $hit) {
                foreach ($a in $altKw) {
                    if ($name.IndexOf($a) -ge 0 -or $path.IndexOf($a) -ge 0) { $hit = $true; break }
                }
            }
            if (-not $hit -and $usePinyin) {
                $keys = Get-SearchKeys $name
                foreach ($k in $keys) {
                    if ($k.Length -gt 0 -and $k.IndexOf($kw) -ge 0) { $hit = $true; break }
                }
            }
            if (-not $hit) { $ok = $false }
        }
        if ($ok) {
            [void]$script:listView.Items.Add($item)
            $shown++
        }
    }
    $script:listView.EndUpdate()
    $script:lblCount.Text = ('共 {0} 项，显示 {1} 项' -f $script:AllItems.Count, $shown)
}

function Add-Shortcuts-Common {
    param([string]$DestDir)
    if ($script:listView.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先勾选要恢复的程序。', '提示')
        return
    }
    if (-not (Test-Path -LiteralPath $DestDir)) {
        [System.Windows.Forms.MessageBox]::Show('目标目录不存在：' + $DestDir + "`n`n如为「所有用户」开始菜单，请尝试以管理员身份运行本程序。", '提示')
        return
    }
    $ok = 0
    $fail = 0
    foreach ($item in $script:listView.CheckedItems) {
        $tag = $item.Tag
        if (-not $tag) { $fail++; continue }
        $path = $tag.Path
        if (-not (Test-Path -LiteralPath $path)) { $fail++; continue }
        $baseName = $item.Text
        if ([string]::IsNullOrEmpty($baseName)) { $baseName = [System.IO.Path]::GetFileNameWithoutExtension($path) }
        try {
            $lnk = New-Shortcut $path $DestDir $baseName
            if ($lnk) { $ok++ } else { $fail++ }
        } catch {
            $fail++
        }
    }
    [System.Windows.Forms.MessageBox]::Show(('完成：成功创建 {0} 个快捷方式，失败 {1} 个。' -f $ok, $fail), '结果')
}

function Export-Results {
    if ($script:AllItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('没有可导出的结果，请先扫描。', '提示')
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV 文件 (*.csv)|*.csv'
    $dlg.FileName = '快捷方式恢复结果.csv'
    if ($dlg.ShowDialog($script:form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('Name,Path,Company,Version,SizeKB')
    foreach ($item in $script:AllItems) {
        $tag = $item.Tag
        if (-not $tag) { continue }
        $sizeKb = 0
        try { $sizeKb = [math]::Round([long]((Get-Item -LiteralPath $tag.Path -ErrorAction SilentlyContinue).Length) / 1KB, 1) } catch { }
        [void]$sb.AppendLine(('"{0}","{1}","{2}","{3}",{4}' -f $item.Text, $tag.Path, $item.SubItems[2].Text, $item.SubItems[3].Text, $sizeKb))
    }
    [System.IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    [System.Windows.Forms.MessageBox]::Show('已导出：' + $dlg.FileName, '完成')
}

# ---------------- 已安装应用（应用模式） ----------------
# 口径对齐「设置 > 应用 > 已安装的应用」：读取注册表 Uninstall 键（64/32 位 + 当前用户），
# 每个条目定位其主可执行程序并提取应用图标，只保留能创建快捷方式的独立应用。

function Get-UninstallRoots {
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall')
    [void]$roots.Add('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')
    # 64 位进程下补读 32 位应用视图（WOW6432Node），否则 32 位软件会缺失
    if ([IntPtr]::Size -eq 8) {
        [void]$roots.Add('HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    }
    return $roots
}

# 是否属于「独立应用」（与系统设置口径一致：排除系统组件、子组件、更新补丁）
function Test-IsStandaloneApp {
    param($p)
    $dn = ''
    if ($p.DisplayName) { $dn = [string]$p.DisplayName }
    $dn = $dn.Trim()
    if ($dn.Length -eq 0) { return $false }
    if ([string]$p.SystemComponent -eq '1') { return $false }
    if ($p.ParentKeyName) { return $false }
    $rt = ''
    if ($p.ReleaseType) { $rt = [string]$p.ReleaseType }
    if ($rt -eq 'Hotfix' -or $rt -eq 'Update' -or $rt -eq 'Security Update' -or $rt -eq 'Driver') { return $false }
    if ($dn -match '^KB\d{4,}') { return $false }
    if ($dn -match 'Update for Windows|Security Update|Definition Update|Windows Malicious Software|Visual C\+\+ 20.* Redistributable|Desktop Runtime|\.NET.*Runtime|WebView2|Universal CRT') { return $false }
    return $true
}

# 解析 DisplayIcon（可能带引号/图标序号），返回可用的图标源路径（exe/ico/dll），不存在则返回空串
function Resolve-DisplayIconPath {
    param([string]$di)
    if ([string]::IsNullOrEmpty($di)) { return '' }
    $s = $di.Trim()
    $s = $s -replace '^"', '' -replace '"$', ''
    if ($s.IndexOf(',') -ge 0) { $s = ($s -split ',')[0] }
    $s = $s.Trim()
    if ($s.Length -eq 0) { return '' }
    try { if (Test-Path -LiteralPath $s -ErrorAction SilentlyContinue) { return $s } } catch { }
    return ''
}

# 该 exe 是否适合作为「主启动程序」：排除卸载器/安装器/辅助进程/系统缓存目录里的程序
function Test-MainExeName {
    param([string]$exe)
    if ([string]::IsNullOrEmpty($exe)) { return $false }
    $n = ([System.IO.Path]::GetFileName($exe)).ToLowerInvariant()
    if ($n -match 'setup|^unins|^uninstall|^msiexec|^install') { return $false }
    if ($n -match 'drvinst|installhelper|uninstaller') { return $false }
    if (Test-HelperName $n) { return $false }
    $lp = $exe.ToLowerInvariant()
    if ($lp.IndexOf('\installer\') -ge 0 -or $lp.IndexOf('\package cache\') -ge 0) { return $false }
    return $true
}

# 在安装目录（含一级子目录）里挑选最像「图形界面主程序」的 exe
function Find-MainExeInDir {
    param([string]$dir)
    $best = $null
    $bestScore = -999999
    $dirs = New-Object System.Collections.ArrayList
    [void]$dirs.Add($dir)
    try {
        foreach ($s in [System.IO.Directory]::GetDirectories($dir)) { [void]$dirs.Add($s) }
    } catch { }
    foreach ($d in $dirs) {
        $files = $null
        try { $files = [System.IO.Directory]::GetFiles($d, '*.exe') } catch { }
        if (-not $files) { continue }
        foreach ($f in $files) {
            $name = [System.IO.Path]::GetFileName($f)
            if (-not (Test-MainExeName $f)) { continue }
            if (Test-BuiltIn $f) { continue }
            $isGui = $false
            try { $isGui = [ScanEngine]::PeIsGui($f) } catch { $isGui = $true }
            if (-not $isGui) { continue }
            $r = @{ Path = $f; Name = $name; Product = ''; Company = ''; Version = ''; Size = 0 }
            $score = Get-MainScore $r
            if ($score -gt $bestScore) { $bestScore = $score; $best = $f }
        }
    }
    return $best
}

# 从 Start Menu / Desktop 快捷方式扫描备用应用列表（覆盖注册表缺失场景）
function Get-AppsFromShortcuts {
    $apps = New-Object System.Collections.ArrayList
    $searchPaths = @(
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu'),
        [Environment]::GetFolderPath('Desktop'),
        'C:\Users\Public\Desktop'
    )
    $seen = @{}
    foreach ($p in $searchPaths) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $items = Get-ChildItem -LiteralPath $p -Filter '*.lnk' -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $lnk = $shell.CreateShortcut($item.FullName)
                    $target = $lnk.TargetPath
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null } catch {}
                    if ([string]::IsNullOrEmpty($target)) { continue }
                    if (-not (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue)) { continue }
                    if ([System.IO.Path]::GetExtension($target).ToLowerInvariant() -ne '.exe') { continue }
                    if (-not (Test-MainExeName $target)) { continue }
                    if (Test-BuiltIn $target) { continue }
                    $isGui = $true
                    try { $isGui = [ScanEngine]::PeIsGui($target) } catch {}
                    if (-not $isGui) { continue }
                    # 提取版本信息
                    $name = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                    $ver = ''
                    $pub = ''
                    try {
                        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($target)
                        if ($vi.ProductName -and $vi.ProductName.Trim().Length -gt 0) { $name = $vi.ProductName.Trim() }
                        if ($vi.FileVersion -and $vi.FileVersion.Trim().Length -gt 0) { $ver = $vi.FileVersion.Trim() }
                        if ($vi.CompanyName -and $vi.CompanyName.Trim().Length -gt 0) { $pub = $vi.CompanyName.Trim() }
                    } catch {}
                    $key = ($name + '|' + $target).ToLowerInvariant()
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = 1
                    $size = 0
                    try { $size = (Get-Item -LiteralPath $target -ErrorAction SilentlyContinue).Length } catch {}
                    [void]$apps.Add(@{
                        Name = $name
                        Version = $ver
                        Publisher = $pub
                        InstallLocation = [System.IO.Path]::GetDirectoryName($target)
                        MainExe = $target
                        IconSource = $target
                        EstimatedSize = [math]::Round($size / 1KB)
                    })
                } catch {}
            }
        } catch {}
    }
    return ,$apps
}

# 从注册表读取已安装应用，返回数组（每条含 Name/Version/Publisher/InstallLocation/MainExe/IconSource）
function Get-InstalledApps {
    $apps = New-Object System.Collections.ArrayList
    $seen = @{}
    $roots = Get-UninstallRoots
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $subs = $null
        try { $subs = Get-ChildItem $root -ErrorAction SilentlyContinue } catch { }
        if (-not $subs) { continue }
        foreach ($sub in $subs) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue } catch { }
            if (-not $p) { continue }
            if (-not (Test-IsStandaloneApp $p)) { continue }
            $name = ([string]$p.DisplayName).Trim()
            $ver = ''
            if ($p.DisplayVersion) { $ver = [string]$p.DisplayVersion }
            $pub = ''
            if ($p.Publisher) { $pub = [string]$p.Publisher }
            $loc = ''
            if ($p.InstallLocation) { $loc = ([string]$p.InstallLocation).Trim('"') }
            $estKB = 0
            if ($p.EstimatedSize) {
                $v = 0
                if ([int]::TryParse([string]$p.EstimatedSize, [ref]$v)) { $estKB = $v }
            }
            $iconSrc = Resolve-DisplayIconPath ([string]$p.DisplayIcon)
            $mainExe = ''
            if ($iconSrc.Length -gt 0 -and [System.IO.Path]::GetExtension($iconSrc).ToLowerInvariant() -eq '.exe') {
                # DisplayIcon 指向 exe 时，必须是「像主程序」的文件才直接采用，否则从安装目录重找
                if (Test-MainExeName $iconSrc) { $mainExe = $iconSrc }
            }
            if ($mainExe.Length -eq 0 -and $loc.Length -gt 0) {
                try { if (Test-Path -LiteralPath $loc -ErrorAction SilentlyContinue) { $found = Find-MainExeInDir $loc; if ($found) { $mainExe = $found } } } catch { }
            }
            if ($mainExe.Length -eq 0) { continue }
            $iconFor = $mainExe
            if ($iconSrc.Length -gt 0) {
                $iconExt = [System.IO.Path]::GetExtension($iconSrc).ToLowerInvariant()
                if ($iconExt -ne '.exe' -or (Test-MainExeName $iconSrc)) { $iconFor = $iconSrc }
            }
            $key = $mainExe.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            [void]$apps.Add(@{
                Name = $name
                Version = $ver
                Publisher = $pub
                InstallLocation = $loc
                MainExe = $mainExe
                IconSource = $iconFor
                EstimatedSize = $estKB
            })
        }
    }
    # 备用定位源：从 Start Menu / Desktop 快捷方式补充（覆盖注册表缺失场景）
    try {
        $extraApps = Get-AppsFromShortcuts
        foreach ($app in $extraApps) {
            $key = $app.MainExe.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            [void]$apps.Add($app)
        }
    } catch {}
    return ,$apps
}

# 从 exe/ico/dll 提取关联图标；失败返回 $null（界面用系统通用图标兜底）
function Get-AppIcon {
    param([string]$src)
    if ([string]::IsNullOrEmpty($src)) { return $null }
    $ext = [System.IO.Path]::GetExtension($src).ToLowerInvariant()
    if ($ext -ne '.exe' -and $ext -ne '.ico' -and $ext -ne '.dll') { return $null }
    try { if (-not (Test-Path -LiteralPath $src -ErrorAction SilentlyContinue)) { return $null } } catch { return $null }
    try {
        return [System.Drawing.Icon]::ExtractAssociatedIcon($src)
    } catch {
        return $null
    }
}

# 界面用：加载已安装应用列表（读注册表 + 提取图标 + 填充列表）
function Load-InstalledApps {
    $script:listView.BeginUpdate()
    $script:listView.Items.Clear()
    $script:AllItems.Clear()
    $script:iconList.Images.Clear()
    $script:IconIndexByPath.Clear()

    $apps = Get-InstalledApps
    foreach ($app in $apps) {
        # 左侧缩略图标：相同图标源复用同一 ImageList 索引
        $iconIdx = -1
        $iconKey = ([string]$app.IconSource).ToLowerInvariant()
        if ($script:IconIndexByPath.ContainsKey($iconKey)) {
            $iconIdx = $script:IconIndexByPath[$iconKey]
        } else {
            $ico = Get-AppIcon ([string]$app.IconSource)
            $ownsIcon = ($null -ne $ico)
            if (-not $ico) {
                try { $ico = [System.Drawing.SystemIcons]::Application } catch { $ico = $null }
            }
            if ($ico) {
                $iconIdx = $script:iconList.Images.Count
                [void]$script:iconList.Images.Add($ico)
                if ($ownsIcon) { try { $ico.Dispose() } catch { } }
                $script:IconIndexByPath[$iconKey] = $iconIdx
            }
        }

        $item = New-Object System.Windows.Forms.ListViewItem
        $item.Text = [string]$app.Name
        if ($iconIdx -ge 0) { $item.ImageIndex = $iconIdx }
        [void]$item.SubItems.Add([string]$app.MainExe)
        [void]$item.SubItems.Add([string]$app.Publisher)
        [void]$item.SubItems.Add([string]$app.Version)
        $sizeText = ''
        if ($app.EstimatedSize -gt 0) { $sizeText = Format-Size ([long]$app.EstimatedSize * 1KB) }
        [void]$item.SubItems.Add($sizeText)
        $item.Tag = @{
            Path = $app.MainExe
            Product = $app.Name
            AppName = $app.Name
            Publisher = $app.Publisher
            Version = $app.Version
        }
        $item.ToolTipText = [string]$app.MainExe
        [void]$script:AllItems.Add($item)
        [void]$script:listView.Items.Add($item)
    }
    $script:listView.EndUpdate()
    $script:lblCount.Text = ('共 {0} 项' -f $script:AllItems.Count)
}

# ---------------- 无头模式（测试/命令行） ----------------

# 无头输出已安装应用（口径与系统设置一致），用于核对与命令行调用
function Run-InstalledApps {
    param([string]$out)
    Add-ScanEngine
    $apps = Get-InstalledApps
    Write-Output ('Apps: ' + $apps.Count)
    if ($out) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Name,Publisher,Version,InstallLocation,MainExe,IconSource,EstimatedSizeKB')
        foreach ($a in $apps) {
            [void]$sb.AppendLine(('"{0}","{1}","{2}","{3}","{4}","{5}",{6}' -f $a.Name, $a.Publisher, $a.Version, $a.InstallLocation, $a.MainExe, $a.IconSource, $a.EstimatedSize))
        }
        [System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Write-Output ('Written: ' + $out)
    }
}

function Run-Headless {
    param([string]$dir, [string]$out)
    Add-ScanEngine
    $roots = @($dir)
    $tokens = Get-DefaultTokens
    [ScanEngine]::Start([string[]]$roots, [string[]]$tokens, $true)
    $all = New-Object System.Collections.ArrayList
    $guard = 0
    while (-not [ScanEngine]::IsIdle()) {
        $batch = [ScanEngine]::DequeueBatch(2000)
        if ($batch.Length -gt 0) { foreach ($r in $batch) { [void]$all.Add($r) } }
        Start-Sleep -Milliseconds 100
        $guard++
        if ($guard -gt 60000) { Write-Output 'TIMEOUT waiting scan'; break }
    }
    $batch = [ScanEngine]::DequeueBatch(1000000)
    if ($batch.Length -gt 0) { foreach ($r in $batch) { [void]$all.Add($r) } }
    [ScanEngine]::Finish()
    Write-Output ('Found: ' + $all.Count)
    # 与界面保持一致：隐藏自带程序，每个产品只保留主程序
    $best = @{}
    foreach ($r in $all) { [void](Update-BestMap $best $r) }
    $apps = New-Object System.Collections.ArrayList
    foreach ($k in $best.Keys) { [void]$apps.Add($best[$k].R) }
    Write-Output ('Apps: ' + $apps.Count)
    if ($out) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Name,Path,Product,Company,Version,SizeKB')
        foreach ($r in $apps) {
            [void]$sb.AppendLine(('"{0}","{1}","{2}","{3}","{4}",{5}' -f $r.Name, $r.Path, $r.Product, $r.Company, $r.Version, [math]::Round($r.Size / 1KB, 1)))
        }
        [System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Write-Output ('Written: ' + $out)
    }
}

# ---------------- 自检 ----------------

function Run-SelfTest {
    Add-ScanEngine
    Write-Output 'ScanEngine compile: OK'

    # ---- 应用模式断言：独立应用口径与「设置 > 应用 > 已安装的应用」一致 ----
    $fakeApp = New-Object PSObject -Property @{
        DisplayName = 'TestApp 2026'
        SystemComponent = '0'
        ParentKeyName = $null
        ReleaseType = $null
    }
    if (Test-IsStandaloneApp $fakeApp) { Write-Output 'Standalone filter (app): OK' } else { Write-Output 'FAIL filter rejects normal app'; exit 1 }
    $fakeSys = New-Object PSObject -Property @{
        DisplayName = 'SystemComponent App'
        SystemComponent = '1'
    }
    if (-not (Test-IsStandaloneApp $fakeSys)) { Write-Output 'Standalone filter (SystemComponent): OK' } else { Write-Output 'FAIL SystemComponent not filtered'; exit 1 }
    $fakeChild = New-Object PSObject -Property @{
        DisplayName = 'Child App'
        SystemComponent = '0'
        ParentKeyName = 'Parent'
    }
    if (-not (Test-IsStandaloneApp $fakeChild)) { Write-Output 'Standalone filter (ParentKeyName): OK' } else { Write-Output 'FAIL child not filtered'; exit 1 }
    $fakeHotfix = New-Object PSObject -Property @{
        DisplayName = 'KB5000001 Update for Windows'
        SystemComponent = '0'
        ReleaseType = 'Update'
    }
    if (-not (Test-IsStandaloneApp $fakeHotfix)) { Write-Output 'Standalone filter (KB/Update): OK' } else { Write-Output 'FAIL KB not filtered'; exit 1 }
    $fakeVcRedist = New-Object PSObject -Property @{
        DisplayName = 'Microsoft Visual C++ 2015 Redistributable (x64) - 14.0.24215'
        SystemComponent = '0'
    }
    if (-not (Test-IsStandaloneApp $fakeVcRedist)) { Write-Output 'Standalone filter (VC redist): OK' } else { Write-Output 'FAIL VC redist not filtered'; exit 1 }
    $roots = Get-UninstallRoots
    if ($roots.Count -ge 2) { Write-Output ('Uninstall roots (' + $roots.Count + '): OK') } else { Write-Output 'FAIL uninstall roots'; exit 1 }
    $realApps = Get-InstalledApps
    Write-Output ('Installed apps (headless): ' + $realApps.Count)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sr_test_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($tmp)
    try {
        $src = Join-Path $env:WINDIR 'System32\notepad.exe'
        if (-not (Test-Path -LiteralPath $src)) {
            $cand = Get-ChildItem -Path (Join-Path $env:WINDIR 'System32') -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cand) { Write-Output 'FAIL: no source exe'; exit 1 }
            $src = $cand.FullName
        }
        $names = @('AppOne.exe', 'AppTwo.exe', 'AppThree.exe')
        foreach ($n in $names) { Copy-Item -LiteralPath $src -Destination (Join-Path $tmp $n) -Force }
        # 额外放入一个控制台程序，用于验证 GUI 子系统过滤
        $consoleSrc = Join-Path $env:WINDIR 'System32\cmd.exe'
        $consoleCopied = $false
        if (Test-Path -LiteralPath $consoleSrc) {
            Copy-Item -LiteralPath $consoleSrc -Destination (Join-Path $tmp 'AppConsole.exe') -Force
            $consoleCopied = $true
        }

        [ScanEngine]::Start([string[]]@($tmp), [string[]]@(), $true)
        $res = New-Object System.Collections.ArrayList
        $guard = 0
        while (-not [ScanEngine]::IsIdle()) {
            $batch = [ScanEngine]::DequeueBatch(1000)
            if ($batch.Length -gt 0) { foreach ($r in $batch) { [void]$res.Add($r) } }
            Start-Sleep -Milliseconds 50
            $guard++
            if ($guard -gt 2000) { Write-Output 'TIMEOUT waiting scan'; break }
        }
        $batch = [ScanEngine]::DequeueBatch(1000000)
        if ($batch.Length -gt 0) { foreach ($r in $batch) { [void]$res.Add($r) } }
        if ($res.Count -eq 3) { Write-Output ('Scan found ' + $res.Count + ' : OK') } else { Write-Output ('FAIL scan count = ' + $res.Count); exit 1 }
        if ($consoleCopied) { Write-Output 'GUI filter (console excluded): OK' }

        $lnk = New-Shortcut (Join-Path $tmp 'AppOne.exe') $tmp '测试应用'
        if ($lnk -and (Test-Path -LiteralPath $lnk)) {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($lnk)
            if ($sc.TargetPath -eq (Join-Path $tmp 'AppOne.exe')) { Write-Output 'Shortcut: OK' } else { Write-Output ('FAIL shortcut target: ' + $sc.TargetPath); exit 1 }
        } else { Write-Output 'FAIL shortcut create'; exit 1 }

        $lnk2 = New-Shortcut (Join-Path $tmp 'AppTwo.exe') $tmp '测试应用'
        if ($lnk2 -and ($lnk2 -ne $lnk) -and (Test-Path -LiteralPath $lnk2)) { Write-Output 'Shortcut dedup: OK' } else { Write-Output 'FAIL shortcut dedup'; exit 1 }

        # 搜索归一化：全角字母/数字转半角，中文保持不变
        $fwCodes = @(0xFF23, 0xFF48, 0xFF52, 0xFF4F, 0xFF4D, 0xFF45, 0xFF11, 0xFF12, 0xFF13)
        $fwChars = @()
        foreach ($c in $fwCodes) { $fwChars += [char]$c }
        $fwSample = ConvertTo-HalfWidth ($fwChars -join '')
        if ($fwSample -eq 'Chrome123') { Write-Output 'Search width normalize: OK' } else { Write-Output ('FAIL width normalize: ' + $fwSample); exit 1 }
        if ((ConvertTo-HalfWidth '中文A1') -eq '中文A1') { Write-Output 'Search width normalize (CJK kept): OK' } else { Write-Output 'FAIL CJK kept unchanged'; exit 1 }

        # 拼音与中英别名匹配
        $pyKeys = Get-SearchKeys '微信'
        if ($pyKeys[0] -eq 'weixin' -and $pyKeys[1] -eq 'wx') {
            Write-Output 'Search pinyin: OK'
        } else {
            Write-Output ('FAIL pinyin: ' + ($pyKeys -join '/')); exit 1
        }
        $aliasKw = @(Get-AliasKeywords 'wechat')
        $aliasHasZh = $false
        foreach ($t in $aliasKw) { if ($t -eq '微信') { $aliasHasZh = $true } }
        if ($aliasHasZh) { Write-Output 'Search alias (en -> zh): OK' } else { Write-Output 'FAIL alias en->zh'; exit 1 }
        $aliasKw2 = @(Get-AliasKeywords '钉钉')
        $aliasHasEn = $false
        foreach ($t in $aliasKw2) { if ($t -eq 'dingtalk') { $aliasHasEn = $true } }
        if ($aliasHasEn) { Write-Output 'Search alias (zh -> en): OK' } else { Write-Output 'FAIL alias zh->en'; exit 1 }

        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
        $form = Build-MainForm
        if ($form) {
            # 切到应用模式：加载真实注册表应用并填充图标缩略列
            $script:rModeApps.Checked = $true
            Update-Scope-UI
            Load-InstalledApps
            if ($script:AllItems.Count -gt 0) {
                Write-Output ('App mode rows: ' + $script:AllItems.Count + ' : OK')
            } else {
                Write-Output 'App mode rows: 0 (machine has no uninstall entries)'
            }
            # 搜索过滤集成验证：全角关键字应匹配半角名称（用合成条目，与真机应用无关）
            $probeItem = New-Object System.Windows.Forms.ListViewItem
            $probeItem.Text = 'ZzSearchProbe'
            [void]$probeItem.SubItems.Add('C:\Nonexistent\ZzSearchProbe.exe')
            $probeItem.Tag = @{ Path = 'C:\Nonexistent\ZzSearchProbe.exe'; Product = 'ZzSearchProbe' }
            [void]$script:AllItems.Add($probeItem)
            $fwKwCodes = @(0xFF3A, 0xFF5A, 0xFF33, 0xFF45, 0xFF41, 0xFF52, 0xFF43, 0xFF48, 0xFF30, 0xFF52, 0xFF4F, 0xFF42, 0xFF45)
            $fwKwChars = @()
            foreach ($c in $fwKwCodes) { $fwKwChars += [char]$c }
            $script:txtFilter.Text = ($fwKwChars -join '')
            Update-ListView
            $probeShown = 0
            foreach ($it in $script:listView.Items) { if ($it.Text -eq 'ZzSearchProbe') { $probeShown++ } }
            if ($probeShown -eq 1 -and $script:listView.Items.Count -eq 1) {
                Write-Output 'Search filter (full-width -> half-width): OK'
            } else {
                Write-Output ('FAIL filter full-width match: shown=' + $probeShown + ' total=' + $script:listView.Items.Count)
                exit 1
            }
            $script:txtFilter.Text = ''
            Update-ListView
            [void]$script:AllItems.Remove($probeItem)

            # 中英文互匹配集成验证：合成 3 条唯一探针条目（名称不会与真机应用重名）
            $pPy = New-Object System.Windows.Forms.ListViewItem
            $pPy.Text = '梓柠测试'
            [void]$pPy.SubItems.Add('C:\Nonexistent\ZzPinyinProbe\ZzPinyinProbe.exe')
            $pPy.Tag = @{ Path = 'C:\Nonexistent\ZzPinyinProbe\ZzPinyinProbe.exe'; Product = 'ZzPinyinProbe' }
            $pZh = New-Object System.Windows.Forms.ListViewItem
            $pZh.Text = 'Zz微信探针'
            [void]$pZh.SubItems.Add('C:\Nonexistent\ZzZhProbe\ZzZhProbe.exe')
            $pZh.Tag = @{ Path = 'C:\Nonexistent\ZzZhProbe\ZzZhProbe.exe'; Product = 'ZzZhProbe' }
            $pEn = New-Object System.Windows.Forms.ListViewItem
            $pEn.Text = 'ZzDingTalkProbe'
            [void]$pEn.SubItems.Add('C:\Nonexistent\ZzDingTalkProbe\ZzDingTalkProbe.exe')
            $pEn.Tag = @{ Path = 'C:\Nonexistent\ZzDingTalkProbe\ZzDingTalkProbe.exe'; Product = 'ZzDingTalkProbe' }
            [void]$script:AllItems.Add($pPy)
            [void]$script:AllItems.Add($pZh)
            [void]$script:AllItems.Add($pEn)

            function SearchProbeHits {
                param([string]$kw, [string]$text)
                $script:txtFilter.Text = $kw
                Update-ListView
                $n = 0
                foreach ($it in $script:listView.Items) { if ($it.Text -eq $text) { $n++ } }
                return $n
            }

            $cases = @(
                @('zining', '梓柠测试', 'pinyin full'),
                @('zn', '梓柠测试', 'pinyin initials'),
                @('梓柠', '梓柠测试', 'zh kw -> zh name'),
                @('wechat', 'Zz微信探针', 'en kw -> zh name (alias)'),
                @('钉钉', 'ZzDingTalkProbe', 'zh kw -> en name (alias)')
            )
            foreach ($case in $cases) {
                $hitN = SearchProbeHits $case[0] $case[1]
                Write-Output ('Search cross-lang [' + $case[2] + '] kw=' + $case[0] + ' probe=' + $case[1] + ' -> shown=' + $hitN)
                if ($hitN -ne 1) { Write-Output 'FAIL cross-lang match'; exit 1 }
            }
            Write-Output 'Search cross-lang (mixed): OK'
            $script:txtFilter.Text = ''
            Update-ListView
            [void]$script:AllItems.Remove($pPy)
            [void]$script:AllItems.Remove($pZh)
            [void]$script:AllItems.Remove($pEn)

            if ($env:SR_UI_SHOT) {
                try {
                    $form.Show()
                    $form.Refresh()
                    $bmp = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
                    $form.DrawToBitmap($bmp, $form.ClientRectangle)
                    $bmp.Save($env:SR_UI_SHOT, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                    Write-Output ('UI shot: ' + $env:SR_UI_SHOT)
                } catch {
                    Write-Output ('UI shot FAIL: ' + $_.Exception.Message)
                }
            }
            $form.Dispose()
            Write-Output 'Form build: OK'
        } else {
            Write-Output 'FAIL form build'
            exit 1
        }
        Write-Output 'ALL SELF TESTS PASSED'
    } finally {
        if (Test-Path -LiteralPath $tmp) { [System.IO.Directory]::Delete($tmp, $true) }
    }
    exit 0
}

# ---------------- 入口 ----------------

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

if ($SelfTest) {
    Run-SelfTest
} elseif ($HeadlessScan) {
    Run-Headless $HeadlessScan $OutFile
} elseif ($InstalledApps) {
    Run-InstalledApps $OutFile
} else {
    Add-ScanEngine
    $mainForm = Build-MainForm
    [System.Windows.Forms.Application]::Run($mainForm)
}