!ifndef HERDR_STAGE_DIR
  !error "HERDR_STAGE_DIR is required"
!endif
!ifndef HERDR_LAUNCHER_EXE
  !error "HERDR_LAUNCHER_EXE is required"
!endif
!ifndef HERDR_HELPER_PS1
  !error "HERDR_HELPER_PS1 is required"
!endif
!ifndef HERDR_SKILL_MD
  !error "HERDR_SKILL_MD is required"
!endif
!ifndef HERDR_BUILD_ID
  !error "HERDR_BUILD_ID is required"
!endif
!ifndef HERDR_DISPLAY_VERSION
  !error "HERDR_DISPLAY_VERSION is required"
!endif
!ifndef HERDR_NUMERIC_VERSION
  !error "HERDR_NUMERIC_VERSION is required"
!endif
!ifndef HERDR_OUTPUT_PATH
  !error "HERDR_OUTPUT_PATH is required"
!endif

Unicode true
Name "Herdr"
Caption "Herdr Setup"
OutFile "${HERDR_OUTPUT_PATH}"
InstallDir "$LOCALAPPDATA\Programs\Herdr"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
BrandingText "Herdr"
VIProductVersion "${HERDR_NUMERIC_VERSION}"
VIAddVersionKey "ProductName" "Herdr"
VIAddVersionKey "CompanyName" "herdr-win"
VIAddVersionKey "LegalCopyright" "Herdr contributors"
VIAddVersionKey "FileDescription" "Herdr per-user installer"
VIAddVersionKey "FileVersion" "${HERDR_DISPLAY_VERSION}"
VIAddVersionKey "ProductVersion" "${HERDR_DISPLAY_VERSION}"

!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

Var ParentPid
Var ParentPidProvided
Var PowerShellPath
Var HelperExitCode
Var HelperOutput
Var StartGate
Var ResidualValid
Var ResidualFindHandle
Var ResidualFindName

!macro HerdrUninstallFault Point Label
  !ifdef HERDR_TEST_UNINSTALL_FAULT
    StrCmp "${HERDR_TEST_UNINSTALL_FAULT}" "${Point}" 0 fault_done_${Label}
    IfFileExists "$TEMP\herdr-uninstall-fault-${Point}.once" fault_done_${Label}
    FileOpen $0 "$TEMP\herdr-uninstall-fault-${Point}.once" w
    FileClose $0
    SetErrors
    Goto uninstall_cleanup_failed
fault_done_${Label}:
  !endif
!macroend

Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Function SetPowerShellPath
  StrCpy $PowerShellPath "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${If} ${RunningX64}
    ; NSIS is a 32-bit process. Sysnative selects the native PowerShell so
    ; HKCU ARP registration is not dependent on WOW64 registry behavior.
    StrCpy $PowerShellPath "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
FunctionEnd

Function un.SetPowerShellPath
  StrCpy $PowerShellPath "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${If} ${RunningX64}
    StrCpy $PowerShellPath "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
FunctionEnd

Function ValidateParentPid
  StrCpy $0 "0"
  StrCmp $ParentPidProvided "1" 0 parent_pid_valid
  StrLen $1 $ParentPid
  IntCmp $1 0 parent_pid_invalid parent_pid_invalid parent_pid_length_nonzero
parent_pid_length_nonzero:
  IntCmp $1 10 parent_pid_digits parent_pid_digits parent_pid_invalid
parent_pid_digits:
  StrCpy $2 0
  StrCpy $3 "0"
parent_pid_loop:
  StrCpy $4 $ParentPid 1 $2
  StrCmp $4 "" parent_pid_done
  StrCmp $4 "0" parent_pid_next
  StrCmp $4 "1" parent_pid_nonzero
  StrCmp $4 "2" parent_pid_nonzero
  StrCmp $4 "3" parent_pid_nonzero
  StrCmp $4 "4" parent_pid_nonzero
  StrCmp $4 "5" parent_pid_nonzero
  StrCmp $4 "6" parent_pid_nonzero
  StrCmp $4 "7" parent_pid_nonzero
  StrCmp $4 "8" parent_pid_nonzero
  StrCmp $4 "9" parent_pid_nonzero parent_pid_invalid
parent_pid_nonzero:
  StrCpy $3 "1"
