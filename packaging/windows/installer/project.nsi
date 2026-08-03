; Product identity, payloads, and runtime protocol names are build inputs.
!ifndef ARG_STAGE_DIR
  !error "ARG_STAGE_DIR is required"
!endif
!ifndef ARG_LAUNCHER_EXE
  !error "ARG_LAUNCHER_EXE is required"
!endif
!ifndef ARG_HELPER_PS1
  !error "ARG_HELPER_PS1 is required"
!endif
!ifndef ARG_SKILL_MD
  !error "ARG_SKILL_MD is required"
!endif
!ifndef ARG_ARTWORK_DIR
  !error "ARG_ARTWORK_DIR is required"
!endif
!ifndef APP_BUILD_ID
  !error "APP_BUILD_ID is required"
!endif
!ifndef INFO_PRODUCTVERSION_DISPLAY
  !error "INFO_PRODUCTVERSION_DISPLAY is required"
!endif
!ifndef INFO_PRODUCTVERSION_FIXED
  !error "INFO_PRODUCTVERSION_FIXED is required"
!endif
!ifndef INFO_PRODUCTVERSION_UI
  !error "INFO_PRODUCTVERSION_UI is required"
!endif
!ifndef APP_OUTPUT_PATH
  !error "APP_OUTPUT_PATH is required"
!endif
!ifndef INFO_PRODUCTNAME
  !error "INFO_PRODUCTNAME is required"
!endif
!ifndef INFO_DISTRIBUTIONNAME
  !error "INFO_DISTRIBUTIONNAME is required"
!endif
!ifndef INFO_COMPANYNAME
  !error "INFO_COMPANYNAME is required"
!endif
!ifndef INFO_COPYRIGHT
  !error "INFO_COPYRIGHT is required"
!endif
!ifndef INFO_PRODUCTURL
  !error "INFO_PRODUCTURL is required"
!endif
!ifndef INFO_UPSTREAMURL
  !error "INFO_UPSTREAMURL is required"
!endif
!ifndef INFO_COMMANDNAME
  !error "INFO_COMMANDNAME is required"
!endif
!ifndef INFO_ORIGINALFILENAME
  !error "INFO_ORIGINALFILENAME is required"
!endif
!ifndef APP_START_GATE_ENV
  !error "APP_START_GATE_ENV is required"
!endif
!ifndef APP_TEST_MARKER_PREFIX
  !error "APP_TEST_MARKER_PREFIX is required"
!endif

Unicode true
!define APP_LANG_ENGLISH 1033

Name "${INFO_DISTRIBUTIONNAME}"
Caption "${INFO_DISTRIBUTIONNAME} Setup"
OutFile "${APP_OUTPUT_PATH}"
InstallDir "$LOCALAPPDATA\Programs\${INFO_PRODUCTNAME}"
RequestExecutionLevel user
SetCompressor lzma
SetDatablockOptimize on
SetCompressorDictSize 8
SetCompressor /SOLID /FINAL lzma
AllowSkipFiles off
ShowInstDetails show
ShowUninstDetails show
AutoCloseWindow true
ManifestDPIAware true
VIProductVersion "${INFO_PRODUCTVERSION_FIXED}"
VIFileVersion "${INFO_PRODUCTVERSION_FIXED}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "ProductName" "${INFO_DISTRIBUTIONNAME}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "CompanyName" "${INFO_COMPANYNAME}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "LegalCopyright" "${INFO_COPYRIGHT}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "FileDescription" "${INFO_DISTRIBUTIONNAME} per-user installer"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "FileVersion" "${INFO_PRODUCTVERSION_DISPLAY}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "ProductVersion" "${INFO_PRODUCTVERSION_DISPLAY}"
VIAddVersionKey /LANG=${APP_LANG_ENGLISH} "OriginalFilename" "${INFO_ORIGINALFILENAME}"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "WinMessages.nsh"
!include "x64.nsh"

Var PowerShellPath
Var HelperExitCode
Var HelperOutput
Var StartGate
Var ResidualValid
Var ResidualFindHandle
Var ResidualFindName
Var SettingsDisposition
Var SettingsCheckbox
Var UpstreamLink

