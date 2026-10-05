#define AppVersion "0.3.0"
[Setup]
#ifdef SigningEnabled
SignTool=voiceling
SignedUninstaller=yes
#endif
AppId={{D8556A6D-96DC-47B0-8B96-A80F932A9460}
AppName=Voiceling
AppVersion={#AppVersion}
AppPublisher=Team Wong
AppPublisherURL=https://github.com/M1w234/voiceling
DefaultDirName={localappdata}\Programs\voiceling
UsePreviousAppDir=no
DefaultGroupName=Voiceling
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\artifacts
OutputBaseFilename=voiceling-{#AppVersion}-windows-x64-preview-setup
SetupIconFile=..\src\Voiceling.Windows\Assets\voiceling.ico
UninstallDisplayIcon={app}\voiceling.exe
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
AppMutex=Local\TeamWong.Voiceling.Windows,Local\TeamWong.YaprFlow.Windows

[Files]
Source: "..\artifacts\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\voiceling"; Filename: "{app}\voiceling.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Voiceling"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\voiceling.exe"; Description: "Open voiceling"; Flags: nowait postinstall skipifsilent

; Uninstall preserves user history and the downloaded model. The app provides
; explicit history deletion; data location is documented in Settings and README.
