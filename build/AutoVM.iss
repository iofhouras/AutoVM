; AutoVM installer (Inno Setup 6).
;
; Produces AutoVM-Setup-<version>.exe: a single file the user downloads, runs,
; and then finds in their Start menu.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\staging"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

#define AppName    "AutoVM"
#define AppPublisher "AutoVM"
#define AppUrl     "https://github.com/iofhouras/AutoVM"
#define AppExe     "AutoVM.exe"

[Setup]
AppId={{9C4E1F2A-3B77-4C1E-8E3D-6A2F5B0D9E41}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=AutoVM-Setup-{#AppVersion}
SetupIconFile={#SourceDir}\AutoVM.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; The application installs a hypervisor, which needs administrator rights.
PrivilegesRequired=admin
MinVersion=10.0
LicenseFile={#SourceDir}\LICENSE.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceDir}\{#AppExe}";          DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\AutoVM.ico";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\AutoVM.ps1";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\AutoVM.Console.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\MainWindow.xaml";    DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE.txt";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.txt";         DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "{#SourceDir}\AutoVM\*";           DestDir: "{app}\AutoVM"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\docs\*";             DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}";            Filename: "{app}\{#AppExe}"; IconFilename: "{app}\AutoVM.ico"
Name: "{group}\AutoVM build logs";     Filename: "{commonappdata}\AutoVM\logs"
Name: "{group}\Uninstall {#AppName}";  Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";      Filename: "{app}\{#AppExe}"; IconFilename: "{app}\AutoVM.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\AutoVM"

[Code]
function InitializeSetup(): Boolean;
var
  PowerShell: String;
begin
  Result := True;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(PowerShell) then
  begin
    if not FileExists(ExpandConstant('{pf}\PowerShell\7\pwsh.exe')) then
    begin
      MsgBox('AutoVM needs Windows PowerShell, which could not be found on this computer.' + #13#10 + #13#10 +
             'Install PowerShell and run this setup again.', mbCriticalError, MB_OK);
      Result := False;
    end;
  end;
end;
