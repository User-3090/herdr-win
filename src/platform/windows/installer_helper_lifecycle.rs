use std::{
    collections::BTreeSet,
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    io::{self, Write as _},
    os::windows::{
        ffi::OsStringExt as _,
        fs::{MetadataExt as _, OpenOptionsExt as _},
        io::AsRawHandle as _,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_ACCESS_DENIED, ERROR_NO_MORE_FILES, HANDLE, INVALID_HANDLE_VALUE,
    },
    Storage::FileSystem::{FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
        JobObjects::{AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject},
        Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
    },
};

use crate::{
    managed_install::{BuildId, ManagedInstall, WINGET_PACKAGE_MANAGER_RECORD},
    windows_managed_install::CoordinationLease,
};

use super::{
    installer_helper_files as files, installer_helper_registry as registry,
    installer_helper_skills::{self as skills, SkillDisposition},
};

const LOCK_TIMEOUT: Duration = Duration::from_secs(30);
const LOCK_RETRY: Duration = Duration::from_millis(50);
const QUIET_UNINSTALL_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InstallManager {
    Direct,
    WinGet,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SettingsDisposition {
    Keep,
    Remove,
}

#[derive(Clone, Debug)]
pub(crate) struct InstallOptions {
    pub(crate) install_root: PathBuf,
    pub(crate) user_profile_root: PathBuf,
    pub(crate) package_root: PathBuf,
    pub(crate) build_id: BuildId,
    pub(crate) display_version: String,
    pub(crate) numeric_version: String,
    pub(crate) install_manager: InstallManager,
}

#[derive(Clone, Debug)]
pub(crate) struct UninstallOptions {
    pub(crate) install_root: PathBuf,
    pub(crate) user_profile_root: PathBuf,
    pub(crate) skill_hash_manifest: PathBuf,
    pub(crate) settings_disposition: SettingsDisposition,
    pub(crate) skill_disposition: SkillDisposition,
    pub(crate) fault: Option<String>,
    pub(crate) fault_marker_prefix: String,
    pub(crate) quiet_runner: Option<QuietRunnerOptions>,
}

#[derive(Clone, Debug)]
pub(crate) struct QuietRunnerOptions {
    pub(crate) process_id: u32,
    pub(crate) token: String,
}

#[derive(Clone, Debug)]
pub(crate) struct QuietUninstallOptions {
    pub(crate) install_root: PathBuf,
}

#[derive(Clone, Debug)]
pub(crate) struct SkillDefaultOptions {
    pub(crate) user_profile_root: PathBuf,
    pub(crate) skill_hash_manifest: PathBuf,
}

#[derive(Clone, Debug)]
pub(crate) struct MaintenanceOptions {
    pub(crate) install_root: PathBuf,
    pub(crate) parent_process_id: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RootKind {
    New,
    ManagedNative,
    UninstallRetry,
    UninstallResidual,
}

#[derive(Debug)]
struct Staging {
    path: PathBuf,
    kind: &'static str,
    install_root: PathBuf,
}

#[derive(Debug)]
struct LeaseStatus {
    active: Vec<PathBuf>,
    stale: Vec<PathBuf>,
    ambiguous: Vec<PathBuf>,
}

#[derive(Debug)]
struct ProcessHandle(HANDLE);

#[derive(Debug)]
struct ProcessJob(HANDLE);

#[derive(Clone, Debug)]
struct QuietSession {
    process_id: u32,
    result_path: PathBuf,
    moved_helper_path: PathBuf,
}

impl Drop for ProcessHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: this wrapper owns the process or snapshot handle.
            unsafe { CloseHandle(self.0) };
        }
    }
}

impl ProcessJob {
    fn new() -> io::Result<Self> {
        // SAFETY: null security attributes and name request a private job. This
        // guard owns the returned handle.
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(handle))
    }

    fn assign(&self, child: &Child) -> io::Result<()> {
        // SAFETY: the job and process handles remain valid for this call.
        if unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle() as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn terminate(&self) -> io::Result<()> {
        // SAFETY: this guard owns a valid job handle.
        if unsafe { TerminateJobObject(self.0, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for ProcessJob {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: this guard uniquely owns the job handle. The job has no
            // kill-on-close policy, so successful NSIS cleanup may finish.
            unsafe { CloseHandle(self.0) };
        }
    }
}

impl QuietSession {
    fn new(install_root: &Path, options: &QuietRunnerOptions) -> io::Result<Self> {
        validate_quiet_token(&options.token)?;
        if options.process_id == 0 || options.process_id == std::process::id() {
            return Err(files::invalid_data(
                "quiet-uninstall runner process ID is invalid",
            ));
        }
        let expected = install_root.join("state").join(files::NATIVE_HELPER_NAME);
        files::assert_regular_file(&expected)?;
        let actual = process_path(options.process_id).ok_or_else(|| {
            files::invalid_data("quiet-uninstall runner process is not available")
        })?;
        if !files::path_eq(&actual, &expected)? {
            return Err(files::invalid_data(
                "quiet-uninstall runner is not the installed native helper",
            ));
        }
        let (result_path, moved_helper_path) = quiet_paths(install_root, &options.token)?;
        files::assert_regular_file(&result_path)?;
        if fs::read(&result_path)? != files::QUIET_UNINSTALL_PENDING {
            return Err(files::invalid_data(
                "quiet-uninstall rendezvous is not pending",
            ));
        }
        if files::path_exists(&moved_helper_path)? {
            return Err(files::invalid_data(
                "quiet-uninstall helper handoff path already exists",
            ));
        }
        Ok(Self {
            process_id: options.process_id,
            result_path,
            moved_helper_path,
        })
    }

    fn publish_result(&self, success: bool) -> io::Result<()> {
        files::assert_regular_file(&self.result_path)?;
        if fs::read(&self.result_path)? != files::QUIET_UNINSTALL_PENDING {
            return Err(files::invalid_data(
                "quiet-uninstall rendezvous changed before completion",
            ));
        }
        let replacement = self
            .result_path
            .with_file_name(format!("quiet-result.{}.new", files::unique_hex()));
        files::write_durable(
            &replacement,
            if success {
                files::QUIET_UNINSTALL_SUCCESS
            } else {
                files::QUIET_UNINSTALL_FAILURE
            },
        )?;
        files::replace_file(&self.result_path, &replacement, None)
    }

    fn wait_for_runner_and_remove_helper(&self) -> io::Result<()> {
        if !files::wait_for_process(self.process_id, LOCK_TIMEOUT)? {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "quiet-uninstall runner did not exit before cleanup deadline",
            ));
        }
        remove_file_if_exists(&self.moved_helper_path)
    }
}

fn validate_quiet_token(token: &str) -> io::Result<()> {
    if token.len() != 32
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(files::invalid_data("invalid quiet-uninstall token"));
    }
    Ok(())
}

fn quiet_paths(install_root: &Path, token: &str) -> io::Result<(PathBuf, PathBuf)> {
    validate_quiet_token(token)?;
    let parent = install_root
        .parent()
        .ok_or_else(|| files::invalid_data("install root has no parent"))?;
    files::assert_regular_dir(parent)?;
    let leaf = install_root
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| files::invalid_data("install root has no UTF-8 leaf"))?;
    Ok((
        parent.join(format!("{leaf}.quiet-uninstall.{token}.result")),
        parent.join(format!("{leaf}.quiet-uninstall.{token}.exe")),
    ))
}

pub(crate) fn install(options: InstallOptions) -> io::Result<String> {
    let install_root = files::full_path(&options.install_root)?;
    let profile = skills::user_profile_root(&options.user_profile_root)?;
    let _lifecycle = acquire_lifecycle_lock(&install_root, LOCK_TIMEOUT)?;
    registry::assert_arp_ownership(&install_root)?;
    let allow_convergence = registry::arp_exists()?;
    let previous_path_owned = registry::arp_path_owned(&install_root)?;
    let agent_root = skills::agent_skills_root(&profile)?;
    let claude_root = if skills::claude_installed(&profile)? {
        Some(skills::claude_skills_root(
            &profile,
            std::env::var("CLAUDE_CONFIG_DIR").ok().as_deref(),
        )?)
    } else {
        None
    };
    let result = install_layout(
        &install_root,
        &options.package_root,
        &options.build_id,
        &options.display_version,
        &options.numeric_version,
        options.install_manager,
        &agent_root,
        claude_root.as_deref(),
        allow_convergence,
    )?;
    let path_update = registry::add_user_path(&install_root.join("bin"), previous_path_owned)?;
    registry::set_arp_registration(
        &install_root,
        &options.display_version,
        &options.numeric_version,
        path_update.owned,
    )?;
    Ok(result)
}

