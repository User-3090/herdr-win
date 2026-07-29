use std::{
    ffi::{OsStr, OsString},
    io::{self, Write},
    os::windows::process::CommandExt as _,
    path::Path,
    process::{Child, Command},
    thread,
    time::{Duration, Instant},
};

use windows_sys::Win32::System::{
    Console::{
        GetConsoleCP, SetConsoleCtrlHandler, CTRL_BREAK_EVENT, CTRL_C_EVENT, PHANDLER_ROUTINE,
    },
    Threading::DETACHED_PROCESS,
};

use crate::{
    managed_install::{BuildId, ManagedInstall},
    windows_managed_install::{
        build_id_from_dir, install_from_runtime_dir, CoordinationLease, Runtime, SharedLease,
        MANAGED_LEASE_HANDLE_ENV,
    },
};

const PENDING_POINTER: &str = "pending";
const COORDINATION_TIMEOUT: Duration = Duration::from_secs(5);
const COORDINATION_RETRY_INTERVAL: Duration = Duration::from_millis(10);
const BUILD_ID_QUERY_ARG: &str = "--herdr-private-launcher-build-id-v1";
const BUILD_ID_QUERY_ENV: &str = "HERDR_INTERNAL_LAUNCHER_BUILD_ID_QUERY_V1";
const DEVELOPMENT_BUILD_ID: &str = "development";

#[derive(Debug)]
enum LauncherRole {
    Bootstrap(ManagedInstall),
    Dispatcher {
        install: ManagedInstall,
        physical_build: BuildId,
    },
}

pub(crate) fn run() -> io::Result<i32> {
    let current = std::env::current_exe().map_err(|err| {
        contextual(
            err,
            "failed to determine the managed Herdr launcher path".to_string(),
        )
    })?;
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if let Some(code) = maybe_run_build_id_query(&current, &args)? {
        return Ok(code);
    }
    match launcher_role(&current)? {
        LauncherRole::Bootstrap(install) => run_bootstrap(&install, &args),
        LauncherRole::Dispatcher {
            install,
            physical_build,
        } => {
            // Role resolution already validates the dispatcher's immutable
            // physical runtime. Selection below deliberately re-reads active
            // state because another dispatcher may have activated a newer one.
            run_dispatcher(&install, &physical_build, &args)
        }
    }
}

fn maybe_run_build_id_query(current: &Path, args: &[OsString]) -> io::Result<Option<i32>> {
    if current.file_name() != Some(OsStr::new("herdr-launcher.exe"))
        || args != [OsString::from(BUILD_ID_QUERY_ARG)]
    {
        return Ok(None);
    }
    let installed_shape = current
        .parent()
        .and_then(Path::parent)
        .is_some_and(|parent| parent.file_name() == Some(OsStr::new("runtime")));
    let authorized_installed_query =
        std::env::var_os(BUILD_ID_QUERY_ENV).as_deref() == Some(OsStr::new("1"));
    if installed_shape && !authorized_installed_query {
        return Ok(None);
    }

    std::env::remove_var(BUILD_ID_QUERY_ENV);
    std::env::remove_var(MANAGED_LEASE_HANDLE_ENV);
    writeln!(io::stdout().lock(), "{}", compiled_build_id_label()?)?;
    Ok(Some(0))
}

fn compiled_build_id_label() -> io::Result<&'static str> {
    match option_env!("HERDR_BUILD_ID") {
        Some(value) if !value.is_empty() && value != DEVELOPMENT_BUILD_ID => {
            BuildId::parse(value)?;
            Ok(value)
        }
        _ => Ok(DEVELOPMENT_BUILD_ID),
    }
}

#[cfg(not(test))]
fn compiled_build_id() -> io::Result<Option<BuildId>> {
    let label = compiled_build_id_label()?;
    if label == DEVELOPMENT_BUILD_ID {
        Ok(None)
    } else {
        BuildId::parse(label).map(Some)
    }
}

fn launcher_role(current: &Path) -> io::Result<LauncherRole> {
    if current.file_name() == Some(OsStr::new("herdr.exe")) {
        let bin_dir = current.parent().ok_or_else(|| {
            invalid_data(format!(
                "managed bootstrap {} has no bin directory",
                current.display()
            ))
        })?;
        if bin_dir.file_name() != Some(OsStr::new("bin")) {
            return Err(invalid_data(format!(
                "managed bootstrap {} is not the direct bin/herdr.exe command",
                current.display()
            )));
        }
        let root = bin_dir.parent().ok_or_else(|| {
            invalid_data(format!(
                "managed bootstrap {} has no install root",
                current.display()
            ))
        })?;
        let install = ManagedInstall::new(root.to_path_buf());
        let expected = install.validate_managed_bin()?;
        if expected != current {
            return Err(invalid_data(format!(
                "managed bootstrap path is {}, expected {}",
                current.display(),
                expected.display()
            )));
        }
        return Ok(LauncherRole::Bootstrap(install));
    }

    if current.file_name() == Some(OsStr::new("herdr-launcher.exe")) {
        let build_dir = current.parent().ok_or_else(|| {
            invalid_data(format!(
                "managed dispatcher {} has no build directory",
                current.display()
            ))
        })?;
        let runtime_dir = build_dir.parent().ok_or_else(|| {
            invalid_data(format!(
                "managed dispatcher {} has no runtime directory",
                current.display()
            ))
        })?;
        if runtime_dir.file_name() != Some(OsStr::new("runtime")) {
            return Err(invalid_data(format!(
                "managed dispatcher {} is not a direct runtime/<build-id>/herdr-launcher.exe child",
                current.display()
            )));
        }
        let build_id = build_id_from_dir(build_dir)?;
        #[cfg(not(test))]
        if let Some(compiled) = compiled_build_id()? {
            if compiled != build_id {
                return Err(invalid_data(format!(
                    "managed dispatcher {} contains compiled build {}, expected physical build {}",
                    current.display(),
                    compiled.as_str(),
                    build_id.as_str()
                )));
            }
        }
        let install = install_from_runtime_dir(runtime_dir)?;
        install.validate_managed_bin()?;
        let runtime = install.validate_runtime(&build_id)?;
        if runtime.dispatcher != current {
            return Err(invalid_data(format!(
                "managed dispatcher resolved to {}, not {}",
                runtime.dispatcher.display(),
                current.display()
            )));
        }
        return Ok(LauncherRole::Dispatcher {
            install,
            physical_build: build_id,
        });
    }

    Err(invalid_data(format!(
        "managed launcher {} is neither bin/herdr.exe bootstrap mode nor runtime/<build-id>/herdr-launcher.exe dispatcher mode",
        current.display()
    )))
}