parent_pid_next:
  IntOp $2 $2 + 1
  Goto parent_pid_loop
parent_pid_done:
  StrCmp $3 "1" parent_pid_valid parent_pid_invalid
parent_pid_valid:
  StrCpy $0 "1"
parent_pid_invalid:
FunctionEnd

Function FailInstall
  Exch $0
  DetailPrint "$0"
  !ifdef HERDR_TEST_UNINSTALL_FAULT
    FileOpen $1 "$TEMP\herdr-install-failure-${HERDR_TEST_UNINSTALL_FAULT}.txt" w
    FileWrite $1 "$0"
    FileClose $1
  !endif
  IfSilent install_failure_silent
  MessageBox MB_OK|MB_ICONSTOP "$0"
install_failure_silent:
  SetErrorLevel 1
  Quit
FunctionEnd

Function un.FailUninstall
  Exch $0
  DetailPrint "$0"
  IfSilent uninstall_failure_silent
  MessageBox MB_OK|MB_ICONSTOP "$0"
uninstall_failure_silent:
  SetErrorLevel 1
  Quit
FunctionEnd

Function WaitForUpdaterStartGate
  ReadEnvStr $StartGate "HERDR_INSTALLER_START_GATE_V1"
  StrCmp $StartGate "" updater_start_gate_done
  StrCpy $0 "0"
updater_start_gate_loop:
  IfFileExists "$StartGate" updater_start_gate_ready
  IntCmp $0 600 updater_start_gate_timeout updater_start_gate_sleep updater_start_gate_timeout
updater_start_gate_sleep:
  Sleep 50
  IntOp $0 $0 + 1
  Goto updater_start_gate_loop
updater_start_gate_ready:
  Delete "$StartGate"
  Goto updater_start_gate_done
updater_start_gate_timeout:
  Push "Timed out waiting for the verified updater process boundary."
  Call FailInstall
updater_start_gate_done:
FunctionEnd

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    Push "Herdr requires 64-bit Windows."
    Call FailInstall
  ${EndIf}
  Call WaitForUpdaterStartGate

  StrCpy $ParentPid "0"
  StrCpy $ParentPidProvided "0"
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} "$0" "/PARENT_PID=" $ParentPid
  ${IfNot} ${Errors}
    StrCpy $ParentPidProvided "1"
  ${EndIf}
  Call ValidateParentPid
  StrCmp $0 "1" parent_pid_ok
  Push "Invalid /PARENT_PID value. Expected a positive decimal process ID."
  Call FailInstall
parent_pid_ok:
  Call SetPowerShellPath
  IfFileExists "$PowerShellPath" powershell_ok
  Push "Windows PowerShell is required to install Herdr."
  Call FailInstall
powershell_ok:
FunctionEnd

Function un.onInit
  SetShellVarContext current
  Call un.SetPowerShellPath
  IfFileExists "$PowerShellPath" un_powershell_ok
  Push "Windows PowerShell is required to uninstall Herdr."
  Call un.FailUninstall
un_powershell_ok:
FunctionEnd

Function un.ValidateResidualLayout
  StrCpy $ResidualValid "0"
  IfFileExists "$INSTDIR\." un_residual_root_exists un_residual_root_missing

un_residual_root_missing:
  StrCpy $ResidualValid "1"
  Return

un_residual_root_exists:
  ClearErrors
  ${un.GetFileAttributes} "$INSTDIR" "DIRECTORY" $0
  IfErrors un_residual_validation_done
  StrCmp $0 "1" 0 un_residual_validation_done
  ${un.GetFileAttributes} "$INSTDIR" "REPARSE_POINT" $0
  IfErrors un_residual_validation_done
  StrCmp $0 "0" 0 un_residual_validation_done

  FindFirst $ResidualFindHandle $ResidualFindName "$INSTDIR\*.*"
  IfErrors un_residual_validation_done
un_residual_root_entry:
  StrCmp $ResidualFindName "." un_residual_root_next
  StrCmp $ResidualFindName ".." un_residual_root_next
  StrCmp $ResidualFindName "state" un_residual_root_state
  StrCmp $ResidualFindName "uninstall.exe" un_residual_root_file un_residual_root_invalid

