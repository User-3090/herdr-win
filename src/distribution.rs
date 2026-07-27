//! Compile-time distribution configuration for herdr-win.

pub(crate) const UPDATE_CHANNEL: &str = "preview";
pub(crate) const PREVIEW_MANIFEST_URL: &str =
    "https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json";
// herdr-win has no stable channel. Keep dormant stable code fork-owned so an
// accidental channel regression fails to parse instead of contacting upstream.
pub(crate) const STABLE_MANIFEST_URL: &str = PREVIEW_MANIFEST_URL;

// Keep the installer pinned to a reviewed control commit. The installer reads
// PREVIEW_MANIFEST_URL to select the current immutable Windows package.
#[cfg(windows)]
pub(crate) const WINDOWS_INSTALLER_URL: &str = "https://raw.githubusercontent.com/User-3090/herdr-win/d87208e06674802576d98bdeebf093479bfcffa7/website/install.ps1";

#[cfg(test)]
mod tests {
    use super::*;

    const FORK_RAW_PREFIX: &str = "https://raw.githubusercontent.com/User-3090/herdr-win/";

    #[test]
    fn preview_distribution_is_fork_owned() {
        assert_eq!(UPDATE_CHANNEL, "preview");
        assert_eq!(STABLE_MANIFEST_URL, PREVIEW_MANIFEST_URL);
        assert_eq!(
            PREVIEW_MANIFEST_URL,
            format!("{FORK_RAW_PREFIX}master/website/preview.json")
        );
        assert!(!PREVIEW_MANIFEST_URL.contains("herdr.dev"));
    }

    #[cfg(windows)]
    #[test]
    fn windows_installer_is_pinned_to_a_fork_commit() {
        let Some(path) = WINDOWS_INSTALLER_URL.strip_prefix(FORK_RAW_PREFIX) else {
            panic!("Windows installer URL is not fork-owned");
        };
        let Some((revision, file)) = path.split_once('/') else {
            panic!("Windows installer URL has no revision");
        };
        assert_eq!(revision.len(), 40);
        assert!(revision.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_eq!(file, "website/install.ps1");
        assert!(!WINDOWS_INSTALLER_URL.contains("herdr.dev"));
    }
}