fn run_bootstrap(install: &ManagedInstall, args: &[OsString]) -> io::Result<i32> {
    let (mut child, _console_handler) = spawn_bootstrap_dispatcher(install, args)?;
    let status = child.wait().map_err(|err| {
        contextual(
            err,
            "failed while waiting for managed Herdr runtime dispatcher".to_string(),
        )
    })?;
    child_exit_code(status)
}

fn spawn_bootstrap_dispatcher(
    install: &ManagedInstall,
    args: &[OsString],
) -> io::Result<(Child, ConsoleCtrlHandler)> {
    let _coordination = CoordinationGate::acquire(install, COORDINATION_TIMEOUT)?;
    install.validate_managed_bin()?;
    let active_id = install.read_required_active_pointer()?;
    let runtime = install.validate_runtime(&active_id)?;
    spawn_transparent(
        &runtime.dispatcher,
        args,
        "managed Herdr runtime dispatcher",
    )
}

enum SpawnedDispatch {
    Payload {
        child: Child,
        lease: SharedLease,
        _console_handler: ConsoleCtrlHandler,
    },
    Redispatch {
        child: Child,
        _console_handler: ConsoleCtrlHandler,
    },
}

fn run_dispatcher(
    install: &ManagedInstall,
    physical_build: &BuildId,
    args: &[OsString],
) -> io::Result<i32> {
    match spawn_dispatch(install, physical_build, args)? {
        SpawnedDispatch::Redispatch {
            mut child,
            _console_handler,
        } => {
            let status = child.wait().map_err(|err| {
                contextual(
                    err,
                    "failed while waiting for selected Herdr runtime dispatcher".to_string(),
                )
            })?;
            child_exit_code(status)
        }
        SpawnedDispatch::Payload {
            mut child,
            lease,
            _console_handler,
        } => {
            let status = child.wait().map_err(|err| {
                contextual(
                    err,
                    "failed while waiting for managed Herdr payload".to_string(),
                )
            })?;
            drop(lease);
            if let Err(err) = activate_pending_after_child(install, COORDINATION_TIMEOUT) {
                let _ = writeln!(
                    io::stderr().lock(),
                    "herdr launcher: child exited, but pending runtime activation failed: {err}"
                );
            }
            child_exit_code(status)
        }
    }
}

fn spawn_dispatch(
    install: &ManagedInstall,
    physical_build: &BuildId,
    args: &[OsString],
) -> io::Result<SpawnedDispatch> {
    let _coordination = CoordinationGate::acquire(install, COORDINATION_TIMEOUT)?;
    let runtime = select_runtime_locked(install)?;
    if runtime.build_id != *physical_build {
        let (child, console_handler) = spawn_transparent(
            &runtime.dispatcher,
            args,
            "selected managed Herdr runtime dispatcher",
        )?;
        return Ok(SpawnedDispatch::Redispatch {
            child,
            _console_handler: console_handler,
        });
    }

    let lease = install.open_shared_lease(&runtime.build_id)?;
    let console_handler = ConsoleCtrlHandler::install()?;
    let mut command = payload_command(&runtime.executable, args);
    command.env_remove(BUILD_ID_QUERY_ENV);
    lease.configure_payload_child(&mut command);
    let child = command.spawn().map_err(|err| {
        contextual(
            err,
            format!(
                "failed to launch managed Herdr payload {}",
                runtime.executable.display()
            ),
        )
    })?;

    // `_coordination` remains live until after CreateProcess succeeds. Rust
    // 1.96.1's Windows Command defaults bInheritHandles to TRUE; the real
    // parent-death test below protects that external contract.
    Ok(SpawnedDispatch::Payload {
        child,
        lease,
        _console_handler: console_handler,
    })
}

fn spawn_transparent(
    executable: &Path,
    args: &[OsString],
    description: &str,
) -> io::Result<(Child, ConsoleCtrlHandler)> {
    let console_handler = ConsoleCtrlHandler::install()?;
    let mut command = payload_command(executable, args);
    command
        .env_remove(MANAGED_LEASE_HANDLE_ENV)
        .env_remove(BUILD_ID_QUERY_ENV);
    let child = command.spawn().map_err(|err| {
        contextual(
            err,
            format!("failed to launch {description} {}", executable.display()),
        )
    })?;
    Ok((child, console_handler))
}