!define INSTALLER_WELCOME_BITMAP_100 "${ARG_ARTWORK_DIR}\installer-welcome-finish-164x314.bmp"
!define INSTALLER_WELCOME_BITMAP_125 "${ARG_ARTWORK_DIR}\installer-welcome-finish-205x393.bmp"
!define INSTALLER_WELCOME_BITMAP_150 "${ARG_ARTWORK_DIR}\installer-welcome-finish-246x471.bmp"
!define INSTALLER_WELCOME_BITMAP_175 "${ARG_ARTWORK_DIR}\installer-welcome-finish-287x550.bmp"
!define INSTALLER_WELCOME_BITMAP_200 "${ARG_ARTWORK_DIR}\installer-welcome-finish-328x628.bmp"

!define MUI_ABORTWARNING
!define MUI_UNABORTWARNING
!define MUI_WELCOMEFINISHPAGE_BITMAP "${INSTALLER_WELCOME_BITMAP_100}"
!define MUI_WELCOMEFINISHPAGE_BITMAP_STRETCH NoStretchNoCropNoAlign
!define MUI_CUSTOMFUNCTION_GUIINIT SelectInstallerWelcomeBitmap
!pragma verifyloadimage "${INSTALLER_WELCOME_BITMAP_125}"
!pragma verifyloadimage "${INSTALLER_WELCOME_BITMAP_150}"
!pragma verifyloadimage "${INSTALLER_WELCOME_BITMAP_175}"
!pragma verifyloadimage "${INSTALLER_WELCOME_BITMAP_200}"
!define MUI_WELCOMEPAGE_TITLE "Install ${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI}"
!define MUI_WELCOMEPAGE_TEXT "This setup installs ${INFO_DISTRIBUTIONNAME}, an unofficial Windows distribution of ${INFO_PRODUCTNAME}. It advances Windows support by applying this fork's patches to the latest reviewed stable ${INFO_PRODUCTNAME} release.$\r$\n$\r$\nNo administrator access is required. Open a new terminal after setup so it can find ${INFO_COMMANDNAME} on PATH."
!define MUI_FINISHPAGE_NOREBOOTSUPPORT
!define MUI_FINISHPAGE_TITLE "${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI} is installed"
!define MUI_FINISHPAGE_TEXT "Setup completed successfully.$\r$\n$\r$\n${INFO_DISTRIBUTIONNAME} is an unofficial distribution; the command remains ${INFO_COMMANDNAME} and no application window opens.$\r$\n$\r$\nOpen a new terminal, then run:$\r$\n${INFO_COMMANDNAME}"
!define MUI_FINISHPAGE_LINK "Open ${INFO_DISTRIBUTIONNAME} setup and usage guide"
!define MUI_FINISHPAGE_LINK_LOCATION "${INFO_PRODUCTURL}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${ARG_STAGE_DIR}\LICENSE.txt"
!insertmacro MUI_PAGE_INSTFILES
!define MUI_PAGE_CUSTOMFUNCTION_SHOW PositionInstallerFinishLink
!insertmacro MUI_PAGE_FINISH

UninstPage custom un.SettingsPage un.SettingsPageLeave
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

LangString AppSettingsPageTitle ${LANG_ENGLISH} "Remove local ${INFO_DISTRIBUTIONNAME} data"
LangString AppSettingsPageSubtitle ${LANG_ENGLISH} "Choose what remains after uninstall."
LangString AppSettingsPageText ${LANG_ENGLISH} "Uninstall removes the managed program, user PATH entry, Windows Installed Apps registration, and managed skill copies. Settings and session data are kept by default. Select this option to delete them too. Other files are not removed."
LangString AppSettingsCheckbox ${LANG_ENGLISH} "Also delete ${INFO_PRODUCTNAME} settings and session data"
LangString AppDetailRemoveSettings ${LANG_ENGLISH} "Removing ${INFO_PRODUCTNAME} settings and session data..."

!macro AppUninstallFault Point Label
  !ifdef TEST_UNINSTALL_FAULT
    StrCmp "${TEST_UNINSTALL_FAULT}" "${Point}" 0 fault_done_${Label}
    IfFileExists "$TEMP\${APP_TEST_MARKER_PREFIX}-uninstall-fault-${Point}.once" fault_done_${Label}
    FileOpen $0 "$TEMP\${APP_TEST_MARKER_PREFIX}-uninstall-fault-${Point}.once" w
    FileClose $0
    SetErrors
    Goto uninstall_cleanup_failed
fault_done_${Label}:
  !endif
!macroend

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