pub(crate) fn uninstall(options: UninstallOptions) -> io::Result<String> {
    let install_root = files::full_path(&options.install_root)?;
    let quiet = options
        .quiet_runner
        .as_ref()
        .map(|value| QuietSession::new(&install_root, value))
        .transpose()?;
    let result = (|| {
        let profile = skills::user_profile_root(&options.user_profile_root)?;
        let known = skills::read_managed_skill_hashes(&options.skill_hash_manifest, None)?;
        let _lifecycle = acquire_lifecycle_lock(&install_root, LOCK_TIMEOUT)?;
        registry::assert_arp_ownership(&install_root)?;
        let allow_convergence = registry::arp_exists()?;
        let path_owned = registry::arp_path_owned(&install_root)?;
        let agent_root = skills::agent_skills_root(&profile)?;
        let claude_roots = skills::claude_roots_for_removal(&profile)?;
        let mut warnings = Vec::new();
        let (preserved, warning) = uninstall_layout(
            &install_root,
            &agent_root,
            &claude_roots,
            &known,
            options.skill_disposition,
            allow_convergence,
            options.fault.as_deref(),
            &options.fault_marker_prefix,
            quiet.as_ref(),
        )?;
        if let Some(warning) = warning {
            warnings.push(warning);
        }
        let _ = registry::remove_user_path(&install_root.join("bin"), path_owned)?;
        registry::remove_arp_registration(&install_root)?;
        if options.settings_disposition == SettingsDisposition::Remove {
            if let Err(err) = skills::remove_user_settings(&profile) {
                warnings.push(format!(
                "Warning: Selected Herdr settings cleanup was incomplete; locked or unsafe settings were preserved. {err}"
            ));
            }
        }
        remove_fault_marker(options.fault.as_deref(), &options.fault_marker_prefix)?;
        let mut output = String::from("Herdr Win uninstall cleanup is ready.");
        for path in preserved {
            output.push_str(&format!("\nPreserved Herdr skill: {}", path.display()));
        }
        for warning in warnings {
            output.push_str(&format!("\n{warning}"));
        }
        Ok(output)
    })();
    if let Some(quiet) = &quiet {
        let success = result.is_ok();
        let publish_result = quiet.publish_result(success);
        if files::path_exists(&quiet.moved_helper_path)? {
            if publish_result.is_ok() {
                quiet.wait_for_runner_and_remove_helper()?;
            } else {
                let _ = files::wait_for_process(
                    quiet.process_id,
                    QUIET_UNINSTALL_TIMEOUT + LOCK_TIMEOUT,
                );
                remove_file_if_exists(&quiet.moved_helper_path)?;
            }
        }
        publish_result?;
    }
    result
}

pub(crate) fn quiet_uninstall(options: QuietUninstallOptions) -> io::Result<String> {
    let install_root = files::full_path(&options.install_root)?;
    let expected_helper = install_root.join("state").join(files::NATIVE_HELPER_NAME);
    let current = std::env::current_exe()?;
    if !files::path_eq(&current, &expected_helper)? {
        return Err(files::invalid_data(
            "quiet uninstall must run from the installed native helper",
        ));
    }
    if !matches!(
        classify_root(&install_root, false)?,
        RootKind::ManagedNative | RootKind::UninstallRetry | RootKind::UninstallResidual
    ) {
        return Err(files::invalid_data(
            "quiet uninstall requires an exact native managed or retry root",
        ));
    }
    registry::assert_arp_ownership(&install_root)?;
    let token = files::unique_hex();
    let (result_path, moved_helper_path) = quiet_paths(&install_root, &token)?;
    if files::path_exists(&result_path)? || files::path_exists(&moved_helper_path)? {
        return Err(files::invalid_data(
            "quiet-uninstall rendezvous path already exists",
        ));
    }
    files::write_durable(&result_path, files::QUIET_UNINSTALL_PENDING)?;
    let uninstaller = install_root.join("uninstall.exe");
    files::assert_regular_file(&uninstaller)?;
    let job = ProcessJob::new()?;
    let mut child = Command::new(&uninstaller)
        .arg("/S")
        .arg(format!("/NATIVE_QUIET_RUNNER_PID={}", std::process::id()))
        .arg(format!("/NATIVE_QUIET_TOKEN={token}"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| files::contextual(err, "failed to start native quiet uninstall"))?;
    if let Err(err) = job.assign(&child) {
        let _ = child.kill();
        let _ = child.wait();
        remove_file_if_exists(&result_path)?;
        return Err(files::contextual(
            err,
            "failed to contain native quiet uninstall process tree",
        ));
    }
    let deadline = Instant::now() + QUIET_UNINSTALL_TIMEOUT;
    loop {
        if files::path_exists(&result_path)? {
            files::assert_regular_file(&result_path)?;
            let status = fs::read(&result_path)?;
            if status != files::QUIET_UNINSTALL_PENDING {
                remove_file_if_exists(&result_path)?;
                return match status.as_slice() {
                    files::QUIET_UNINSTALL_SUCCESS => {
                        Ok("Herdr Win quiet uninstall completed.".to_string())
                    }
                    files::QUIET_UNINSTALL_FAILURE => Err(files::invalid_data(
                        "native quiet uninstall reported failure",
                    )),
                    _ => Err(files::invalid_data(
                        "native quiet uninstall returned malformed status",
                    )),
                };
            }
        }
        if let Some(status) = child.try_wait()? {
            if !status.success() {
                remove_file_if_exists(&result_path)?;
                return Err(files::invalid_data(format!(
                    "native quiet uninstall bootstrap exited with {status}"
                )));
            }
        }
        if Instant::now() >= deadline {
            if !files::path_exists(&moved_helper_path)? && files::path_exists(&install_root)? {
                let _ = job.terminate();
            }
            remove_file_if_exists(&result_path)?;
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "native quiet uninstall exceeded its 180 second deadline",
            ));
        }
        thread::sleep(LOCK_RETRY);
    }
}

pub(crate) fn skill_removal_default(options: SkillDefaultOptions) -> io::Result<String> {
    let profile = skills::user_profile_root(&options.user_profile_root)?;
    let known = skills::read_managed_skill_hashes(&options.skill_hash_manifest, None)?;
    let agent = skills::agent_skills_root(&profile)?;
    let claude = skills::claude_roots_for_removal(&profile)?;
    Ok(skills::skill_removal_default(&agent, &claude, &known)?.to_string())
}

pub(crate) fn complete_maintenance(options: MaintenanceOptions) -> io::Result<String> {
    if !files::wait_for_process(options.parent_process_id, LOCK_TIMEOUT)? {
        return Ok("Herdr Win maintenance: Deferred".to_string());
    }
    let install_root = files::full_path(&options.install_root)?;
    let _lifecycle = acquire_lifecycle_lock(&install_root, LOCK_TIMEOUT)?;
    if !files::path_exists(&install_root)? {
        return Ok("Herdr Win maintenance: Missing".to_string());
    }
    repair_launcher_publication(&install_root)?;
    remove_stale_staging(&install_root);
    if !matches!(
        classify_root(&install_root, false),
        Ok(RootKind::ManagedNative)
    ) {
        return Ok("Herdr Win maintenance: Deferred".to_string());
    }
    let _coordination =
        acquire_coordination(&ManagedInstall::new(install_root.clone()), LOCK_TIMEOUT)?;
    maintenance_locked(&install_root)?;
    Ok("Herdr Win maintenance: Complete".to_string())
}