fn payload_command(executable: &Path, args: &[OsString]) -> Command {
    let mut command = Command::new(executable);
    // Deliberately leave environment, cwd, standard handles, console, and
    // Rust's default handle inheritance untouched. The only creation flag
    // adjustment below carries an already-detached state across launcher hops.
    command.args(args);
    // SAFETY: `GetConsoleCP` has no arguments and only queries whether this
    // process is attached to a console.
    let detached = unsafe { GetConsoleCP() } == 0;
    if detached {
        // A console-subsystem child created by a detached launcher would
        // otherwise allocate a fresh console. Preserve the caller's detached
        // state through both bootstrap and dispatcher hops.
        command.creation_flags(DETACHED_PROCESS);
    }
    command
}

fn child_exit_code(status: std::process::ExitStatus) -> io::Result<i32> {
    status.code().ok_or_else(|| {
        io::Error::other("managed Herdr child exited without a Windows process exit code")
    })
}

fn activate_pending_after_child(install: &ManagedInstall, timeout: Duration) -> io::Result<()> {
    let _coordination = CoordinationGate::acquire(install, timeout)?;
    let _ = select_runtime_locked(install)?;
    Ok(())
}

/// Selects one runtime while the caller holds the coordination gate.
///
/// The old-build exclusive sharing probe and active pointer replacement happen
/// before this returns. A launching caller must open the selected inheritable
/// lease and create the child before releasing the gate.
fn select_runtime_locked(install: &ManagedInstall) -> io::Result<Runtime> {
    let active_id = install.read_required_active_pointer()?;
    let active_runtime = install.validate_runtime(&active_id)?;

    let Some(pending_id) = install.read_pointer(PENDING_POINTER)? else {
        return Ok(active_runtime);
    };
    let pending_runtime = install.validate_runtime(&pending_id)?;

    let Some(_exclusive_old_build) = install.try_open_exclusive_lease(&active_id)? else {
        return Ok(active_runtime);
    };
    install.replace_active_with_pending(&pending_id)?;
    Ok(pending_runtime)
}

#[derive(Debug)]
struct CoordinationGate {
    _lease: CoordinationLease,
}

impl CoordinationGate {
    fn acquire(install: &ManagedInstall, timeout: Duration) -> io::Result<Self> {
        let path = install.coordination_lock_path();
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(lease) = install.try_open_coordination_lease()? {
                return Ok(Self { _lease: lease });
            }

            let now = Instant::now();
            if now >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!(
                        "timed out after {} ms acquiring managed Herdr launcher coordination gate {}",
                        timeout.as_millis(),
                        path.display()
                    ),
                ));
            }
            thread::sleep(COORDINATION_RETRY_INTERVAL.min(deadline - now));
        }
    }
}

struct ConsoleCtrlHandler {
    installed: bool,
}

impl ConsoleCtrlHandler {
    fn install() -> io::Result<Self> {
        let handler: PHANDLER_ROUTINE = Some(launcher_console_handler);
        // SAFETY: the handler has the required system ABI and static lifetime.
        if unsafe { SetConsoleCtrlHandler(handler, 1) } != 0 {
            return Ok(Self { installed: true });
        }
        // A detached server chain has no console and therefore no console
        // control event to intercept. Do not make that valid mode unlaunchable.
        // SAFETY: `GetConsoleCP` has no arguments and only queries attachment.
        if unsafe { GetConsoleCP() } == 0 {
            return Ok(Self { installed: false });
        }
        Err(contextual(
            io::Error::last_os_error(),
            "failed to install transparent Herdr launcher console handler".to_string(),
        ))
    }
}

impl Drop for ConsoleCtrlHandler {
    fn drop(&mut self) {
        if !self.installed {
            return;
        }
        let handler: PHANDLER_ROUTINE = Some(launcher_console_handler);
        // SAFETY: removes the same static handler registered by `install`.
        unsafe {
            SetConsoleCtrlHandler(handler, 0);
        }
    }
}

unsafe extern "system" fn launcher_console_handler(control_type: u32) -> i32 {
    i32::from(matches!(control_type, CTRL_C_EVENT | CTRL_BREAK_EVENT))
}

fn contextual(error: io::Error, context: String) -> io::Error {
    io::Error::new(error.kind(), format!("{context}: {error}"))
}