un_residual_root_state:
  ${un.GetFileAttributes} "$INSTDIR\state" "DIRECTORY" $0
  IfErrors un_residual_root_invalid
  StrCmp $0 "1" 0 un_residual_root_invalid
  ${un.GetFileAttributes} "$INSTDIR\state" "REPARSE_POINT" $0
  IfErrors un_residual_root_invalid
  StrCmp $0 "0" un_residual_root_next un_residual_root_invalid

un_residual_root_file:
  ${un.GetFileAttributes} "$INSTDIR\uninstall.exe" "DIRECTORY" $0
  IfErrors un_residual_root_invalid
  StrCmp $0 "0" 0 un_residual_root_invalid
  ${un.GetFileAttributes} "$INSTDIR\uninstall.exe" "REPARSE_POINT" $0
  IfErrors un_residual_root_invalid
  StrCmp $0 "0" un_residual_root_next un_residual_root_invalid

un_residual_root_next:
  ClearErrors
  FindNext $ResidualFindHandle $ResidualFindName
  IfErrors un_residual_root_complete
  Goto un_residual_root_entry

un_residual_root_invalid:
  FindClose $ResidualFindHandle
  Goto un_residual_validation_done

un_residual_root_complete:
  FindClose $ResidualFindHandle
  IfFileExists "$INSTDIR\state\." un_residual_state_start un_residual_valid

un_residual_state_start:
  FindFirst $ResidualFindHandle $ResidualFindName "$INSTDIR\state\*.*"
  IfErrors un_residual_validation_done
un_residual_state_entry:
  StrCmp $ResidualFindName "." un_residual_state_next
  StrCmp $ResidualFindName ".." un_residual_state_next
  StrCmp $ResidualFindName "installer-helper.ps1" un_residual_state_file
  StrCmp $ResidualFindName "launcher.lock" un_residual_state_file
  StrCmp $ResidualFindName "uninstall.pending" un_residual_state_file un_residual_state_invalid

un_residual_state_file:
  ${un.GetFileAttributes} "$INSTDIR\state\$ResidualFindName" "DIRECTORY" $0
  IfErrors un_residual_state_invalid
  StrCmp $0 "0" 0 un_residual_state_invalid
  ${un.GetFileAttributes} "$INSTDIR\state\$ResidualFindName" "REPARSE_POINT" $0
  IfErrors un_residual_state_invalid
  StrCmp $0 "0" un_residual_state_next un_residual_state_invalid

un_residual_state_next:
  ClearErrors
  FindNext $ResidualFindHandle $ResidualFindName
  IfErrors un_residual_state_complete
  Goto un_residual_state_entry

un_residual_state_invalid:
  FindClose $ResidualFindHandle
  Goto un_residual_validation_done

un_residual_state_complete:
  FindClose $ResidualFindHandle
un_residual_valid:
  StrCpy $ResidualValid "1"
un_residual_validation_done:
FunctionEnd

Section "Herdr" SEC_HERDR
  SectionIn RO
  InitPluginsDir
  ClearErrors
  SetOutPath "$PLUGINSDIR\payload"
  File /r "${HERDR_STAGE_DIR}\*"
  SetOutPath "$PLUGINSDIR"
  File /oname=herdr-launcher.exe "${HERDR_LAUNCHER_EXE}"
  File /oname=herdr-installer-helper.ps1 "${HERDR_HELPER_PS1}"
  SetOutPath "$PLUGINSDIR\skill"
  File /oname=SKILL.md "${HERDR_SKILL_MD}"
  SetOutPath "$PLUGINSDIR"
  WriteUninstaller "$PLUGINSDIR\uninstall.exe"
  IfErrors 0 installer_inputs_ready
  Push "Herdr setup could not unpack its embedded, pre-verified files."
  Call FailInstall

installer_inputs_ready:
  nsExec::ExecToStack /TIMEOUT=120000 '"$PowerShellPath" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\herdr-installer-helper.ps1" -Action Install -InstallRoot "$INSTDIR" -StageDir "$PLUGINSDIR\payload" -LauncherPath "$PLUGINSDIR\herdr-launcher.exe" -UninstallerPath "$PLUGINSDIR\uninstall.exe" -HelperSourcePath "$PLUGINSDIR\herdr-installer-helper.ps1" -SkillSourcePath "$PLUGINSDIR\skill\SKILL.md" -BuildId "${HERDR_BUILD_ID}" -DisplayVersion "${HERDR_DISPLAY_VERSION}" -NumericVersion "${HERDR_NUMERIC_VERSION}" -ParentPid "$ParentPid"'
  Pop $HelperExitCode
  Pop $HelperOutput
  StrCmp $HelperExitCode "0" installer_complete
  StrCpy $0 "Herdr setup failed ($HelperExitCode). $HelperOutput"
  Push $0
  Call FailInstall