fn install_layout(
    install_root: &Path,
    package_root: &Path,
    build_id: &BuildId,
    display_version: &str,
    numeric_version: &str,
    requested_manager: InstallManager,
    agent_skills_root: &Path,
    claude_skills_root: Option<&Path>,
    allow_convergence: bool,
) -> io::Result<String> {
    let package_root = files::full_path(package_root)?;
    let stage = package_root.join("payload");
    let launcher = package_root.join("app-launcher.exe");
    let helper = package_root.join("installer-helper.exe");
    let uninstaller = package_root.join("uninstall.exe");
    let skill = package_root.join("skill").join("SKILL.md");
    let skill_hashes = package_root.join("skill").join("managed-skill-hashes.txt");
    files::assert_regular_dir(&stage)?;
    for path in [&launcher, &helper, &uninstaller, &skill, &skill_hashes] {
        files::assert_regular_file(path)?;
    }
    let queried = files::query_launcher_build_id(&launcher, LOCK_TIMEOUT)?;
    if queried != *build_id {
        return Err(files::invalid_data(format!(
            "launcher build ID {} does not match runtime {}",
            queried.as_str(),
            build_id.as_str()
        )));
    }
    files::validate_version_identity(display_version, numeric_version)?;
    let known = skills::read_managed_skill_hashes(&skill_hashes, Some(&skill))?;
    remove_stale_staging(install_root);
    if unsupported_launcher_hop(install_root)? {
        return Err(incompatible_root(install_root));
    }
    let mut kind = match classify_root(install_root, true) {
        Ok(value) => value,
        Err(err) if allow_convergence => {
            let _ = writeln!(
                io::stderr().lock(),
                "Warning: The registered current Herdr root could not use normal repair and will be rebuilt directly. {err}"
            );
            remove_current_root_for_convergence(install_root)?;
            RootKind::New
        }
        Err(err) => return Err(err),
    };
    if kind == RootKind::UninstallRetry {
        let _ = uninstall_layout(
            install_root,
            agent_skills_root,
            &claude_skills_root
                .into_iter()
                .map(Path::to_path_buf)
                .collect::<Vec<_>>(),
            &known,
            SkillDisposition::Keep,
            true,
            None,
            "herdr",
            None,
        )?;
        kind = RootKind::New;
    } else if kind == RootKind::UninstallResidual {
        remove_uninstall_residual(install_root, None, "herdr", None)?;
        kind = RootKind::New;
    }
    let effective_manager =
        if validate_package_manager_marker(&install_root.join("state").join("package-manager"))
            .unwrap_or(false)
        {
            InstallManager::WinGet
        } else {
            requested_manager
        };
    let status = match kind {
        RootKind::ManagedNative => install_upgrade(
            install_root,
            &stage,
            &launcher,
            &helper,
            &uninstaller,
            build_id,
            display_version,
            numeric_version,
            effective_manager,
        )?,
        RootKind::New => install_fresh(
            install_root,
            &stage,
            &launcher,
            &helper,
            &uninstaller,
            build_id,
            display_version,
            numeric_version,
            effective_manager,
        )?,
        RootKind::UninstallRetry | RootKind::UninstallResidual => unreachable!(),
    };
    let preserved =
        skills::install_skill_copies(&skill, agent_skills_root, claude_skills_root, &known)?;
    let mut output = if status == "Pending" {
        format!(
            "Herdr Win {}: Pending; staged until old sessions exit.",
            build_id.as_str()
        )
    } else {
        format!("Herdr Win {}: {status}", build_id.as_str())
    };
    for path in preserved {
        output.push_str(&format!(
            "\nWarning: Existing customized Herdr skill was preserved: {}",
            path.display()
        ));
    }
    Ok(output)
}

#[allow(clippy::too_many_arguments)]
fn install_fresh(
    install_root: &Path,
    stage: &Path,
    launcher: &Path,
    helper: &Path,
    uninstaller: &Path,
    build_id: &BuildId,
    display_version: &str,
    numeric_version: &str,
    manager: InstallManager,
) -> io::Result<&'static str> {
    let staging = new_staging("fresh", install_root)?;
    let root = staging.path.join("root");
    fs::create_dir(&root)?;
    fs::create_dir(root.join("bin"))?;
    fs::create_dir_all(root.join("bin").join("managed-install-v1"))?;
    fs::create_dir(root.join("runtime"))?;
    fs::create_dir(root.join("state"))?;
    fs::create_dir(root.join("state").join("leases"))?;
    files::copy_durable_file(launcher, &root.join("bin").join("herdr.exe"))?;
    files::write_durable(
        &root.join("bin").join("managed-install-v1").join("marker"),
        files::MANAGED_BIN_MARKER,
    )?;
    files::create_runtime_tree(
        &root.join("runtime").join(build_id.as_str()),
        stage,
        build_id,
    )?;
    files::write_durable(&root.join("state").join("launcher.lock"), &[])?;
    files::write_durable(
        &root.join("state").join("active"),
        files::pointer_text(build_id).as_bytes(),
    )?;
    files::copy_durable_file(helper, &root.join("state").join(files::NATIVE_HELPER_NAME))?;
    files::copy_durable_file(uninstaller, &root.join("uninstall.exe"))?;
    files::write_durable(
        &root.join("state").join("install.manifest"),
        files::install_manifest_text(
            &files::sha256(&root.join("bin").join("herdr.exe"))?,
            display_version,
            numeric_version,
        )?
        .as_bytes(),
    )?;
    set_package_manager_marker(&root.join("state"), manager)?;
    validate_managed_root(&root, false)?;
    if files::path_exists(install_root)? {
        return Err(files::invalid_data(
            "install root appeared before fresh publication",
        ));
    }
    fs::rename(&root, install_root)?;
    cleanup_staging(&staging);
    Ok("Activated")
}

#[allow(clippy::too_many_arguments)]
fn install_upgrade(
    install_root: &Path,
    stage: &Path,
    launcher: &Path,
    helper: &Path,
    uninstaller: &Path,
    build_id: &BuildId,
    display_version: &str,
    numeric_version: &str,
    manager: InstallManager,
) -> io::Result<&'static str> {
    let staging = new_staging("update", install_root)?;
    let staged_runtime = staging.path.join("runtime");
    files::create_runtime_tree(&staged_runtime, stage, build_id)?;
    let metadata = staging.path.join("metadata");
    fs::create_dir(&metadata)?;
    files::copy_durable_file(helper, &metadata.join(files::NATIVE_HELPER_NAME))?;
    files::copy_durable_file(uninstaller, &metadata.join("uninstall.exe"))?;
    files::write_durable(
        &metadata.join("pending"),
        files::pointer_text(build_id).as_bytes(),
    )?;
    let install = ManagedInstall::new(install_root.to_path_buf());
    let _coordination = acquire_coordination(&install, LOCK_TIMEOUT)?;
    validate_managed_root(install_root, true)?;
    files::write_durable(
        &metadata.join("install.manifest"),
        files::install_manifest_text(
            &files::sha256(&install_root.join("bin").join("herdr.exe"))?,
            display_version,
            numeric_version,
        )?
        .as_bytes(),
    )?;
    let runtime_destination = install_root.join("runtime").join(build_id.as_str());
    if files::path_exists(&runtime_destination)? {
        files::validate_runtime_directory(&runtime_destination, build_id)?;
        files::validate_runtime_directory(&staged_runtime, build_id)?;
        if fs::read(runtime_destination.join("runtime.manifest"))?
            != fs::read(staged_runtime.join("runtime.manifest"))?
        {
            return Err(files::invalid_data(format!(
                "existing runtime {} differs from staged payload",
                build_id.as_str()
            )));
        }
        files::remove_validated_directory(&staged_runtime)?;
    } else {
        fs::rename(&staged_runtime, &runtime_destination)?;
    }
    let state = install_root.join("state");
    files::publish_file(
        &metadata.join(files::NATIVE_HELPER_NAME),
        &state.join(files::NATIVE_HELPER_NAME),
        &staging.path,
    )?;
    files::publish_file(
        &metadata.join("uninstall.exe"),
        &install_root.join("uninstall.exe"),
        &staging.path,
    )?;
    set_pending_launcher(install_root, launcher, build_id)?;
    let active = install.read_required_active_pointer()?;
    let pending = install.pointer_path("pending");
    if active == *build_id {
        remove_file_if_exists(&pending)?;
        files::publish_file(
            &metadata.join("install.manifest"),
            &state.join("install.manifest"),
            &staging.path,
        )?;
        maintenance_locked(install_root)?;
        set_package_manager_marker(&state, manager)?;
        cleanup_staging(&staging);
        return Ok("AlreadyActive");
    }
    files::publish_file(&metadata.join("pending"), &pending, &staging.path)?;
    let leases = lease_status(&state.join("leases"))?;
    if !leases.active.is_empty() || !leases.ambiguous.is_empty() {
        files::publish_file(
            &metadata.join("install.manifest"),
            &state.join("install.manifest"),
            &staging.path,
        )?;
        maintenance_locked(install_root)?;
        set_package_manager_marker(&state, manager)?;
        cleanup_staging(&staging);
        return Ok("Pending");
    }
    remove_stale_leases(&leases)?;
    files::move_replace(&pending, &state.join("active"))?;
    if install.read_required_active_pointer()? != *build_id || files::path_exists(&pending)? {
        return Err(files::invalid_data(
            "pending activation did not publish expected active pointer",
        ));
    }
    files::publish_file(
        &metadata.join("install.manifest"),
        &state.join("install.manifest"),
        &staging.path,
    )?;
    maintenance_locked(install_root)?;
    set_package_manager_marker(&state, manager)?;
    cleanup_staging(&staging);
    Ok("Activated")
}