fn invalid_data(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashMap,
        fs,
        io::{BufRead, BufReader, Read},
        net::{TcpListener, TcpStream},
        os::windows::process::CommandExt as _,
        path::PathBuf,
        process::{ExitStatus, Stdio},
        sync::{
            atomic::{AtomicU64, Ordering},
            Mutex,
        },
        time::{SystemTime, UNIX_EPOCH},
    };

    use windows_sys::Win32::{
        Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0},
        System::{
            Console::GetConsoleWindow,
            Threading::{
                OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE,
                PROCESS_TERMINATE,
            },
        },
    };

    use crate::{
        managed_install::{MANAGED_BIN_MARKER, POINTER_RECORD_HEADER, RUNTIME_RECORD_HEADER},
        windows_managed_install::{
            adopt_managed_runtime_lease_platform, managed_install_command_executable_platform,
        },
    };

    use super::*;

    const ACTIVE_POINTER: &str = "active";
    const OLD_BUILD: &str = "111111111111.aaaaaaaaaaaa";
    const NEW_BUILD: &str = "222222222222.bbbbbbbbbbbb";
    const CHILD_ENV: &str = "HERDR_LAUNCHER_INHERITANCE_TEST";
    const CHILD_CWD_ENV: &str = "HERDR_LAUNCHER_CWD_TEST";
    const OWNER_ROOT_ENV: &str = "HERDR_LAUNCHER_OWNER_ROOT";
    const OWNER_ADDR_ENV: &str = "HERDR_LAUNCHER_OWNER_ADDR";
    const DETACHED_ROOT_ENV: &str = "HERDR_LAUNCHER_DETACHED_ROOT";
    const REDISPATCH_ADDR_ENV: &str = "HERDR_LAUNCHER_REDISPATCH_ADDR";
    const ADOPTION_PROBE_ENV: &str = "HERDR_LAUNCHER_ADOPTION_PROBE";
    const LEASE_DESCENDANT_EXE: &str = "lease-descendant.exe";
    const HELPER_TIMEOUT: Duration = Duration::from_secs(10);
    const TEST_POLL_INTERVAL: Duration = Duration::from_millis(10);

    static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(0);
    static PROCESS_ENV_LOCK: Mutex<()> = Mutex::new(());

    struct TestTree {
        root: PathBuf,
    }

    impl TestTree {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time")
                .as_nanos();
            let sequence = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "herdr-launcher-{label}-{}-{nonce}-{sequence}",
                std::process::id()
            ));
            fs::create_dir_all(root.join("bin/managed-install-v1")).expect("create bin sentinel");
            fs::create_dir_all(root.join("runtime")).expect("create runtime");
            fs::create_dir_all(root.join("state")).expect("create state");
            fs::write(root.join("bin/herdr.exe"), b"bootstrap").expect("write bootstrap");
            fs::write(
                root.join("bin/managed-install-v1/marker"),
                MANAGED_BIN_MARKER,
            )
            .expect("write bin marker");
            Self { root }
        }

        fn install(&self) -> ManagedInstall {
            ManagedInstall::new(self.root.clone())
        }

        fn add_runtime(&self, build_id: &str) -> PathBuf {
            let dir = self.root.join("runtime").join(build_id);
            fs::create_dir(&dir).expect("create build runtime");
            fs::write(dir.join("herdr.exe"), b"payload").expect("write payload");
            fs::write(dir.join("herdr-launcher.exe"), b"dispatcher").expect("write dispatcher");
            fs::write(
                dir.join("runtime.ready"),
                format!("{RUNTIME_RECORD_HEADER}\nbuild_id={build_id}\n"),
            )
            .expect("write marker");
            dir
        }

        fn install_test_executable(&self, build_id: &str, name: &str) {
            fs::copy(
                std::env::current_exe().expect("test executable"),
                self.root.join("runtime").join(build_id).join(name),
            )
            .expect("install test executable");
        }

        fn write_pointer(&self, name: &str, build_id: &str) {
            fs::write(
                self.root.join("state").join(name),
                format!("{POINTER_RECORD_HEADER}\nbuild_id={build_id}\n"),
            )
            .expect("write pointer");
        }
    }

    impl Drop for TestTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    struct ProcessHandleGuard {
        handle: HANDLE,
        exited: bool,
    }

    impl ProcessHandleGuard {
        fn open(pid: u32) -> Self {
            // SAFETY: opens a real PID reported by the test child with only
            // synchronization and emergency cleanup rights.
            let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, 0, pid) };
            assert!(
                !handle.is_null(),
                "open helper process {pid}: {}",
                io::Error::last_os_error()
            );
            Self {
                handle,
                exited: false,
            }
        }

        fn wait(&mut self, timeout: Duration) {
            let millis = u32::try_from(timeout.as_millis()).expect("bounded timeout");
            // SAFETY: the guard owns a valid process handle.
            let result = unsafe { WaitForSingleObject(self.handle, millis) };
            assert_eq!(result, WAIT_OBJECT_0, "helper process did not exit in time");
            self.exited = true;
        }
    }

    impl Drop for ProcessHandleGuard {
        fn drop(&mut self) {
            // SAFETY: test-only emergency cleanup for a helper PID. Production
            // launcher code never terminates processes.
            unsafe {
                if !self.exited {
                    TerminateProcess(self.handle, 1);
                    WaitForSingleObject(self.handle, 5_000);
                }
                CloseHandle(self.handle);
            }
        }
    }

    fn harness_test_name(local_name: &str) -> String {
        let module = module_path!()
            .split_once("::")
            .map_or(module_path!(), |(_, module)| module);
        format!("{module}::{local_name}")
    }

    fn helper_command(local_name: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().expect("test executable"));
        command
            .arg("--exact")
            .arg(harness_test_name(local_name))
            .arg("--nocapture");
        command
    }

    fn spawn_active_test_payload(
        install: &ManagedInstall,
        args: &[OsString],
    ) -> (Child, SharedLease, ConsoleCtrlHandler) {
        let physical_build = install
            .read_required_active_pointer()
            .expect("active physical build");
        match spawn_dispatch(install, &physical_build, args).expect("spawn test payload") {
            SpawnedDispatch::Payload {
                child,
                lease,
                _console_handler,
            } => (child, lease, _console_handler),
            SpawnedDispatch::Redispatch { .. } => {
                panic!("active physical dispatcher unexpectedly redispatched")
            }
        }
    }

    fn wait_child_bounded(child: &mut Child, timeout: Duration) -> ExitStatus {
        let deadline = Instant::now() + timeout;
        loop {
            match child.try_wait().expect("inspect helper child") {
                Some(status) => return status,
                None if Instant::now() < deadline => thread::sleep(TEST_POLL_INTERVAL),
                None => {
                    let _ = child.kill();
                    return child.wait().expect("reap timed-out helper child");
                }
            }
        }
    }

    fn kill_child_bounded(child: &mut Child) {
        child.kill().expect("terminate helper parent");
        let status = wait_child_bounded(child, HELPER_TIMEOUT);
        assert!(
            !status.success(),
            "terminated helper unexpectedly succeeded"
        );
    }

    fn accept_helper_streams(
        listener: &TcpListener,
        expected: usize,
    ) -> HashMap<String, (u32, TcpStream)> {
        listener
            .set_nonblocking(true)
            .expect("nonblocking helper listener");
        let deadline = Instant::now() + HELPER_TIMEOUT;
        let mut helpers = HashMap::new();
        while helpers.len() < expected && Instant::now() < deadline {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .expect("bound helper handshake");
                    let mut line = String::new();
                    BufReader::new(stream.try_clone().expect("clone helper stream"))
                        .read_line(&mut line)
                        .expect("read helper handshake");
                    let mut fields = line.split_whitespace();
                    let role = fields.next().expect("helper role").to_string();
                    let pid = fields
                        .next()
                        .expect("helper pid")
                        .parse::<u32>()
                        .expect("numeric helper pid");
                    assert!(fields.next().is_none(), "unexpected helper handshake");
                    helpers.insert(role, (pid, stream));
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(TEST_POLL_INTERVAL);
                }
                Err(err) => panic!("accept helper connection: {err}"),
            }
        }
        assert_eq!(helpers.len(), expected, "helpers did not become ready");
        helpers
    }

    #[test]
    fn bootstrap_and_dispatcher_roles_require_exact_managed_layout() {
        let tree = TestTree::new("roles");
        let runtime_dir = tree.add_runtime(OLD_BUILD);
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);

        assert!(matches!(
            launcher_role(&tree.root.join("bin/herdr.exe")).expect("bootstrap role"),
            LauncherRole::Bootstrap(_)
        ));
        let LauncherRole::Dispatcher { physical_build, .. } =
            launcher_role(&runtime_dir.join("herdr-launcher.exe")).expect("dispatcher role")
        else {
            panic!("expected dispatcher role");
        };
        assert_eq!(physical_build.as_str(), OLD_BUILD);
        assert_eq!(
            managed_install_command_executable_platform(runtime_dir.join("herdr.exe"))
                .expect("stable command"),
            tree.root.join("bin/herdr.exe")
        );

        fs::write(tree.root.join("bin/managed-install-v1/marker"), b"wrong\n")
            .expect("corrupt bin marker");
        assert!(launcher_role(&tree.root.join("bin/herdr.exe")).is_err());
        assert!(
            managed_install_command_executable_platform(runtime_dir.join("herdr.exe")).is_err()
        );
    }

    #[test]
    fn bootstrap_selects_active_versioned_dispatcher() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("bootstrap-chain");
        tree.add_runtime(OLD_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr-launcher.exe");
        tree.install_test_executable(OLD_BUILD, "herdr.exe");
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);
        let args = vec![
            OsString::from("--exact"),
            OsString::from(harness_test_name("bootstrap_dispatcher_helper")),
            OsString::from("--nocapture"),
        ];
        std::env::set_var(CHILD_ENV, "through-bootstrap-and-dispatcher");
        let spawned = spawn_bootstrap_dispatcher(&tree.install(), &args);
        std::env::remove_var(CHILD_ENV);
        let (mut dispatcher, _console_handler) = spawned.expect("spawn active dispatcher");
        let status = wait_child_bounded(&mut dispatcher, HELPER_TIMEOUT);
        assert_eq!(status.code(), Some(37));
    }

    #[test]
    fn stale_dispatcher_redispatches_through_the_selected_physical_runtime() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("stale-dispatcher");
        tree.add_runtime(OLD_BUILD);
        tree.add_runtime(NEW_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr-launcher.exe");
        tree.install_test_executable(NEW_BUILD, "herdr-launcher.exe");
        tree.install_test_executable(NEW_BUILD, "herdr.exe");
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);
        tree.write_pointer(PENDING_POINTER, NEW_BUILD);

        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind redispatch listener");
        let address = listener.local_addr().expect("redispatch listener address");
        let mut command = Command::new(
            tree.root
                .join("runtime")
                .join(OLD_BUILD)
                .join("herdr-launcher.exe"),
        );
        command
            .arg("--exact")
            .arg(harness_test_name("stale_dispatcher_helper"))
            .arg("--nocapture")
            .env(REDISPATCH_ADDR_ENV, address.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut dispatcher = command.spawn().expect("spawn stale dispatcher");

        let mut helpers = accept_helper_streams(&listener, 3);
        assert!(helpers.contains_key(&format!("dispatcher-{OLD_BUILD}")));
        assert!(helpers.contains_key(&format!("dispatcher-{NEW_BUILD}")));
        let (_, mut payload_stream) = helpers.remove("payload").expect("payload handshake");
        payload_stream
            .write_all(b"x")
            .expect("release redispatched payload");
        let status = wait_child_bounded(&mut dispatcher, HELPER_TIMEOUT);
        assert_eq!(status.code(), Some(43));

        let install = tree.install();
        assert_eq!(
            install
                .read_required_active_pointer()
                .expect("activated pointer")
                .as_str(),
            NEW_BUILD
        );
        assert!(install
            .read_pointer(PENDING_POINTER)
            .expect("pending pointer")
            .is_none());
    }

    #[test]
    fn build_id_query_requires_authorization_only_in_an_installed_shape() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let args = [OsString::from(BUILD_ID_QUERY_ARG)];
        let installed = PathBuf::from(format!(r"C:\Herdr\runtime\{OLD_BUILD}\herdr-launcher.exe"));
        std::env::remove_var(BUILD_ID_QUERY_ENV);
        std::env::remove_var(MANAGED_LEASE_HANDLE_ENV);
        assert!(maybe_run_build_id_query(&installed, &args)
            .expect("unauthorized installed query")
            .is_none());

        std::env::set_var(BUILD_ID_QUERY_ENV, "1");
        std::env::set_var(MANAGED_LEASE_HANDLE_ENV, "1234");
        assert_eq!(
            maybe_run_build_id_query(&installed, &args).expect("authorized installed query"),
            Some(0)
        );
        assert!(std::env::var_os(BUILD_ID_QUERY_ENV).is_none());
        assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());

        let staged = PathBuf::from(r"C:\stage\herdr-launcher.exe");
        assert_eq!(
            maybe_run_build_id_query(&staged, &args).expect("staged build query"),
            Some(0)
        );
    }

    #[test]
    fn runtime_validation_rejects_mismatched_marker_missing_dispatcher_and_hard_link() {
        let tree = TestTree::new("runtime-validation");
        let runtime_dir = tree.add_runtime(OLD_BUILD);
        let install = tree.install();
        let build_id = BuildId::parse(OLD_BUILD).expect("build id");
        fs::write(
            install.runtime_marker_path(&build_id),
            format!("{RUNTIME_RECORD_HEADER}\nbuild_id={NEW_BUILD}\n"),
        )
        .expect("replace marker");
        assert!(install.validate_runtime(&build_id).is_err());

        fs::write(
            install.runtime_marker_path(&build_id),
            format!("{RUNTIME_RECORD_HEADER}\nbuild_id={OLD_BUILD}\n"),
        )
        .expect("restore marker");
        fs::remove_file(runtime_dir.join("herdr-launcher.exe")).expect("remove dispatcher");
        assert!(install.validate_runtime(&build_id).is_err());
        fs::write(runtime_dir.join("herdr-launcher.exe"), b"dispatcher")
            .expect("restore dispatcher");

        let payload = runtime_dir.join("herdr.exe");
        fs::hard_link(&payload, tree.root.join("payload-hard-link.exe")).expect("create hard link");
        assert!(install.validate_runtime(&build_id).is_err());
    }

    #[test]
    fn managed_payload_rejects_missing_and_wrong_runtime_leases() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("lease-rejection");
        tree.add_runtime(OLD_BUILD);
        tree.add_runtime(NEW_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr.exe");
        let install = tree.install();
        let old_id = BuildId::parse(OLD_BUILD).expect("old build id");
        let new_id = BuildId::parse(NEW_BUILD).expect("new build id");
        drop(
            install
                .try_open_exclusive_lease(&old_id)
                .expect("prepare old lease")
                .expect("exclusive old lease"),
        );

        let payload = tree.root.join("runtime").join(OLD_BUILD).join("herdr.exe");
        let launch_probe = |mode: &str| {
            let mut command = Command::new(&payload);
            command
                .arg("--exact")
                .arg(harness_test_name("lease_adoption_rejection_helper"))
                .arg("--nocapture")
                .env(ADOPTION_PROBE_ENV, mode)
                .env_remove(MANAGED_LEASE_HANDLE_ENV)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            command
        };

        let mut missing = launch_probe("missing")
            .spawn()
            .expect("spawn missing lease probe");
        assert!(wait_child_bounded(&mut missing, HELPER_TIMEOUT).success());

        let wrong_lease = install
            .open_shared_lease(&new_id)
            .expect("open wrong-build lease");
        let mut wrong_command = launch_probe("wrong");
        wrong_lease.configure_payload_child(&mut wrong_command);
        let mut wrong = wrong_command.spawn().expect("spawn wrong lease probe");
        assert!(wait_child_bounded(&mut wrong, HELPER_TIMEOUT).success());
    }

    #[test]
    fn share_mode_leases_interoperate_and_coordination_is_bounded() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("sharing");
        tree.add_runtime(OLD_BUILD);
        let install = tree.install();
        let old_id = BuildId::parse(OLD_BUILD).expect("old build id");
        let first = install
            .open_shared_lease(&old_id)
            .expect("first shared lease");
        let second = install
            .open_shared_lease(&old_id)
            .expect("second shared lease");
        assert!(install
            .try_open_exclusive_lease(&old_id)
            .expect("exclusive lease probe")
            .is_none());
        drop(first);
        drop(second);
        assert!(install
            .try_open_exclusive_lease(&old_id)
            .expect("exclusive lease probe")
            .is_some());

        let gate = CoordinationGate::acquire(&install, Duration::from_millis(100))
            .expect("first coordination gate");
        let started = Instant::now();
        let error = CoordinationGate::acquire(&install, Duration::from_millis(80))
            .expect_err("second coordination gate should time out");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(gate);
    }

    #[test]
    fn managed_payload_lease_survives_dispatcher_but_not_payload_descendants() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("lease-lifetime");
        tree.add_runtime(OLD_BUILD);
        tree.add_runtime(NEW_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr.exe");
        tree.install_test_executable(OLD_BUILD, LEASE_DESCENDANT_EXE);
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);
        let install = tree.install();
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind helper listener");
        let address = listener.local_addr().expect("helper listener address");

        let mut owner = helper_command("lease_owner_helper");
        owner
            .env(OWNER_ROOT_ENV, &tree.root)
            .env(OWNER_ADDR_ENV, address.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut owner = owner.spawn().expect("spawn lease owner helper");
        let mut helpers = accept_helper_streams(&listener, 3);
        let (_, _owner_stream) = helpers.remove("owner").expect("owner handshake");
        let (payload_pid, mut payload_stream) =
            helpers.remove("payload").expect("payload handshake");
        let (descendant_pid, mut descendant_stream) =
            helpers.remove("descendant").expect("descendant handshake");
        let mut payload_guard = ProcessHandleGuard::open(payload_pid);
        let mut descendant_guard = ProcessHandleGuard::open(descendant_pid);

        kill_child_bounded(&mut owner);
        tree.write_pointer(PENDING_POINTER, NEW_BUILD);
        activate_pending_after_child(&install, Duration::from_secs(1))
            .expect("defer activation while inherited lease is live");
        assert_eq!(
            install
                .read_required_active_pointer()
                .expect("active pointer")
                .as_str(),
            OLD_BUILD
        );
        assert!(install
            .read_pointer(PENDING_POINTER)
            .expect("pending pointer")
            .is_some());

        payload_stream
            .write_all(b"x")
            .expect("release managed payload");
        payload_guard.wait(HELPER_TIMEOUT);
        activate_pending_after_child(&install, Duration::from_secs(1))
            .expect("activate while payload descendant remains alive");
        assert_eq!(
            install
                .read_required_active_pointer()
                .expect("active pointer")
                .as_str(),
            NEW_BUILD
        );
        assert!(install
            .read_pointer(PENDING_POINTER)
            .expect("pending pointer")
            .is_none());

        descendant_stream
            .write_all(b"x")
            .expect("release payload descendant");
        descendant_guard.wait(HELPER_TIMEOUT);
    }

    #[test]
    fn dispatcher_forwards_arguments_environment_cwd_and_exit_code() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("process-contract");
        tree.add_runtime(OLD_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr.exe");
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);
        let args = vec![
            OsString::from("--exact"),
            OsString::from(harness_test_name("payload_process_helper")),
            OsString::from("--nocapture"),
        ];
        std::env::set_var(CHILD_ENV, "inherited");
        std::env::set_var(
            CHILD_CWD_ENV,
            std::env::current_dir().expect("current directory"),
        );
        let launched = spawn_active_test_payload(&tree.install(), &args);
        std::env::remove_var(CHILD_ENV);
        std::env::remove_var(CHILD_CWD_ENV);
        let (mut child, lease, _console_handler) = launched;
        let status = wait_child_bounded(&mut child, HELPER_TIMEOUT);
        drop(lease);
        assert_eq!(status.code(), Some(37));
    }

    #[test]
    fn detached_dispatcher_preserves_headless_payload_behavior() {
        let _env = PROCESS_ENV_LOCK.lock().expect("process env lock");
        let tree = TestTree::new("detached");
        tree.add_runtime(OLD_BUILD);
        tree.install_test_executable(OLD_BUILD, "herdr.exe");
        tree.write_pointer(ACTIVE_POINTER, OLD_BUILD);
        let mut command = helper_command("detached_dispatcher_helper");
        command
            .env(DETACHED_ROOT_ENV, &tree.root)
            .creation_flags(DETACHED_PROCESS)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut helper = command.spawn().expect("spawn detached dispatcher helper");
        let status = wait_child_bounded(&mut helper, HELPER_TIMEOUT);
        assert_eq!(status.code(), Some(41));
    }

    #[test]
    fn bootstrap_dispatcher_helper() {
        let current = std::env::current_exe().expect("helper executable");
        match current.file_name().and_then(OsStr::to_str) {
            Some("herdr-launcher.exe") => {
                let LauncherRole::Dispatcher {
                    install,
                    physical_build,
                } = launcher_role(&current).expect("resolve helper dispatcher")
                else {
                    panic!("expected helper dispatcher role");
                };
                let args = std::env::args_os().skip(1).collect::<Vec<_>>();
                let code = run_dispatcher(&install, &physical_build, &args)
                    .expect("dispatch helper payload");
                std::process::exit(code);
            }
            Some("herdr.exe") => {
                let _lease = adopt_managed_runtime_lease_platform()
                    .expect("adopt bootstrap-chain payload lease");
                assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());
                assert_eq!(
                    std::env::var(CHILD_ENV).as_deref(),
                    Ok("through-bootstrap-and-dispatcher")
                );
                assert_eq!(
                    std::env::args_os().skip(1).collect::<Vec<_>>(),
                    [
                        OsString::from("--exact"),
                        OsString::from(harness_test_name("bootstrap_dispatcher_helper")),
                        OsString::from("--nocapture")
                    ]
                );
                std::process::exit(37);
            }
            _ => {}
        }
    }

    #[test]
    fn stale_dispatcher_helper() {
        let current = std::env::current_exe().expect("redispatch helper executable");
        match current.file_name().and_then(OsStr::to_str) {
            Some("herdr-launcher.exe") => {
                let LauncherRole::Dispatcher {
                    install,
                    physical_build,
                } = launcher_role(&current).expect("resolve redispatch helper")
                else {
                    panic!("expected redispatch helper dispatcher role");
                };
                let address =
                    std::env::var(REDISPATCH_ADDR_ENV).expect("redispatch helper listener address");
                let mut stream = TcpStream::connect(address).expect("connect redispatch helper");
                writeln!(
                    stream,
                    "dispatcher-{} {}",
                    physical_build.as_str(),
                    std::process::id()
                )
                .expect("dispatcher redispatch handshake");
                stream.flush().expect("flush redispatch handshake");
                let args = std::env::args_os().skip(1).collect::<Vec<_>>();
                let code = run_dispatcher(&install, &physical_build, &args)
                    .expect("run selected dispatcher");
                std::process::exit(code);
            }
            Some("herdr.exe") => {
                let _lease = adopt_managed_runtime_lease_platform()
                    .expect("adopt redispatched payload lease");
                assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());
                let address = std::env::var(REDISPATCH_ADDR_ENV)
                    .expect("redispatch payload listener address");
                let mut stream = TcpStream::connect(address).expect("connect redispatch payload");
                writeln!(stream, "payload {}", std::process::id())
                    .expect("redispatch payload handshake");
                stream.flush().expect("flush redispatch payload handshake");
                let mut release = [0_u8; 1];
                stream
                    .read_exact(&mut release)
                    .expect("redispatch payload release");
                std::process::exit(43);
            }
            _ => {}
        }
    }

    #[test]
    fn payload_process_helper() {
        if std::env::current_exe()
            .expect("helper executable")
            .file_name()
            != Some(OsStr::new("herdr.exe"))
        {
            return;
        }
        let _lease = adopt_managed_runtime_lease_platform().expect("adopt process payload lease");
        assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());
        assert_eq!(std::env::var(CHILD_ENV).as_deref(), Ok("inherited"));
        assert_eq!(
            std::env::current_dir().expect("helper current directory"),
            PathBuf::from(std::env::var_os(CHILD_CWD_ENV).expect("inherited cwd"))
        );
        assert_eq!(
            std::env::args_os().skip(1).collect::<Vec<_>>(),
            [
                OsString::from("--exact"),
                OsString::from(harness_test_name("payload_process_helper")),
                OsString::from("--nocapture")
            ]
        );
        std::process::exit(37);
    }

    #[test]
    fn lease_adoption_rejection_helper() {
        if std::env::current_exe()
            .expect("lease rejection executable")
            .file_name()
            != Some(OsStr::new("herdr.exe"))
            || std::env::var_os(ADOPTION_PROBE_ENV).is_none()
        {
            return;
        }
        let error = adopt_managed_runtime_lease_platform()
            .expect_err("managed payload accepted an invalid runtime lease");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn lease_owner_helper() {
        let Some(root) = std::env::var_os(OWNER_ROOT_ENV) else {
            return;
        };
        let address = std::env::var(OWNER_ADDR_ENV).expect("owner helper address");
        let install = ManagedInstall::new(PathBuf::from(root));
        let args = vec![
            OsString::from("--exact"),
            OsString::from(harness_test_name("lease_payload_helper")),
            OsString::from("--nocapture"),
        ];
        let (child, _lease, _console_handler) = spawn_active_test_payload(&install, &args);
        let mut stream = TcpStream::connect(address).expect("connect owner helper");
        writeln!(stream, "owner {}", std::process::id()).expect("owner handshake");
        stream.flush().expect("flush owner handshake");
        let mut release = [0_u8; 1];
        stream.read_exact(&mut release).expect("owner release");
        drop(child);
    }

    #[test]
    fn lease_payload_helper() {
        if std::env::current_exe()
            .expect("lease payload executable")
            .file_name()
            != Some(OsStr::new("herdr.exe"))
        {
            return;
        }
        let _lease = adopt_managed_runtime_lease_platform().expect("adopt managed payload lease");
        assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());

        let address = std::env::var(OWNER_ADDR_ENV).expect("lease payload address");
        let descendant = std::env::current_exe()
            .expect("lease payload executable")
            .parent()
            .expect("lease payload build directory")
            .join(LEASE_DESCENDANT_EXE);
        let mut child = Command::new(descendant);
        child
            .arg("--exact")
            .arg(harness_test_name("lease_descendant_helper"))
            .arg("--nocapture")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let child = child.spawn().expect("spawn payload descendant");

        let mut stream = TcpStream::connect(address).expect("connect lease payload");
        writeln!(stream, "payload {}", std::process::id()).expect("payload handshake");
        stream.flush().expect("flush child handshake");
        let mut release = [0_u8; 1];
        stream.read_exact(&mut release).expect("child release");
        drop(child);
    }

    #[test]
    fn lease_descendant_helper() {
        if std::env::current_exe()
            .expect("lease descendant executable")
            .file_name()
            != Some(OsStr::new(LEASE_DESCENDANT_EXE))
        {
            return;
        }
        assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());
        let address = std::env::var(OWNER_ADDR_ENV).expect("lease descendant address");
        let mut stream = TcpStream::connect(address).expect("connect lease descendant");
        writeln!(stream, "descendant {}", std::process::id()).expect("descendant handshake");
        stream.flush().expect("flush descendant handshake");
        let mut release = [0_u8; 1];
        stream.read_exact(&mut release).expect("descendant release");
    }

    #[test]
    fn detached_dispatcher_helper() {
        let Some(root) = std::env::var_os(DETACHED_ROOT_ENV) else {
            return;
        };
        let install = ManagedInstall::new(PathBuf::from(root));
        let args = vec![
            OsString::from("--exact"),
            OsString::from(harness_test_name("detached_payload_helper")),
            OsString::from("--nocapture"),
        ];
        let (mut child, lease, _console_handler) = spawn_active_test_payload(&install, &args);
        let status = wait_child_bounded(&mut child, Duration::from_secs(5));
        drop(lease);
        std::process::exit(status.code().expect("detached payload exit code"));
    }

    #[test]
    fn detached_payload_helper() {
        if std::env::current_exe()
            .expect("detached payload executable")
            .file_name()
            != Some(OsStr::new("herdr.exe"))
        {
            return;
        }
        let _lease = adopt_managed_runtime_lease_platform().expect("adopt detached payload lease");
        assert!(std::env::var_os(MANAGED_LEASE_HANDLE_ENV).is_none());
        assert!(unsafe { GetConsoleWindow() }.is_null());
        assert_eq!(unsafe { GetConsoleCP() }, 0);
        std::process::exit(41);
    }
}
