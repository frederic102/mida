[Setup]
AppName=MiDa
AppVersion=2.2.0
AppPublisher=frederic102
DefaultDirName={autopf}\MiDa
DefaultGroupName=MiDa
OutputDir=dist\windows
OutputBaseFilename=MiDa_Setup_v2.2.0
Compression=lzma
SolidCompression=yes
UninstallDisplayIcon={app}\MiDa.exe

[Files]
Source: "dist\windows\MiDa.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\desktop_drop_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\ffprobe.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\windows\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MiDa"; Filename: "{app}\MiDa.exe"
Name: "{commondesktop}\MiDa"; Filename: "{app}\MiDa.exe"

[Run]
Filename: "{app}\MiDa.exe"; Description: "Launch MiDa"; Flags: nowait postinstall skipifsilent