Function NotifyEnvironmentChange
  System::Call 'USER32::SendMessageTimeoutW(p 0xffff, i ${WM_SETTINGCHANGE}, p 0, w "Environment", i 0x2, i 5000, *p .r0)'
FunctionEnd

Function un.NotifyEnvironmentChange
  System::Call 'USER32::SendMessageTimeoutW(p 0xffff, i ${WM_SETTINGCHANGE}, p 0, w "Environment", i 0x2, i 5000, *p .r0)'
FunctionEnd

Function FailInstall
  Exch $0
  DetailPrint "$0"
  !ifdef TEST_UNINSTALL_FAULT
    FileOpen $1 "$TEMP\${APP_TEST_MARKER_PREFIX}-install-failure-${TEST_UNINSTALL_FAULT}.txt" w
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
  ReadEnvStr $StartGate "${APP_START_GATE_ENV}"
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

Function SelectInstallerWelcomeBitmap
  System::Call 'USER32::GetDpiForWindow(p $HWNDPARENT)i.r0'
  ${If} $0 >= 180
    File "/oname=$PLUGINSDIR\modern-wizard.bmp" "${INSTALLER_WELCOME_BITMAP_200}"
  ${ElseIf} $0 >= 156
    File "/oname=$PLUGINSDIR\modern-wizard.bmp" "${INSTALLER_WELCOME_BITMAP_175}"
  ${ElseIf} $0 >= 132
    File "/oname=$PLUGINSDIR\modern-wizard.bmp" "${INSTALLER_WELCOME_BITMAP_150}"
  ${ElseIf} $0 >= 108
    File "/oname=$PLUGINSDIR\modern-wizard.bmp" "${INSTALLER_WELCOME_BITMAP_125}"
  ${EndIf}
FunctionEnd

Function PositionInstallerFinishLink
  System::Store "S"
  ${NSD_GetText} $mui.FinishPage.Text $0
  System::Call 'USER32::GetWindowRect(p $mui.FinishPage.Text, @r1)'
  System::Call '*$1(i.r2, i.r3, i.r4, i.r5)'
  IntOp $4 $4 - $2
  System::Call '*$1(i 0, i 0, i r4, i 0)'
  System::Call 'USER32::GetDC(p $mui.FinishPage.Text) p.r6'
  SendMessage $mui.FinishPage.Text ${WM_GETFONT} 0 0 $7
  System::Call 'GDI32::SelectObject(p r6, p r7) p.s'
  System::Call 'USER32::DrawTextW(p r6, w r0, i -1, p r1, i 0x00000C10)'
  System::Call '*$1(i, i, i, i.r8)'
  System::Call 'GDI32::SelectObject(p r6, p s)'
  System::Call 'USER32::ReleaseDC(p $mui.FinishPage.Text, p r6)'

  System::Call 'USER32::GetWindowRect(p $mui.FinishPage.Text, @r1)'
  System::Call 'USER32::MapWindowPoints(p 0, p $mui.FinishPage, p r1, i 2)'
  System::Call '*$1(i.r2, i.r3, i.r4, i.r5)'
  IntOp $7 $4 - $2
  System::Call 'USER32::SetWindowPos(p $mui.FinishPage.Text, p 0, i r2, i r3, i r7, i r8, i 0x14)'

  System::Call 'USER32::GetWindowRect(p $mui.FinishPage.Link, @r1)'
  System::Call 'USER32::MapWindowPoints(p 0, p $mui.FinishPage, p r1, i 2)'
  System::Call '*$1(i.r2, i.r4, i.r5, i.r6)'
  IntOp $7 $5 - $2
  IntOp $9 $6 - $4
  IntOp $8 $8 + $3
  IntOp $8 $8 + $9
  System::Call 'USER32::SetWindowPos(p $mui.FinishPage.Link, p 0, i r2, i r8, i r7, i r9, i 0x14)'

  ${NSD_CreateLink} 120u 185u 195u 10u "Open official ${INFO_PRODUCTNAME} project"
  Pop $UpstreamLink
  SetCtlColors $UpstreamLink "000080" "FFFFFF"
  ${NSD_OnClick} $UpstreamLink OpenInstallerUpstream
  IntOp $8 $8 + $9
  IntOp $8 $8 + 2
  System::Call 'USER32::SetWindowPos(p $UpstreamLink, p 0, i r2, i r8, i r7, i r9, i 0x14)'
  System::Store "L"
