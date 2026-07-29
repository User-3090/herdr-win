//! Compile-time distribution configuration for herdr-win.

pub(crate) const UPDATE_CHANNEL: &str = "preview";
pub(crate) const PREVIEW_MANIFEST_URL: &str =
    "https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json";
// herdr-win has no stable channel. Keep dormant stable code fork-owned so an
// accidental channel regression fails to parse instead of contacting upstream.
pub(crate) const STABLE_MANIFEST_URL: &str = PREVIEW_MANIFEST_URL;

#[cfg(windows)]
pub(crate) const WINDOWS_RELEASE_DOWNLOAD_PREFIX: &str =
    "https://github.com/User-3090/herdr-win/releases/download/";

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
    fn windows_release_assets_are_fork_owned() {
        assert_eq!(
            WINDOWS_RELEASE_DOWNLOAD_PREFIX,
            "https://github.com/User-3090/herdr-win/releases/download/"
        );
        assert!(!WINDOWS_RELEASE_DOWNLOAD_PREFIX.contains("herdr.dev"));
    }
}
