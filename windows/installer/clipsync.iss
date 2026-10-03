; Inno Setup script for ClipSync (Windows).
;
; Build steps (run from the project root):
;   1. flutter build windows --release
;   2. iscc windows\installer\clipsync.iss     (or open this file in Inno Setup and press Compile)
; The installer is written to build\installer\ClipSync-Setup-<version>.exe
;
; Bump MyAppVersion together with `version:` in pubspec.yaml.

#define MyAppName "ClipSync"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "ClipSync"
#define MyAppExeName "clip_sync.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Never change AppId after you ship; it is how Windows recognises upgrades.
AppId={{6D1B7C3E-4F0A-4B8E-9C52-3A7E1D9F2B64}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\installer
OutputBaseFilename=ClipSync-Setup-{#MyAppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Installs for the current user only, so no admin prompt is needed.
; Switch to "admin" to install for all users under Program Files.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start ClipSync when I sign in to Windows"; GroupDescription: "Startup:"

[Files]
Source: "{#BuildDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; Visual C++ runtime, so the app starts on PCs that don't have it installed.
; These are copied from the machine that builds the installer.
Source: "C:\Windows\System32\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "C:\Windows\System32\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "C:\Windows\System32\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