FunctionEnd

Function OpenInstallerUpstream
  ExecShell open "${INFO_UPSTREAMURL}"
FunctionEnd

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    Push "${INFO_DISTRIBUTIONNAME} requires 64-bit Windows."
    Call FailInstall
  ${EndIf}
  Call WaitForUpdaterStartGate
  Call SetPowerShellPath
  IfFileExists "$PowerShellPath" powershell_ok
  Push "Windows PowerShell is required to install ${INFO_DISTRIBUTIONNAME}."
  Call FailInstall
powershell_ok:
FunctionEnd

Function un.onInit
  SetShellVarContext current
  StrCpy $SettingsDisposition "Keep"
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} "$0" "/REMOVE_SETTINGS" $1
  ${IfNot} ${Errors}
    StrCpy $SettingsDisposition "Remove"
  ${EndIf}
  Call un.SetPowerShellPath
  IfFileExists "$PowerShellPath" un_powershell_ok
  Push "Windows PowerShell is required to uninstall ${INFO_DISTRIBUTIONNAME}."
  Call un.FailUninstall
un_powershell_ok:
FunctionEnd

Function un.SettingsPage
  IfSilent settings_page_done 0
  !insertmacro MUI_HEADER_TEXT "$(AppSettingsPageTitle)" "$(AppSettingsPageSubtitle)"
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 72u "$(AppSettingsPageText)"
  Pop $0
  ${NSD_CreateCheckbox} 0 82u 100% 14u "$(AppSettingsCheckbox)"
  Pop $SettingsCheckbox
  ${If} $SettingsDisposition == "Remove"
    ${NSD_Check} $SettingsCheckbox
  ${EndIf}
  nsDialogs::Show
settings_page_done:
FunctionEnd

Function un.SettingsPageLeave
  IfSilent settings_page_leave_done 0
  ${If} $SettingsCheckbox == ""
    Goto settings_page_leave_done
  ${EndIf}

  ${NSD_GetState} $SettingsCheckbox $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $SettingsDisposition "Remove"
  ${Else}
    StrCpy $SettingsDisposition "Keep"
  ${EndIf}
settings_page_leave_done:
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

Section "${INFO_DISTRIBUTIONNAME}" SEC_APP
  SectionIn RO
  InitPluginsDir
  ClearErrors
  SetOutPath "$PLUGINSDIR\payload"
  File /r "${ARG_STAGE_DIR}\*"
  SetOutPath "$PLUGINSDIR"
  File /oname=app-launcher.exe "${ARG_LAUNCHER_EXE}"
  File /oname=installer-helper.ps1 "${ARG_HELPER_PS1}"
  SetOutPath "$PLUGINSDIR\skill"
  File /oname=SKILL.md "${ARG_SKILL_MD}"
  SetOutPath "$PLUGINSDIR"
  WriteUninstaller "$PLUGINSDIR\uninstall.exe"
  IfErrors 0 installer_inputs_ready
  Push "${INFO_DISTRIBUTIONNAME} setup could not unpack its embedded, pre-verified files."
  Call FailInstall

installer_inputs_ready:
  DetailPrint "Validating and activating ${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI}..."
  nsExec::ExecToStack /TIMEOUT=120000 '"$PowerShellPath" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-helper.ps1" -Action Install -InstallRoot "$INSTDIR" -StageDir "$PLUGINSDIR\payload" -LauncherPath "$PLUGINSDIR\app-launcher.exe" -UninstallerPath "$PLUGINSDIR\uninstall.exe" -HelperSourcePath "$PLUGINSDIR\installer-helper.ps1" -SkillSourcePath "$PLUGINSDIR\skill\SKILL.md" -ProductName "${INFO_DISTRIBUTIONNAME}" -BuildId "${APP_BUILD_ID}" -DisplayVersion "${INFO_PRODUCTVERSION_DISPLAY}" -NumericVersion "${INFO_PRODUCTVERSION_FIXED}"'
  Pop $HelperExitCode
  Pop $HelperOutput
  StrCmp $HelperExitCode "0" installer_complete
  StrCpy $0 "${INFO_DISTRIBUTIONNAME} setup failed ($HelperExitCode). $HelperOutput"
  Push $0
  Call FailInstall

installer_complete:
  DetailPrint "$HelperOutput"
  Call NotifyEnvironmentChange
  SetErrorLevel 0