fn set_pending_launcher(
    install_root: &Path,
    candidate: &Path,
    build_id: &BuildId,
) -> io::Result<()> {
    if files::query_launcher_build_id(candidate, LOCK_TIMEOUT)? != *build_id {
        return Err(files::invalid_data("candidate launcher build ID mismatch"));
    }
    let state = install_root.join("state");
    let manifest = files::read_install_manifest(&state.join("install.manifest"))?;
    validate_managed_bin(&install_root.join("bin"), &manifest.bootstrap_sha256)?;
    let installed = install_root.join("bin").join("herdr.exe");
    let candidate_hash = files::sha256(candidate)?;
    if let Some(existing) = files::pending_launcher(&state)? {
        if existing.sha256 != candidate_hash {
            fs::remove_file(existing.path)?;
        }
    }
    if files::sha256(&installed)? == candidate_hash {
        if let Some(existing) = files::pending_launcher(&state)? {
            fs::remove_file(existing.path)?;
        }
        return Ok(());
    }
    if files::pending_launcher(&state)?.is_none() {
        files::copy_durable_file(
            candidate,
            &state.join(format!("launcher.pending-{candidate_hash}.exe")),
        )?;
    }
    Ok(())
}

fn maintenance_locked(install_root: &Path) -> io::Result<()> {
    repair_launcher_publication(install_root)?;
    validate_managed_root(install_root, false)?;
    remove_inactive_runtimes(install_root)?;
    let _ = complete_launcher_update_locked(install_root)?;
    repair_launcher_publication(install_root)?;
    validate_managed_root(install_root, false)
}

fn complete_launcher_update_locked(install_root: &Path) -> io::Result<bool> {
    repair_launcher_publication(install_root)?;
    let state = install_root.join("state");
    let Some(pending) = files::pending_launcher(&state)? else {
        return Ok(false);
    };
    let leases = lease_status(&state.join("leases"))?;
    if !leases.active.is_empty() || !leases.ambiguous.is_empty() {
        return Ok(false);
    }
    let active = ManagedInstall::new(install_root.to_path_buf()).read_required_active_pointer()?;
    if files::query_launcher_build_id(&pending.path, LOCK_TIMEOUT)? != active {
        return Err(files::invalid_data(
            "pending launcher build ID does not match active runtime",
        ));
    }
    let launcher = install_root.join("bin").join("herdr.exe");
    let replacement = install_root
        .join("bin")
        .join(files::LAUNCHER_REPLACEMENT_NAME);
    remove_file_if_exists(&replacement)?;
    files::copy_durable_file(&pending.path, &replacement)?;
    let staging = new_staging("update", install_root)?;
    let backup = staging
        .path
        .join(format!("launcher.backup.{}", files::unique_hex()));
    if let Err(err) = files::replace_file(&launcher, &replacement, Some(&backup)) {
        remove_file_if_exists(&replacement)?;
        cleanup_staging(&staging);
        if err.kind() == io::ErrorKind::PermissionDenied {
            return Ok(false);
        }
        return Ok(false);
    }
    remove_file_if_exists(&backup)?;
    cleanup_staging(&staging);
    if files::sha256(&launcher)? != pending.sha256 {
        return Err(files::invalid_data(
            "published launcher does not match staged hash",
        ));
    }
    repair_launcher_publication(install_root)?;
    Ok(true)
}

fn repair_launcher_publication(install_root: &Path) -> io::Result<()> {
    if !files::path_exists(install_root)? {
        return Ok(());
    }
    files::assert_regular_dir(install_root)?;
    let state = install_root.join("state");
    let manifest_path = state.join("install.manifest");
    if !files::path_exists(&manifest_path)? {
        return Ok(());
    }
    let manifest = files::read_install_manifest(&manifest_path)?;
    let launcher = install_root.join("bin").join("herdr.exe");
    files::assert_regular_file(&launcher)?;
    let pending = files::pending_launcher(&state)?;
    let replacement = install_root
        .join("bin")
        .join(files::LAUNCHER_REPLACEMENT_NAME);
    if files::path_exists(&replacement)? {
        files::assert_regular_file(&replacement)?;
        if pending
            .as_ref()
            .map(|value| files::sha256(&replacement).map(|hash| hash != value.sha256))
            .transpose()?
            .unwrap_or(true)
        {
            return Err(files::invalid_data(
                "unrecognized managed launcher replacement file",
            ));
        }
        fs::remove_file(&replacement)?;
    }
    let installed_hash = files::sha256(&launcher)?;
    if installed_hash == manifest.bootstrap_sha256 {
        if let Some(pending) = pending {
            if pending.sha256 == installed_hash {
                fs::remove_file(pending.path)?;
            }
        }
        return Ok(());
    }
    let Some(pending) = pending else {
        return Err(files::invalid_data(
            "managed launcher hash matches neither manifest nor pending launcher",
        ));
    };
    if pending.sha256 != installed_hash {
        return Err(files::invalid_data(
            "managed launcher hash matches neither manifest nor pending launcher",
        ));
    }
    let active = ManagedInstall::new(install_root.to_path_buf()).read_required_active_pointer()?;
    if files::query_launcher_build_id(&pending.path, LOCK_TIMEOUT)? != active {
        return Err(files::invalid_data(
            "pending launcher build ID does not match active runtime",
        ));
    }
    let staging = new_staging("update", install_root)?;
    let replacement_manifest = staging.path.join("install.manifest");
    files::write_durable(
        &replacement_manifest,
        files::install_manifest_text(
            &installed_hash,
            &manifest.display_version,
            &manifest.numeric_version,
        )?
        .as_bytes(),
    )?;
    files::publish_file(&replacement_manifest, &manifest_path, &staging.path)?;
    cleanup_staging(&staging);
    fs::remove_file(pending.path)?;
    Ok(())
}

fn remove_inactive_runtimes(install_root: &Path) -> io::Result<()> {
    let install = ManagedInstall::new(install_root.to_path_buf());
    let active = install.read_required_active_pointer()?;
    let pending = install.read_pointer("pending")?;
    let processes = process_paths()?;
    for entry in fs::read_dir(install.runtime_dir())? {
        let entry = entry?;
        let name = entry
            .file_name()
            .to_str()
            .ok_or_else(|| files::invalid_data("runtime directory name is not UTF-8"))?
            .to_string();
        let build = BuildId::parse(&name)?;
        if build == active || pending.as_ref() == Some(&build) {
            continue;
        }
        files::validate_runtime_directory(&entry.path(), &build)?;
        if processes
            .iter()
            .any(|(_, path)| files::path_within(path, &entry.path()).unwrap_or(false))
        {
            continue;
        }
        if install.try_open_exclusive_lease(&build)?.is_none() {
            continue;
        }
        let staging = new_staging("update", install_root)?;
        fs::rename(entry.path(), staging.path.join("runtime"))?;
        cleanup_staging(&staging);
        remove_file_if_exists(&install.lease_path(&build))?;
    }
    Ok(())
}

