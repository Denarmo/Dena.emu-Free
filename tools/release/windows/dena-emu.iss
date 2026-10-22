; SPDX-License-Identifier: GPL-3.0-or-later
; Inno Setup 6.3+ script for the Dena.emu Windows installer
; (docs/dev/release-windows.md). tools/release/build-windows.ps1 compiles it:
;   ISCC.exe /DAppVersion=X.Y.Z /DSourceDir=<stage\Dena.emu> /DOutputDir=<out>
;            /DOutputBase=dena-emu-X.Y.Z-windows-x64-setup /DRepoDir=<repo> dena-emu.iss
; Per-user install (no admin) into %LOCALAPPDATA%\Programs\Dena.emu, Start
; menu entry, optional desktop shortcut, optional "Open with" entries for game
; files (off by default), uninstaller. User data (%APPDATA%\Dena.emu) is never
; touched by setup or uninstall.

#ifndef AppVersion
  #error Pass /DAppVersion=X.Y.Z (tools/release/build-windows.ps1 does)
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<staged Dena.emu folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputBase
  #define OutputBase "dena-emu-" + AppVersion + "-windows-x64-setup"
#endif
#ifndef DefaultDir
  ; {autopf} is %LOCALAPPDATA%\Programs for a per-user install. Override only
  ; for tests (Wine has no per-user Program Files folder).
  #define DefaultDir "{autopf}\Dena.emu"
#endif
#ifndef RepoDir
  #define RepoDir AddBackslash(SourcePath) + "..\..\.."
#endif

#define AppName "Dena.emu"
#define AppExe "dena_emu.exe"
#define ProgId "DenaEmu.Game"

[Setup]
; Never change AppId: upgrades and the uninstaller find the install by it.
AppId={{6F1D2C7A-3B8E-4E5D-9A61-D3E4A0B7C2F1}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Dena.emu
AppPublisherURL=https://github.com/Denarmo/Dena.emu
AppSupportURL=https://github.com/Denarmo/Dena.emu/issues
AppUpdatesURL=https://github.com/Denarmo/Dena.emu/releases
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
; Per user, no UAC prompt.
PrivilegesRequired=lowest
DefaultDirName={#DefaultDir}
DisableProgramGroupPage=yes
DisableDirPage=auto
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#RepoDir}\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile={#SourceDir}\LICENSE.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Asks to close a running Dena.emu before files are replaced.
CloseApplications=yes
RestartApplications=no
; Only the optional "Open with" task writes associations; the refresh is cheap.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "openwith"; Description: "Show Dena.emu in ""Open with"" for game files (.gba, .nes, .iso, ...)"; GroupDescription: "File types:"; Flags: unchecked

[InstallDelete]
; Cores from an older version that this one no longer ships.
Type: files; Name: "{app}\cores\*_libretro.dll"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; HKA is HKCU\Software\Classes for a per-user install. OpenWithProgids only
; adds Dena.emu to the "Open with" list; it never takes over the default app.
Root: HKA; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; ValueName: ""; ValueData: "Game for {#AppName}"; Flags: uninsdeletekey; Tasks: openwith
Root: HKA; Subkey: "Software\Classes\{#ProgId}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExe},0"; Tasks: openwith
Root: HKA; Subkey: "Software\Classes\{#ProgId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: openwith
#define Ext(E) 'Root: HKA; Subkey: "Software\Classes\' + E + '\OpenWithProgids"; ValueType: string; ValueName: "' + ProgId + '"; ValueData: ""; Flags: uninsdeletevalue; Tasks: openwith'
{#Ext(".nes")}
{#Ext(".sfc")}
{#Ext(".smc")}
{#Ext(".gb")}
{#Ext(".gbc")}
{#Ext(".gba")}
{#Ext(".nds")}
{#Ext(".n64")}
{#Ext(".z64")}
{#Ext(".v64")}
{#Ext(".cue")}
{#Ext(".chd")}
{#Ext(".m3u")}
{#Ext(".iso")}
{#Ext(".cso")}
{#Ext(".pbp")}
{#Ext(".gdi")}
{#Ext(".cdi")}
{#Ext(".gcm")}
{#Ext(".rvz")}
{#Ext(".wia")}
{#Ext(".gcz")}
{#Ext(".wbfs")}
{#Ext(".ciso")}
{#Ext(".p8")}

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
