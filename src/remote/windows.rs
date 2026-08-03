//! Windows remote-host side of the SSH stdio bridge.

use std::io;
use std::thread;
use std::time::Duration;

use base64::Engine as _;
use interprocess::local_socket::traits::Stream as _;

pub(crate) fn run_remote_client_bridge() -> io::Result<()> {
    ensure_remote_server_running()?;

    let socket_path = crate::server::socket_paths::client_socket_path();
    let stream = crate::ipc::connect_local_stream(&socket_path).map_err(|err| {
        io::Error::new(
            err.kind(),
            format!(
                "failed to connect to remote Herdr client socket {}: {err}",
                socket_path.display()
            ),
        )
    })?;
    let (mut socket_to_stdout, mut stdin_to_socket) = stream.split();
    let mut stdout = io::stdout().lock();

    let _upload = thread::spawn(move || {
        let mut stdin = io::stdin();
        let _ = copy_flush(&mut stdin, &mut stdin_to_socket);
    });

    copy_flush(&mut socket_to_stdout, &mut stdout).map(|_| ())
}

fn ensure_remote_server_running() -> io::Result<()> {
    let socket_path = crate::server::socket_paths::client_socket_path();
    if crate::server::autodetect::is_server_listening() {
        let status = crate::api::read_runtime_status_at(
            &crate::api::socket_path(),
            Duration::from_millis(500),
        )?
        .ok_or_else(|| io::Error::other("remote server status API is unavailable"))?;
        if status.protocol == Some(crate::protocol::PROTOCOL_VERSION) {
            return Ok(());
        }
        return Err(io::Error::other(
            "remote herdr server must restart before this bridge can attach",
        ));
    }

    crate::server::autodetect::spawn_server_daemon()?;
    crate::server::autodetect::wait_for_server_socket(&socket_path, Duration::from_secs(15))
}

pub(super) fn remote_bridge_command(session_name: &str, (cols, rows): (u16, u16)) -> String {
    let mut script = format!(
        "$env:{} = '{cols}x{rows}'; $herdr = (Get-Command -Name 'herdr.exe' -CommandType Application -ErrorAction Stop).Source; & $herdr",
        crate::server::autodetect::STARTUP_TERMINAL_SIZE_ENV_VAR
    );
    if session_name != crate::session::DEFAULT_SESSION_NAME {
        script.push_str(" --session ");
        script.push_str(&powershell_quote(session_name));
    }
    script.push_str(" remote-client-bridge");

    // Windows OpenSSH accounts can use either cmd.exe or PowerShell as their
    // default shell. An encoded explicit PowerShell command avoids relying on
    // either shell's quoting and still leaves stdin/stdout attached to Herdr.
    let encoded = base64::engine::general_purpose::STANDARD.encode(
        script
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>(),
    );
    format!("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {encoded}")
}

fn powershell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn copy_flush<R: io::Read, W: io::Write>(reader: &mut R, writer: &mut W) -> io::Result<u64> {
    let mut buffer = [0_u8; 16 * 1024];
    let mut total = 0;

    loop {
        let bytes_read = match reader.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(bytes_read) => bytes_read,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        writer.write_all(&buffer[..bytes_read])?;
        writer.flush()?;
        total += bytes_read as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_remote_bridge_resolves_path_application_for_default_session() {
        assert_eq!(
            decoded_remote_bridge_script(crate::session::DEFAULT_SESSION_NAME),
            "$env:HERDR_STARTUP_TERMINAL_SIZE = '120x40'; $herdr = (Get-Command -Name 'herdr.exe' -CommandType Application -ErrorAction Stop).Source; & $herdr remote-client-bridge"
        );
    }

    #[test]
    fn windows_remote_bridge_resolves_path_application_for_named_session() {
        assert_eq!(
            decoded_remote_bridge_script("agent's work"),
            "$env:HERDR_STARTUP_TERMINAL_SIZE = '120x40'; $herdr = (Get-Command -Name 'herdr.exe' -CommandType Application -ErrorAction Stop).Source; & $herdr --session 'agent''s work' remote-client-bridge"
        );
    }

    fn decoded_remote_bridge_script(session_name: &str) -> String {
        let command = remote_bridge_command(session_name, (120, 40));
        let encoded = command.split_whitespace().last().unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .unwrap();
        let utf16 = bytes
            .chunks_exact(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect::<Vec<_>>();
        String::from_utf16(&utf16).unwrap()
    }
}