fn uninstall_layout(
    install_root: &Path,
    agent_root: &Path,
    claude_roots: &[PathBuf],
    known: &BTreeSet<String>,
    skill_disposition: SkillDisposition,
    allow_convergence: bool,
    fault: Option<&str>,
    marker_prefix: &str,
    quiet: Option<&QuietSession>,
) -> io::Result<(Vec<PathBuf>, Option<String>)> {
    remove_stale_staging(install_root);
    if !files::path_exists(install_root)? {
        let (preserved, warning) = skills::remove_skill_copies_best_effort(
            agent_root,
            claude_roots,
            known,
            skill_disposition,
        );
        return Ok((preserved, warning));
    }
    let kind = match classify_root(install_root, false) {
        Ok(value) => value,
        Err(err) if allow_convergence => {
            let _ = writeln!(
                io::stderr().lock(),
                "Warning: The registered current Herdr root could not use normal uninstall recovery and will be removed directly. {err}"
            );
            remove_current_root_for_convergence(install_root)?;
            let result = skills::remove_skill_copies_best_effort(
                agent_root,
                claude_roots,
                known,
                skill_disposition,
            );
            return Ok(result);
        }
        Err(err) => return Err(err),
    };
    if kind == RootKind::UninstallResidual {
        let result = skills::remove_skill_copies_best_effort(
            agent_root,
            claude_roots,
            known,
            skill_disposition,
        );
        remove_uninstall_residual(install_root, fault, marker_prefix, quiet)?;
        return Ok(result);
    }
    if !matches!(kind, RootKind::ManagedNative | RootKind::UninstallRetry) {
        return Err(files::invalid_data(
            "only an exact managed root can be uninstalled",
        ));
    }
    let install = ManagedInstall::new(install_root.to_path_buf());
    let _coordination = acquire_coordination(&install, LOCK_TIMEOUT)?;
    if kind == RootKind::UninstallRetry {
        validate_uninstall_retry_root(install_root)?;
    } else {
        validate_managed_root(install_root, false)?;
    }
    let leases = if files::path_exists(&install.leases_dir())? {
        lease_status(&install.leases_dir())?
    } else {
        LeaseStatus {
            active: vec![],
            stale: vec![],
            ambiguous: vec![],
        }
    };
    if !leases.active.is_empty() || !leases.ambiguous.is_empty() {
        return Err(files::invalid_data(
            "Herdr is still active. Close all managed sessions before uninstalling.",
        ));
    }
    if process_paths()?.iter().any(|(pid, path)| {
        quiet.is_none_or(|quiet| *pid != quiet.process_id)
            && files::path_within(path, install_root).unwrap_or(false)
    }) {
        return Err(files::invalid_data(
            "a process from the managed Herdr install tree is still active",
        ));
    }
    let (preserved, warning) =
        skills::remove_skill_copies_best_effort(agent_root, claude_roots, known, skill_disposition);
    let state = install_root.join("state");
    let marker = state.join("uninstall.pending");
    if !files::path_exists(&marker)? {
        files::write_durable(&marker, files::UNINSTALL_MARKER)?;
    } else {
        files::assert_regular_file(&marker)?;
    }
    for name in ["bin", "runtime"] {
        let path = install_root.join(name);
        if files::path_exists(&path)? {
            files::remove_validated_directory(&path)?;
        }
    }
    if let Some(pending) = files::pending_launcher(&state)? {
        fs::remove_file(pending.path)?;
    }
    for name in ["active", "pending", "install.manifest", "package-manager"] {
        remove_file_if_exists(&state.join(name))?;
    }
    if files::path_exists(&state.join("leases"))? {
        files::remove_validated_directory(&state.join("leases"))?;
    }
    drop(_coordination);
    validate_uninstall_residual(install_root)?;
    remove_uninstall_residual(install_root, fault, marker_prefix, quiet)?;
    Ok((preserved, warning))
}

fn remove_current_root_for_convergence(install_root: &Path) -> io::Result<()> {
    if !files::path_exists(install_root)? {
        return Ok(());
    }
    files::assert_regular_dir(install_root)?;
    let _ = files::safe_tree_entries(install_root)?;
    let state = install_root.join("state");
    let state_exists = files::path_exists(&state)?;
    let coordination = if state_exists {
        files::assert_regular_dir(&state)?;
        let _ = files::pending_launcher(&state)?;
        Some(acquire_file_lock(
            &state.join("launcher.lock"),
            LOCK_TIMEOUT,
        )?)
    } else {
        None
    };
    if files::path_exists(&state.join("leases"))? {
        let leases = lease_status(&state.join("leases"))?;
        if !leases.active.is_empty() || !leases.ambiguous.is_empty() {
            return Err(files::invalid_data("Herdr is still active"));
        }
    }
    if process_paths()?
        .iter()
        .any(|(_, path)| files::path_within(path, install_root).unwrap_or(false))
    {
        return Err(files::invalid_data(
            "a process from the managed root is active",
        ));
    }
    for entry in fs::read_dir(install_root)? {
        let entry = entry?;
        if entry.file_name() != OsStr::new("state") {
            remove_convergence_entry(&entry.path())?;
        }
    }
    if state_exists {
        for entry in fs::read_dir(&state)? {
            let entry = entry?;
            if entry.file_name() != OsStr::new("launcher.lock") {
                remove_convergence_entry(&entry.path())?;
            }
        }
    }
    drop(coordination);
    if files::path_exists(&state)? {
        remove_file_if_exists(&state.join("launcher.lock"))?;
        files::remove_validated_directory(&state)?;
    }
    if files::path_exists(install_root)? {
        files::remove_validated_directory(install_root)?;
    }
    Ok(())
}

fn remove_convergence_entry(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if files::is_reparse(&metadata) {
        return Err(files::invalid_data(format!(
            "refusing a reparse point during current-root convergence: {}",
            path.display()
        )));
    }
    if metadata.is_dir() {
        files::remove_validated_directory(path)
    } else if metadata.is_file() {
        files::assert_regular_file(path)?;
        fs::remove_file(path)
    } else {
        Err(files::invalid_data(format!(
            "unrecognized current-root entry during convergence: {}",
            path.display()
        )))
    }
}

