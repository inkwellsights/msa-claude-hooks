$ErrorActionPreference = "Stop"

$AppId = "ClaudeCode.SessionRecall"
$AppName = "Claude Code"
$ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"

# Step 1: Create/overwrite a basic shortcut (target is harmless — shortcut just exists so Windows knows this AppId)
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($ShortcutPath)
$sc.TargetPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments = ""
$sc.IconLocation = "$env:WINDIR\System32\imageres.dll,-5305"
$sc.Save()

# Step 2: Set AppUserModelID on the shortcut via IPropertyStore COM
if (-not ('AUM.Setter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace AUM {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink { }

    // Order-preserving stub of IShellLinkW; we only need the COM object to
    // cross-cast to IPersistFile/IPropertyStore. Each stub entry preserves a vtable slot.
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW {
        void _0();  void _1();  void _2();  void _3();
        void _4();  void _5();  void _6();  void _7();
        void _8();  void _9();  void _10(); void _11();
        void _12(); void _13(); void _14(); void _15();
        void _16(); void _17(); void _18();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    // PROPVARIANT is 24 bytes on x64. We only care about vt (offset 0) and
    // a pointer value (offset 8) for VT_LPWSTR strings.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PropertyKey pkey);
        int GetValue(ref PropertyKey key, out PROPVARIANT pv);
        int SetValue(ref PropertyKey key, [In] ref PROPVARIANT pv);
        int Commit();
    }

    public static class Setter {
        public static void SetAppUserModelId(string lnkPath, string appId) {
            var link = (IShellLinkW)new ShellLink();
            ((IPersistFile)link).Load(lnkPath, 2); // STGM_READWRITE

            var store = (IPropertyStore)link;
            var key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

            var pv = new PROPVARIANT {
                vt = 31, // VT_LPWSTR
                pointerValue = Marshal.StringToCoTaskMemUni(appId)
            };

            int hr1 = store.SetValue(ref key, ref pv);
            int hr2 = store.Commit();
            Marshal.FreeCoTaskMem(pv.pointerValue);

            ((IPersistFile)link).Save(lnkPath, true);

            if (hr1 != 0) throw new Exception("SetValue failed: 0x" + hr1.ToString("X"));
            if (hr2 != 0) throw new Exception("Commit failed: 0x" + hr2.ToString("X"));
        }
    }
}
'@
}

[AUM.Setter]::SetAppUserModelId($ShortcutPath, $AppId)

Write-Host "Created shortcut: $ShortcutPath" -ForegroundColor Green
Write-Host "AppUserModelID: $AppId" -ForegroundColor Green
Write-Host ""
Write-Host "Next: update notify-done.ps1 to use this AppId (already done)."
