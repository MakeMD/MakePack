; MakePack - Windows archiver over 7-Zip's 7z.dll.
; ponytail: no license page, no custom wizard pages, no VersionInfo block - Inno defaults are enough.
; ponytail: the app owns every registry key (src\MakePack\Assoc.cs) and the installer just calls it -
;           one implementation for setup, uninstall and the in-app "Associations..." dialog.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

[Setup]
AppId={{8C3F2B7E-5D0A-4E1B-9F6C-3A2B1C0D9E8F}
AppName=MakePack
AppVersion={#MyAppVersion}
AppPublisher=MakeMD
DefaultDirName={autopf}\MakePack
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesAssociations=yes
SetupIconFile=..\icon\makepack.ico
UninstallDisplayIcon={app}\MakePack.exe
OutputDir=..\dist
OutputBaseFilename=MakePack-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Explorer keeps MakePackShell.dll loaded; with *.dll in the filter Restart Manager would offer to close Explorer itself.
CloseApplicationsFilter=*.exe,*.chm

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Tasks]
Name: "contextmenu"; Description: "{cm:TaskContextMenu}"
Name: "assoc"; Description: "{cm:TaskAssoc}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "win11menu"; Description: "{cm:TaskWin11Menu}"; Check: IsWin11

[Files]
Source: "..\dist\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\third_party\7zip\License.txt"; DestDir: "{app}"; DestName: "7-Zip-License.txt"; Flags: ignoreversion
; Windows 11 top-level menu (shell\, tools\build_shell.ps1). Installed on every OS, registered only by the win11menu task.
; The logos go to {app}\Assets because sparse-package paths resolve inside the install folder.
Source: "..\dist\shell\MakePackShell.dll"; DestDir: "{app}"; Flags: ignoreversion restartreplace uninsrestartdelete
Source: "..\dist\shell\MakePackShell.msix"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\shell\cert\MakePack.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\shell\package\Assets\*"; DestDir: "{app}\Assets"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\MakePack"; Filename: "{app}\MakePack.exe"
Name: "{autodesktop}\MakePack"; Filename: "{app}\MakePack.exe"; Tasks: desktopicon

; Classic verbs: Windows 10 and "Show more options" on Windows 11. The top-level Win11 entry is the win11menu task ([Code]).
[Run]
Filename: "{app}\MakePack.exe"; Parameters: "--register defaults"; Tasks: assoc; Flags: runhidden waituntilterminated
Filename: "{app}\MakePack.exe"; Parameters: "--addmenu on"; Tasks: contextmenu; Flags: runhidden waituntilterminated
Filename: "{app}\MakePack.exe"; Description: "{cm:LaunchProgram,MakePack}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{app}\MakePack.exe"; Parameters: "--unregister"; Flags: runhidden waituntilterminated; RunOnceId: "unregister"

[UninstallDelete]
Type: files; Name: "{app}\MakePackShell.dll.old*"

[CustomMessages]
en.TaskContextMenu=Add "Add to archive" to the context menu
uk.TaskContextMenu=Додати «Додати в архів» у контекстне меню
en.TaskAssoc=Register archive types (Extract here / Extract to folder in the context menu, Open with)
uk.TaskAssoc=Зареєструвати типи архівів (Розпакувати тут / Розпакувати в папку в контекстному меню, Відкрити за допомогою)
en.TaskWin11Menu=MakePack entry in the Windows 11 context menu
uk.TaskWin11Menu=Пункт MakePack у контекстному меню Windows 11

[Code]
const
  ShellPackage = 'MakeMD.MakePack.Shell';   // Identity/@Name in shell\package\AppxManifest.xml

function IsWin11: Boolean;
var
  V: TWindowsVersion;
begin
  GetWindowsVersionEx(V);
  Result := V.Build >= 22000;
end;

// PowerShell single-quoted literal (the install path may contain an apostrophe: C:\Users\O'Brien\...).
function Lit(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '''', '''''', True);
  Result := '''' + Result + '''';
end;

// Runs one PowerShell command hidden and returns its exit code (-1 = could not start).
function PS(const Cmd: String): Integer;
begin
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference = ''Stop''; ' + Cmd + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
  Log(Format('powershell exit %d: %s', [Result, Cmd]));
end;

procedure RemoveWin11Menu;
begin
  PS('Get-AppxPackage ' + ShellPackage + ' | Remove-AppxPackage');
end;

// Remove + add instead of -ForceUpdateFromAnyVersion: also covers a same-version reinstall into another folder
// (a registered version can not be re-registered, and the external location is fixed at registration).
// Exit 2 = the package signature is not trusted (CERT_E_* 0x800B01xx) - the self-signed .cer is not in TrustedPeople yet.
procedure RegisterWin11Menu;
var
  Add: String;
  Code: Integer;
begin
  Add := 'Get-AppxPackage ' + ShellPackage + ' | Remove-AppxPackage; ' +
    'try { Add-AppxPackage -Path ' + Lit(ExpandConstant('{app}\MakePackShell.msix')) +
    ' -ExternalLocation ' + Lit(ExpandConstant('{app}')) + ' } ' +
    'catch { if ($_ -match ''800B01'') { exit 2 }; throw }';
  Code := PS(Add);
  if Code = 2 then begin
    // First without UAC: newer Windows builds accept a sparse-package signer trusted in CurrentUser\TrustedPeople.
    if Exec(ExpandConstant('{sys}\certutil.exe'), '-user -addstore TrustedPeople "' + ExpandConstant('{app}\MakePack.cer') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then Code := PS(Add) else Code := 2;
  end;
  if Code <> 2 then begin
    if Code <> 0 then Log('Windows 11 menu not registered; installation continues');
    Exit;
  end;
  // Still untrusted - the one UAC prompt: trust MakePack.cer machine-wide. Declined = no Win11 menu, the classic verbs still work.
  // ponytail: the cert stays in TrustedPeople on uninstall - removing it would cost a second UAC prompt.
  if not ShellExec('runas', ExpandConstant('{sys}\certutil.exe'),
    '-addstore TrustedPeople "' + ExpandConstant('{app}\MakePack.cer') + '"', '', SW_HIDE, ewWaitUntilTerminated, Code)
    or (Code <> 0) then begin
    Log(Format('certificate not trusted (UAC declined or certutil exit %d); skipping the Windows 11 menu', [Code]));
    Exit;
  end;
  if PS(Add) <> 0 then Log('Windows 11 menu not registered even with the certificate trusted; installation continues');
end;

// Explorer keeps MakePackShell.dll loaded, so an upgrade can not overwrite it - but a loaded DLL can be renamed.
// ponytail: restartreplace/uninsrestartdelete only work in admin mode; this covers the default per-user install.
procedure MoveShellDllAside;
var
  Dll: String;
begin
  Dll := ExpandConstant('{app}\MakePackShell.dll');
  DelTree(Dll + '.old*', False, True, False);   // earlier leftovers Explorer has let go of by now
  if FileExists(Dll) and not DeleteFile(Dll) then
    RenameFile(Dll, Dll + '.old' + GetDateTimeString('yyyymmddhhnnsszzz', #0, #0));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    MoveShellDllAside
  else if CurStep = ssPostInstall then begin
    if WizardIsTaskSelected('win11menu') then
      RegisterWin11Menu
    else if IsWin11 then
      RemoveWin11Menu;   // unticked on an upgrade
  end;
end;

// ponytail: per-user registration - other accounts on the PC do not get the Win11 menu (Add-AppxProvisionedPackage if asked).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveWin11Menu;
end;