fn validate_managed_root(install_root: &Path, allow_missing_helper: bool) -> io::Result<()> {
    files::assert_regular_dir(install_root)?;
    assert_exact_root_names(install_root)?;
    let state = install_root.join("state");
    files::assert_regular_dir(&state)?;
    let allowed = [
        "active",
        "pending",
        "leases",
        "launcher.lock",
        files::NATIVE_HELPER_NAME,
        "install.manifest",
        "package-manager",
    ];
    for entry in fs::read_dir(&state)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_text = name.to_string_lossy();
        let pending = name_text.starts_with("launcher.pending-") && name_text.ends_with(".exe");
        if (!allowed.iter().any(|allowed| name == OsStr::new(allowed)) && !pending)
            || entry.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            return Err(files::invalid_data(format!(
                "unrecognized managed state entry: {}",
                entry.path().display()
            )));
        }
    }
    if files::path_exists(&state.join("uninstall.pending"))? {
        return Err(files::invalid_data("managed uninstall is incomplete"));
    }
    for path in [
        state.join("active"),
        state.join("launcher.lock"),
        state.join("install.manifest"),
    ] {
        files::assert_regular_file(&path)?;
    }
    files::assert_regular_dir(&state.join("leases"))?;
    let native = files::path_exists(&state.join(files::NATIVE_HELPER_NAME))?;
    if !(native || allow_missing_helper) {
        return Err(files::invalid_data(
            "managed root lacks native installer helper",
        ));
    }
    if native {
        files::assert_regular_file(&state.join(files::NATIVE_HELPER_NAME))?;
    }
    validate_leases_dir(&state.join("leases"))?;
    validate_package_manager_marker(&state.join("package-manager"))?;
    let manifest = files::read_install_manifest(&state.join("install.manifest"))?;
    validate_managed_bin(&install_root.join("bin"), &manifest.bootstrap_sha256)?;
    let _ = files::pending_launcher(&state)?;
    let runtime_root = install_root.join("runtime");
    files::assert_regular_dir(&runtime_root)?;
    for entry in fs::read_dir(&runtime_root)? {
        let entry = entry?;
        let name = entry.file_name();
        let build = BuildId::parse(
            name.to_str()
                .ok_or_else(|| files::invalid_data("runtime name is not UTF-8"))?,
        )?;
        files::validate_runtime_directory(&entry.path(), &build)?;
    }
    let install = ManagedInstall::new(install_root.to_path_buf());
    let active = install.read_required_active_pointer()?;
    files::validate_runtime_directory(&install.build_dir(&active), &active)?;
    if let Some(pending) = install.read_pointer("pending")? {
        files::validate_runtime_directory(&install.build_dir(&pending), &pending)?;
    }
    Ok(())
}

fn assert_exact_root_names(install_root: &Path) -> io::Result<()> {
    let allowed = ["bin", "runtime", "state", "uninstall.exe"];
    for entry in fs::read_dir(install_root)? {
        let entry = entry?;
        if !allowed
            .iter()
            .any(|allowed| entry.file_name() == OsStr::new(allowed))
            || entry.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            return Err(files::invalid_data(format!(
                "unrecognized managed root entry: {}",
                entry.path().display()
            )));
        }
    }
    for directory in ["bin", "runtime", "state"] {
        files::assert_regular_dir(&install_root.join(directory))?;
    }
    if files::path_exists(&install_root.join("uninstall.exe"))? {
        files::assert_regular_file(&install_root.join("uninstall.exe"))?;
    }
    Ok(())
}

fn validate_managed_bin(bin: &Path, expected_hash: &str) -> io::Result<()> {
    files::assert_regular_dir(bin)?;
    let names = files::sorted_names(bin)?;
    if names
        != [
            OsString::from("herdr.exe"),
            OsString::from("managed-install-v1"),
        ]
    {
        return Err(files::invalid_data("managed bin has unrecognized layout"));
    }
    let launcher = bin.join("herdr.exe");
    files::assert_regular_file(&launcher)?;
    if files::sha256(&launcher)? != expected_hash {
        return Err(files::invalid_data(
            "managed launcher hash differs from install manifest",
        ));
    }
    let sentinel = bin.join("managed-install-v1");
    files::assert_regular_dir(&sentinel)?;
    if files::sorted_names(&sentinel)? != [OsString::from("marker")]
        || fs::read(sentinel.join("marker"))? != files::MANAGED_BIN_MARKER
    {
        return Err(files::invalid_data("managed bin marker is invalid"));
    }
    Ok(())
}

fn validate_uninstall_retry_root(install_root: &Path) -> io::Result<()> {
    files::assert_regular_dir(install_root)?;
    for entry in fs::read_dir(install_root)? {
        let entry = entry?;
        let name = entry.file_name();
        match name.to_str() {
            Some("bin") | Some("runtime") | Some("state") => {
                files::assert_regular_dir(&entry.path())?
            }
            Some("uninstall.exe") => files::assert_regular_file(&entry.path())?,
            _ => {
                return Err(files::invalid_data(
                    "uninstall retry root contains unexpected content",
                ))
            }
        }
    }
    let state = install_root.join("state");
    files::assert_regular_dir(&state)?;
    let allowed_files = [
        "active",
        "pending",
        "launcher.lock",
        files::NATIVE_HELPER_NAME,
        "install.manifest",
        "package-manager",
        "uninstall.pending",
    ];
    for entry in fs::read_dir(&state)? {
        let entry = entry?;
        let name = entry.file_name();
        if name == OsStr::new("leases") {
            files::assert_regular_dir(&entry.path())?;
            continue;
        }
        let name_text = name.to_string_lossy();
        let pending_launcher =
            name_text.starts_with("launcher.pending-") && name_text.ends_with(".exe");
        if !allowed_files
            .iter()
            .any(|allowed| name == OsStr::new(allowed))
            && !pending_launcher
        {
            return Err(files::invalid_data(
                "uninstall retry state contains unexpected content",
            ));
        }
        files::assert_regular_file(&entry.path())?;
    }
    for required in [
        files::NATIVE_HELPER_NAME,
        "launcher.lock",
        "uninstall.pending",
    ] {
        files::assert_regular_file(&state.join(required))?;
    }
    if files::path_exists(&state.join("leases"))? {
        validate_leases_dir(&state.join("leases"))?;
    }
    validate_package_manager_marker(&state.join("package-manager"))?;
    if files::path_exists(&state.join("install.manifest"))? {
        let _ = files::read_install_manifest(&state.join("install.manifest"))?;
    }
    let install = ManagedInstall::new(install_root.to_path_buf());
    for pointer in ["active", "pending"] {
        if files::path_exists(&state.join(pointer))? {
            let _ = install.read_pointer(pointer)?;
        }
    }
    let _ = files::pending_launcher(&state)?;
    if files::path_exists(&install_root.join("bin"))? {
        let manifest = files::read_install_manifest(&state.join("install.manifest"))?;
        validate_managed_bin(&install_root.join("bin"), &manifest.bootstrap_sha256)?;
    }
    let runtime = install_root.join("runtime");
    if files::path_exists(&runtime)? {
        files::assert_regular_dir(&runtime)?;
        for entry in fs::read_dir(runtime)? {
            let entry = entry?;
            let name = entry.file_name();
            let build = BuildId::parse(
                name.to_str()
                    .ok_or_else(|| files::invalid_data("runtime name is not UTF-8"))?,
            )?;
            files::validate_runtime_directory(&entry.path(), &build)?;
        }
    }
    Ok(())
}

fn validate_uninstall_residual(install_root: &Path) -> io::Result<()> {
    files::assert_regular_dir(install_root)?;
    for entry in fs::read_dir(install_root)? {
        let entry = entry?;
        if !["state", "uninstall.exe"]
            .iter()
            .any(|allowed| entry.file_name() == OsStr::new(allowed))
        {
            return Err(files::invalid_data(
                "uninstall residual contains unexpected root state",
            ));
        }
    }
    let state = install_root.join("state");
    files::assert_regular_dir(&state)?;
    let allowed = [
        files::NATIVE_HELPER_NAME,
        "launcher.lock",
        "uninstall.pending",
    ];
    for entry in fs::read_dir(&state)? {
        let entry = entry?;
        if !allowed
            .iter()
            .any(|allowed| entry.file_name() == OsStr::new(allowed))
        {
            return Err(files::invalid_data(
                "uninstall residual contains unexpected state",
            ));
        }
        files::assert_regular_file(&entry.path())?;
    }
    for required in [
        files::NATIVE_HELPER_NAME,
        "launcher.lock",
        "uninstall.pending",
    ] {
        files::assert_regular_file(&state.join(required))?;
    }
    Ok(())
}

fn validate_uninstall_cleanup_root(install_root: &Path) -> io::Result<()> {
    if !files::path_exists(install_root)? {
        return Ok(());
    }
    files::assert_regular_dir(install_root)?;
    for entry in fs::read_dir(install_root)? {
        let entry = entry?;
        match entry.file_name().to_str() {
            Some("state") => files::assert_regular_dir(&entry.path())?,
            Some("uninstall.exe") => files::assert_regular_file(&entry.path())?,
            _ => {
                return Err(files::invalid_data(
                    "uninstall cleanup root contains unexpected content",
                ))
            }
        }
    }
    let state = install_root.join("state");
    if !files::path_exists(&state)? {
        return Ok(());
    }
    files::assert_regular_dir(&state)?;
    let allowed = [
        files::NATIVE_HELPER_NAME,
        "launcher.lock",
        "uninstall.pending",
    ];
    for entry in fs::read_dir(state)? {
        let entry = entry?;
        if !allowed
            .iter()
            .any(|allowed| entry.file_name() == OsStr::new(allowed))
        {
            return Err(files::invalid_data(
                "uninstall cleanup state contains unexpected content",
            ));
        }
        files::assert_regular_file(&entry.path())?;
    }
    Ok(())
}