installer_complete:
  DetailPrint "$HelperOutput"
  SetErrorLevel 0
SectionEnd

Section "Uninstall"
  Call un.ValidateResidualLayout
  StrCmp $ResidualValid "1" un_residual_exact
  IfFileExists "$INSTDIR\state\installer-helper.ps1" un_helper_ready
  Push "The managed Herdr uninstall helper is missing; the install was preserved."
  Call un.FailUninstall

un_residual_exact:
  ; uninstall.pending is removed only after a helper completed PATH/ARP work.
  ; If it remains, rerun that helper instead of mistaking layout-only progress
  ; for a completed uninstall integration lifecycle.
  IfFileExists "$INSTDIR\state\uninstall.pending" un_residual_pending un_residual_ready

un_residual_pending:
  IfFileExists "$INSTDIR\state\installer-helper.ps1" un_helper_ready
  Push "Herdr uninstall is pending but its retry helper is missing; residual files were preserved."
  Call un.FailUninstall

un_helper_ready:
  nsExec::ExecToStack /TIMEOUT=120000 '"$PowerShellPath" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\state\installer-helper.ps1" -Action Uninstall -InstallRoot "$INSTDIR"'
  Pop $HelperExitCode
  Pop $HelperOutput
  StrCmp $HelperExitCode "0" un_helper_complete
  StrCpy $0 "Herdr uninstall failed ($HelperExitCode). $HelperOutput"
  Push $0
  Call un.FailUninstall

un_helper_complete:
  DetailPrint "$HelperOutput"
  Call un.ValidateResidualLayout
  StrCmp $ResidualValid "1" un_cleanup_start
  Push "Herdr uninstall did not leave an exact recognized residual layout; cleanup was preserved."
  Call un.FailUninstall

un_residual_ready:
  DetailPrint "Resuming exact Herdr residual cleanup."

un_cleanup_start:
  ClearErrors
  ; Reaching this block proves the helper completed PATH/ARP cleanup. Remove
  ; the retry marker first so every later exact residual resumes here instead
  ; of re-entering a helper whose coordination file may already be gone.
  Delete "$INSTDIR\state\uninstall.pending"
  IfErrors uninstall_cleanup_failed
  !insertmacro HerdrUninstallFault "after-uninstall-pending" after_uninstall_pending
  Delete "$INSTDIR\state\launcher.lock"
  IfErrors uninstall_cleanup_failed
  !insertmacro HerdrUninstallFault "after-launcher-lock" after_launcher_lock
  Delete "$INSTDIR\state\installer-helper.ps1"
  IfErrors uninstall_cleanup_failed
  !insertmacro HerdrUninstallFault "after-installer-helper" after_installer_helper
  RMDir "$INSTDIR\state"
  IfErrors uninstall_cleanup_failed
  !insertmacro HerdrUninstallFault "after-state-directory" after_state_directory
  !insertmacro HerdrUninstallFault "before-uninstaller" before_uninstaller
  Delete "$INSTDIR\uninstall.exe"
  IfErrors uninstall_cleanup_failed
  ; After self-removal only the install root can remain. Preserve any racing
  ; unowned content, but do not report an unretryable failure without an owner.
  ClearErrors
  RMDir "$INSTDIR"
  IfErrors 0 uninstall_complete
  DetailPrint "Herdr was removed; a non-empty install directory was preserved."
  ClearErrors
  Goto uninstall_complete
uninstall_cleanup_failed:
  Push "Herdr uninstall could not remove its validated residual files. Retry uninstall."
  Call un.FailUninstall
uninstall_complete:
  !ifdef HERDR_TEST_UNINSTALL_FAULT
    Delete "$TEMP\herdr-uninstall-fault-${HERDR_TEST_UNINSTALL_FAULT}.once"
  !endif
  SetErrorLevel 0
SectionEnd