SectionEnd

Section "Uninstall"
  SetAutoClose true
  Call un.ValidateResidualLayout
  StrCmp $ResidualValid "1" un_residual_exact
  IfFileExists "$INSTDIR\state\installer-helper.ps1" un_helper_ready
  Push "The managed ${INFO_DISTRIBUTIONNAME} uninstall helper is missing; the install was preserved."
  Call un.FailUninstall

un_residual_exact:
  ; uninstall.pending is removed only after a helper completed PATH/ARP work.
  ; If it remains, rerun that helper instead of mistaking layout-only progress
  ; for a completed uninstall integration lifecycle.
  IfFileExists "$INSTDIR\state\uninstall.pending" un_residual_pending un_residual_ready

un_residual_pending:
  IfFileExists "$INSTDIR\state\installer-helper.ps1" un_helper_ready
  Push "${INFO_DISTRIBUTIONNAME} uninstall is pending but its retry helper is missing; residual files were preserved."
  Call un.FailUninstall

un_helper_ready:
  nsExec::ExecToStack /TIMEOUT=120000 '"$PowerShellPath" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\state\installer-helper.ps1" -Action Uninstall -InstallRoot "$INSTDIR" -ProductName "${INFO_DISTRIBUTIONNAME}" -SettingsDisposition "$SettingsDisposition"'
  Pop $HelperExitCode
  Pop $HelperOutput
  StrCmp $HelperExitCode "0" un_helper_complete
  StrCpy $0 "${INFO_DISTRIBUTIONNAME} uninstall failed ($HelperExitCode). $HelperOutput"
  Push $0
  Call un.FailUninstall

un_helper_complete:
  DetailPrint "$HelperOutput"
  Call un.NotifyEnvironmentChange
  ${If} $SettingsDisposition == "Remove"
    DetailPrint "$(AppDetailRemoveSettings)"
  ${EndIf}
  Call un.ValidateResidualLayout
  StrCmp $ResidualValid "1" un_cleanup_start
  Push "${INFO_DISTRIBUTIONNAME} uninstall did not leave an exact recognized residual layout; cleanup was preserved."
  Call un.FailUninstall

un_residual_ready:
  DetailPrint "Resuming exact ${INFO_DISTRIBUTIONNAME} residual cleanup."

un_cleanup_start:
  ClearErrors
  ; Reaching this block proves the helper completed PATH/ARP cleanup. Remove
  ; the retry marker first so every later exact residual resumes here instead
  ; of re-entering a helper whose coordination file may already be gone.
  Delete "$INSTDIR\state\uninstall.pending"
  IfErrors uninstall_cleanup_failed
  !insertmacro AppUninstallFault "after-uninstall-pending" after_uninstall_pending
  Delete "$INSTDIR\state\launcher.lock"
  IfErrors uninstall_cleanup_failed
  !insertmacro AppUninstallFault "after-launcher-lock" after_launcher_lock
  Delete "$INSTDIR\state\installer-helper.ps1"
  IfErrors uninstall_cleanup_failed
  !insertmacro AppUninstallFault "after-installer-helper" after_installer_helper
  RMDir "$INSTDIR\state"
  IfErrors uninstall_cleanup_failed
  !insertmacro AppUninstallFault "after-state-directory" after_state_directory
  !insertmacro AppUninstallFault "before-uninstaller" before_uninstaller
  Delete "$INSTDIR\uninstall.exe"
  IfErrors uninstall_cleanup_failed
  ; After self-removal only the install root can remain. Preserve any racing
  ; unowned content, but do not report an unretryable failure without an owner.
  ClearErrors
  RMDir "$INSTDIR"
  IfErrors 0 uninstall_complete
  DetailPrint "${INFO_DISTRIBUTIONNAME} was removed; a non-empty install directory was preserved."
  ClearErrors
  Goto uninstall_complete
uninstall_cleanup_failed:
  Push "${INFO_DISTRIBUTIONNAME} uninstall could not remove its validated residual files. Retry uninstall."
  Call un.FailUninstall
uninstall_complete:
  !ifdef TEST_UNINSTALL_FAULT
    Delete "$TEMP\${APP_TEST_MARKER_PREFIX}-uninstall-fault-${TEST_UNINSTALL_FAULT}.once"
  !endif
  SetErrorLevel 0
SectionEnd