fn classify_root(install_root: &Path, allow_missing_helper: bool) -> io::Result<RootKind> {
    if !files::path_exists(install_root)? {
        return Ok(RootKind::New);
    }
    if files::path_exists(&install_root.join("state").join("uninstall.pending"))? {
        validate_uninstall_retry_root(install_root)?;
        return Ok(RootKind::UninstallRetry);
    }
    if validate_managed_root(install_root, false).is_ok() {
        return Ok(RootKind::ManagedNative);
    }
    if allow_missing_helper
        && !files::path_exists(&install_root.join("state").join(files::NATIVE_HELPER_NAME))?
        && validate_managed_root(install_root, true).is_ok()
    {
        return Ok(RootKind::ManagedNative);
    }
    if validate_uninstall_cleanup_root(install_root).is_ok() {
        return Ok(RootKind::UninstallResidual);
    }
    Err(incompatible_root(install_root))
}

fn incompatible_root(root: &Path) -> io::Error {
    files::invalid_data(format!(
        "The existing Herdr installation is not compatible with this setup. Uninstall the existing Herdr or Herdr Win entry from Windows Installed Apps, then run setup again. Setup preserved: {}",
        root.display()
    ))
}

fn unsupported_launcher_hop(install_root: &Path) -> io::Result<bool> {
    let runtime = install_root.join("runtime");
    if !files::path_exists(&runtime)? {
        return Ok(false);
    }
    files::assert_regular_dir(&runtime)?;
    for entry in fs::read_dir(runtime)? {
        let entry = entry?;
        if entry.metadata()?.is_dir()
            && files::path_exists(&entry.path().join("herdr-launcher.exe"))?
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn acquire_lifecycle_lock(install_root: &Path, timeout: Duration) -> io::Result<File> {
    let parent = install_root
        .parent()
        .ok_or_else(|| files::invalid_data("install root has no parent"))?;
    if !files::path_exists(parent)? {
        fs::create_dir_all(parent)?;
    }
    files::assert_regular_dir(parent)?;
    let leaf = install_root
        .file_name()
        .ok_or_else(|| files::invalid_data("install root has no leaf"))?
        .to_string_lossy();
    let path = parent.join(format!("{leaf}.installer-lifecycle.lock"));
    let lock = acquire_file_lock(&path, timeout)?;
    if lock.metadata()?.len() != 0 {
        return Err(files::invalid_data(
            "persistent lifecycle lock contains data",
        ));
    }
    Ok(lock)
}

fn acquire_file_lock(path: &Path, timeout: Duration) -> io::Result<File> {
    if let Some(parent) = path.parent() {
        if !files::path_exists(parent)? {
            fs::create_dir_all(parent)?;
        }
        files::assert_regular_dir(parent)?;
    }
    if files::path_exists(path)? {
        files::assert_regular_file(path)?;
    }
    let deadline = Instant::now() + timeout;
    loop {
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(true)
            .share_mode(0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
        match options.open(path) {
            Ok(file) => {
                files::assert_regular_file(path)?;
                return Ok(file);
            }
            Err(_err) if Instant::now() < deadline => thread::sleep(LOCK_RETRY),
            Err(err) => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("timed out acquiring Herdr lock {}: {err}", path.display()),
                ))
            }
        }
    }
}

fn acquire_coordination(
    install: &ManagedInstall,
    timeout: Duration,
) -> io::Result<CoordinationLease> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(lease) = install.try_open_coordination_lease()? {
            return Ok(lease);
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "timed out acquiring coordination lock {}",
                    install.coordination_lock_path().display()
                ),
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn new_staging(kind: &'static str, install_root: &Path) -> io::Result<Staging> {
    let parent = install_root
        .parent()
        .ok_or_else(|| files::invalid_data("install root has no parent"))?;
    if !files::path_exists(parent)? {
        fs::create_dir_all(parent)?;
    }
    files::assert_regular_dir(parent)?;
    let leaf = install_root
        .file_name()
        .ok_or_else(|| files::invalid_data("install root has no leaf"))?
        .to_string_lossy();
    let path = parent.join(format!("{leaf}.installer-{kind}.{}", files::unique_hex()));
    fs::create_dir(&path)?;
    Ok(Staging {
        path,
        kind,
        install_root: install_root.to_path_buf(),
    })
}

fn validate_staging(staging: &Staging) -> io::Result<()> {
    let parent = staging
        .install_root
        .parent()
        .ok_or_else(|| files::invalid_data("install root has no parent"))?;
    if staging.path.parent() != Some(parent) {
        return Err(files::invalid_data(
            "staging directory is not beside install root",
        ));
    }
    let leaf = staging
        .install_root
        .file_name()
        .ok_or_else(|| files::invalid_data("install root has no leaf"))?
        .to_string_lossy();
    let prefix = format!("{leaf}.installer-{}.", staging.kind);
    let name = staging
        .path
        .file_name()
        .ok_or_else(|| files::invalid_data("staging directory has no leaf"))?
        .to_string_lossy();
    let suffix = name
        .strip_prefix(&prefix)
        .ok_or_else(|| files::invalid_data("unrecognized staging name"))?;
    if suffix.len() != 32
        || !suffix
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(files::invalid_data("unrecognized staging identifier"));
    }
    files::assert_regular_dir(&staging.path)?;
    let _ = files::safe_tree_entries(&staging.path)?;
    Ok(())
}

fn cleanup_staging(staging: &Staging) {
    let result =
        validate_staging(staging).and_then(|_| files::remove_validated_directory(&staging.path));
    if let Err(err) = result {
        let _ = writeln!(
            io::stderr().lock(),
            "Warning: Private installer staging was preserved and will not change the requested result: {}. {err}",
            staging.path.display()
        );
    }
}

fn remove_stale_staging(install_root: &Path) {
    let Some(parent) = install_root.parent() else {
        return;
    };
    let Some(leaf) = install_root.file_name().and_then(OsStr::to_str) else {
        return;
    };
    let Ok(entries) = fs::read_dir(parent) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        for kind in ["fresh", "update", "uninstall"] {
            let prefix = format!("{leaf}.installer-{kind}.");
            if name.strip_prefix(&prefix).is_some_and(|suffix| {
                suffix.len() == 32
                    && suffix
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            }) {
                cleanup_staging(&Staging {
                    path: entry.path(),
                    kind,
                    install_root: install_root.to_path_buf(),
                });
            }
        }
    }
}

fn validate_leases_dir(path: &Path) -> io::Result<()> {
    files::assert_regular_dir(path)?;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(value) = name.to_str().and_then(|name| name.strip_suffix(".lease")) else {
            return Err(files::invalid_data("unrecognized lease entry"));
        };
        BuildId::parse(value)?;
        files::assert_regular_file(&entry.path())?;
    }
    Ok(())
}

fn lease_status(path: &Path) -> io::Result<LeaseStatus> {
    validate_leases_dir(path)?;
    let mut output = LeaseStatus {
        active: vec![],
        stale: vec![],
        ambiguous: vec![],
    };
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .share_mode(0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
        match options.open(&path) {
            Ok(_) => output.stale.push(path),
            Err(err) if err.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) => {
                output.ambiguous.push(path)
            }
            Err(_) => output.active.push(path),
        }
    }
    Ok(output)
}

