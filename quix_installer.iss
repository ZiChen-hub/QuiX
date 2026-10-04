; QuiX Windows 安装包脚本
; 用法: iscc /DAppVersion=1.6.3 quix_installer.iss
#ifndef AppVersion
  #define AppVersion "1.6.3"
#endif

#define AppName "QuiX"
#define BuildDir "quix-client\build\windows\x64\runner\Release"

[Setup]
AppId={{7F3A2C1E-9B4D-4E6F-A2C8-1D5E7F9B3A4C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=QuiX
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=dist
OutputBaseFilename=QuiX-Setup-{#AppVersion}
SetupIconFile=quix-client\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\quix_client.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.msix,*.pdb"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\quix_client.exe"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\quix_client.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\quix_client.exe"; Description: "启动 {#AppName}"; Flags: nowait postinstall skipifsilent
