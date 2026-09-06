; Existing installations must pass the checked PowerShell installer, which keeps
; a private recovery copy before NSIS can overwrite/uninstall the previous app.
!include "FileFunc.nsh"

!macro customInit
  ReadRegStr $R0 HKCU "Software\d1a6026a-6210-588e-9a2b-da3936f94e02" "InstallLocation"
  ${If} $R0 != ""
    ${GetParameters} $R1
    ClearErrors
    ${GetOptions} $R1 "/MIGRATION_PREPARED" $R2
    ${If} ${Errors}
      MessageBox MB_OK|MB_ICONSTOP "Existing Codex Web GPT installation detected. Run install-launcher.ps1 from geg971509-wq/codex-chatgpt-web to confirm the publisher and back up before replacement." /SD IDOK
      SetErrorLevel 2
      Quit
    ${EndIf}
  ${EndIf}
!macroend
