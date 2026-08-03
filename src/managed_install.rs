//! Shared managed-install identity and path contract.

use std::{io, path::PathBuf};

pub(crate) const RUNTIME_RECORD_HEADER: &str = "herdr-runtime-v1";
// Used by the dedicated launcher crate; the product crate only adopts leases.
#[allow(dead_code)]
pub(crate) const POINTER_RECORD_HEADER: &str = "herdr-pointer-v1";
pub(crate) const MANAGED_BIN_MARKER: &[u8] = b"herdr-managed-bin-v1\n";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BuildId(String);

impl BuildId {
    pub(crate) fn parse(value: &str) -> io::Result<Self> {
        let bytes = value.as_bytes();
        if bytes.len() != 25
            || bytes[12] != b'.'
            || !bytes[..12].iter().all(|byte| is_lower_hex(*byte))
            || !bytes[13..].iter().all(|byte| is_lower_hex(*byte))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "invalid managed Herdr build ID {value:?}; expected 12 lowercase hex digits, a dot, and 12 lowercase hex digits"
                ),
            ));
        }
        Ok(Self(value.to_string()))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

pub(crate) fn parse_record(
    bytes: &[u8],
    expected_header: &str,
    source: &std::path::Path,
) -> io::Result<BuildId> {
    let text = std::str::from_utf8(bytes).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "managed install record {} is not strict UTF-8: {err}",
                source.display()
            ),
        )
    })?;
    let prefix = format!("{expected_header}\nbuild_id=");
    let build_id = text
        .strip_prefix(&prefix)
        .and_then(|value| value.strip_suffix('\n'))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "managed install record {} does not match the exact {expected_header} format",
                    source.display()
                ),
            )
        })?;
    BuildId::parse(build_id).map_err(|err| {
        io::Error::new(
            err.kind(),
            format!(
                "managed install record {} has an invalid build ID: {err}",
                source.display()
            ),
        )
    })
}

#[derive(Clone, Debug)]
pub(crate) struct ManagedInstall {
    root: PathBuf,
}

impl ManagedInstall {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub(crate) fn root(&self) -> &std::path::Path {
        &self.root
    }

    pub(crate) fn bin_dir(&self) -> PathBuf {
        self.root.join("bin")
    }

    pub(crate) fn launcher_path(&self) -> PathBuf {
        self.bin_dir().join("herdr.exe")
    }

    pub(crate) fn bin_sentinel_dir(&self) -> PathBuf {
        self.bin_dir().join("managed-install-v1")
    }

    pub(crate) fn bin_marker_path(&self) -> PathBuf {
        self.bin_sentinel_dir().join("marker")
    }

    pub(crate) fn runtime_dir(&self) -> PathBuf {
        self.root.join("runtime")
    }

    pub(crate) fn build_dir(&self, build_id: &BuildId) -> PathBuf {
        self.runtime_dir().join(build_id.as_str())
    }

    pub(crate) fn payload_path(&self, build_id: &BuildId) -> PathBuf {
        self.build_dir(build_id).join("herdr.exe")
    }

    pub(crate) fn runtime_marker_path(&self, build_id: &BuildId) -> PathBuf {
        self.build_dir(build_id).join("runtime.ready")
    }

    pub(crate) fn state_dir(&self) -> PathBuf {
        self.root.join("state")
    }

    // Used by the dedicated launcher crate through the shared contract source.
    #[allow(dead_code)]
    pub(crate) fn pointer_path(&self, name: &str) -> PathBuf {
        self.state_dir().join(name)
    }

    pub(crate) fn leases_dir(&self) -> PathBuf {
        self.state_dir().join("leases")
    }

    pub(crate) fn installer_helper_path(&self) -> PathBuf {
        self.state_dir().join("installer-helper.ps1")
    }

    pub(crate) fn lease_path(&self, build_id: &BuildId) -> PathBuf {
        self.leases_dir()
            .join(format!("{}.lease", build_id.as_str()))
    }

    // Used by the dedicated launcher crate through the shared contract source.
    #[allow(dead_code)]
    pub(crate) fn coordination_lock_path(&self) -> PathBuf {
        self.state_dir().join("launcher.lock")
    }
}

/// Returns the stable command path for managed Windows payloads and the
/// physical executable path for every other installation.
// This source is also compiled into the dedicated launcher binary, where this
// product-side entry point is intentionally unused.
#[allow(dead_code)]
pub(crate) fn command_executable() -> io::Result<PathBuf> {
    let current = std::env::current_exe().map_err(|err| {
        io::Error::new(
            err.kind(),
            format!("failed to determine the physical Herdr executable path: {err}"),
        )
    })?;
    crate::platform::managed_install_command_executable(current)
}

#[cfg(windows)]
// The same contract source is compiled into the launcher binary, which never
// enters the product updater path.
#[allow(dead_code)]
pub(crate) fn current_payload_is_managed() -> io::Result<bool> {
    let current = std::env::current_exe().map_err(|err| {
        io::Error::new(
            err.kind(),
            format!("failed to determine the physical Herdr executable path: {err}"),
        )
    })?;
    Ok(crate::platform::managed_install_command_executable(current.clone())? != current)
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    const BUILD_ID: &str = "0123456789ab.cdef01234567";

    #[test]
    fn build_ids_are_exact_lowercase_hash_pairs() {
        assert_eq!(BuildId::parse(BUILD_ID).unwrap().as_str(), BUILD_ID);
        for invalid in [
            "0123456789AB.cdef01234567",
            "0123456789ab-Cdef01234567",
            "0123456789ab.cdef0123456",
            "0123456789ab.cdef012345678",
            "0123456789ab/cdef01234567",
            "0123456789ab.cdef0123456g",
        ] {
            assert!(BuildId::parse(invalid).is_err(), "accepted {invalid:?}");
        }
    }

    #[test]
    fn records_require_exact_utf8_header_id_and_final_newline() {
        let source = std::path::Path::new("pointer");
        let exact = format!("{POINTER_RECORD_HEADER}\nbuild_id={BUILD_ID}\n");
        assert_eq!(
            parse_record(exact.as_bytes(), POINTER_RECORD_HEADER, source)
                .unwrap()
                .as_str(),
            BUILD_ID
        );

        for invalid in [
            exact.trim_end().to_string(),
            exact.replace('\n', "\r\n"),
            format!("{exact}extra\n"),
            exact.replace(POINTER_RECORD_HEADER, RUNTIME_RECORD_HEADER),
        ] {
            assert!(
                parse_record(invalid.as_bytes(), POINTER_RECORD_HEADER, source).is_err(),
                "accepted {invalid:?}"
            );
        }
        assert!(parse_record(&[0xff], POINTER_RECORD_HEADER, source).is_err());
    }
}