fn remove_stale_leases(status: &LeaseStatus) -> io::Result<()> {
    if !status.active.is_empty() || !status.ambiguous.is_empty() {
        return Err(files::invalid_data(
            "cannot remove active or ambiguous leases",
        ));
    }
    for path in &status.stale {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn process_paths() -> io::Result<Vec<(u32, PathBuf)>> {
    // SAFETY: snapshot has no pointer arguments and returns an owned handle.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let _snapshot = ProcessHandle(snapshot);
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut output = Vec::new();
    // SAFETY: entry is initialized with the required structure size.
    let mut ok = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
    while ok {
        if let Some(path) = process_path(entry.th32ProcessID) {
            output.push((entry.th32ProcessID, path));
        }
        // SAFETY: entry remains valid for the next snapshot record.
        ok = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
    }
    let err = io::Error::last_os_error();
    if err.raw_os_error() != Some(ERROR_NO_MORE_FILES as i32) && err.raw_os_error() != Some(18) {
        return Err(err);
    }
    Ok(output)
}

fn process_path(pid: u32) -> Option<PathBuf> {
    // SAFETY: no inheritance and only query access are requested.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return None;
    }
    let _handle = ProcessHandle(handle);
    let mut buffer = vec![0u16; 32768];
    let mut size = buffer.len() as u32;
    // SAFETY: buffer and size are valid writable arguments.
    if unsafe {
        QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut size)
    } == 0
    {
        return None;
    }
    buffer.truncate(size as usize);
    Some(PathBuf::from(OsString::from_wide(&buffer)))
}

fn validate_package_manager_marker(path: &Path) -> io::Result<bool> {
    if !files::path_exists(path)? {
        return Ok(false);
    }
    files::assert_regular_file(path)?;
    if fs::read(path)? != WINGET_PACKAGE_MANAGER_RECORD {
        return Err(files::invalid_data("package-manager marker is invalid"));
    }
    Ok(true)
}

fn set_package_manager_marker(state: &Path, manager: InstallManager) -> io::Result<()> {
    let path = state.join("package-manager");
    if files::path_exists(&path)? {
        validate_package_manager_marker(&path)?;
    } else if manager == InstallManager::WinGet {
        files::write_durable(&path, files::PACKAGE_MANAGER_MARKER)?;
    }
    Ok(())
}

fn fault_marker(point: &str, prefix: &str) -> io::Result<PathBuf> {
    if prefix.is_empty()
        || prefix.len() > 32
        || !prefix
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(files::invalid_data("invalid uninstall fault marker prefix"));
    }
    Ok(std::env::temp_dir().join(format!("{prefix}-uninstall-fault-{point}.once")))
}

fn inject_fault(point: &str, fault: Option<&str>, prefix: &str) -> io::Result<()> {
    if fault != Some(point) {
        return Ok(());
    }
    let marker = fault_marker(point, prefix)?;
    if files::path_exists(&marker)? {
        files::assert_regular_file(&marker)?;
        return Ok(());
    }
    files::write_durable(&marker, &[])?;
    Err(files::invalid_data(format!(
        "injected uninstall cleanup fault after {point}"
    )))
}

fn remove_fault_marker(fault: Option<&str>, prefix: &str) -> io::Result<()> {
    if let Some(fault) = fault {
        remove_file_if_exists(&fault_marker(fault, prefix)?)?;
    }
    Ok(())
}

fn remove_uninstall_residual(
    install_root: &Path,
    fault: Option<&str>,
    prefix: &str,
    quiet: Option<&QuietSession>,
) -> io::Result<()> {
    if !files::path_exists(install_root)? {
        return Ok(());
    }
    validate_uninstall_cleanup_root(install_root)?;
    let result = (|| {
        let state = install_root.join("state");
        if files::path_exists(&state)? {
            remove_file_if_exists(&state.join("uninstall.pending"))?;
            inject_fault("after-uninstall-pending", fault, prefix)?;
            remove_file_if_exists(&state.join("launcher.lock"))?;
            inject_fault("after-launcher-lock", fault, prefix)?;
            let helper = state.join(files::NATIVE_HELPER_NAME);
            if let Some(quiet) = quiet {
                files::assert_regular_file(&helper)?;
                if files::path_exists(&quiet.moved_helper_path)? {
                    return Err(files::invalid_data(
                        "quiet-uninstall helper handoff path appeared during cleanup",
                    ));
                }
                fs::rename(&helper, &quiet.moved_helper_path)?;
            } else {
                remove_file_if_exists(&helper)?;
            }
            inject_fault("after-installer-helper", fault, prefix)?;
            fs::remove_dir(&state)?;
            inject_fault("after-state-directory", fault, prefix)?;
        }
        remove_terminal_uninstall_files(install_root, fault, prefix)
    })();
    if result.is_err() {
        if let Some(quiet) = quiet {
            restore_quiet_uninstall_retry(install_root, quiet)?;
        }
    }
    result
}

fn restore_quiet_uninstall_retry(install_root: &Path, quiet: &QuietSession) -> io::Result<()> {
    if !files::path_exists(install_root)? || !files::path_exists(&quiet.moved_helper_path)? {
        return Ok(());
    }
    files::assert_regular_dir(install_root)?;
    let state = install_root.join("state");
    if files::path_exists(&state)? {
        files::assert_regular_dir(&state)?;
    } else {
        fs::create_dir(&state)?;
    }
    let helper = state.join(files::NATIVE_HELPER_NAME);
    if files::path_exists(&helper)? {
        return Err(files::invalid_data(
            "quiet-uninstall retry helper destination already exists",
        ));
    }
    fs::rename(&quiet.moved_helper_path, &helper)?;
    if !files::path_exists(&state.join("launcher.lock"))? {
        files::write_durable(&state.join("launcher.lock"), &[])?;
    }
    if !files::path_exists(&state.join("uninstall.pending"))? {
        files::write_durable(&state.join("uninstall.pending"), files::UNINSTALL_MARKER)?;
    }
    validate_uninstall_retry_root(install_root)
}

fn remove_terminal_uninstall_files(
    install_root: &Path,
    fault: Option<&str>,
    prefix: &str,
) -> io::Result<()> {
    validate_uninstall_cleanup_root(install_root)?;
    let mut retry = None;
    let uninstaller = install_root.join("uninstall.exe");
    if files::path_exists(&uninstaller)? {
        files::assert_regular_file(&uninstaller)?;
        retry = Some((
            uninstaller.clone(),
            fs::read(&uninstaller)?,
            files::sha256(&uninstaller)?,
        ));
    }
    let result = (|| {
        inject_fault("before-uninstaller", fault, prefix)?;
        remove_file_if_exists(&uninstaller)?;
        inject_fault("after-uninstaller", fault, prefix)?;
        fs::remove_dir(install_root)?;
        Ok(())
    })();
    if let Err(original) = result {
        if files::path_exists(install_root)? {
            files::assert_regular_dir(install_root)?;
            if let Some((path, bytes, hash)) = retry {
                if files::path_exists(&path)? {
                    files::assert_regular_file(&path)?;
                    if files::sha256(&path)? != hash {
                        return Err(files::invalid_data(format!(
                            "terminal uninstall failed ({original}) and retry state changed: {}",
                            path.display()
                        )));
                    }
                } else {
                    files::write_durable(&path, &bytes)?;
                }
                if files::sha256(&path)? != hash {
                    return Err(files::invalid_data(format!(
                        "restored uninstall retry state differs from original: {}",
                        path.display()
                    )));
                }
            }
        }
        return Err(original);
    }
    Ok(())
}

fn remove_file_if_exists(path: &Path) -> io::Result<()> {
    if files::path_exists(path)? {
        files::assert_regular_file(path)?;
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fault_marker_prefix_is_narrow() {
        assert!(fault_marker("before-uninstaller", "herdr-test").is_ok());
        assert!(fault_marker("before-uninstaller", "../escape").is_err());
    }

    #[test]
    fn quiet_uninstall_token_is_exact_lowercase_hex() {
        assert!(validate_quiet_token("0123456789abcdef0123456789abcdef").is_ok());
        for invalid in [
            "0123456789abcdef",
            "0123456789ABCDEF0123456789ABCDEF",
            "0123456789abcdef0123456789abcdeg",
        ] {
            assert!(validate_quiet_token(invalid).is_err(), "accepted {invalid}");
        }
    }
}
