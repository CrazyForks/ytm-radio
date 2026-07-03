// SPDX-License-Identifier: GPL-3.0-or-later

use crate::auth::AuthConfig;
use crate::error::{HelperError, Result};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn resolve_stream(
    video_id: &str,
    auth: &AuthConfig,
    yt_dlp_program: &str,
    format: &str,
    proxy: Option<&str>,
) -> Result<String> {
    let cookie_file = TemporaryCookieFile::create(auth)?;
    let mut command = Command::new(yt_dlp_program);
    command
        .arg("--ignore-config")
        .arg("--no-playlist")
        .arg("--cookies")
        .arg(cookie_file.path())
        .arg("-f")
        .arg(format);
    if let Some(proxy) = proxy {
        command.arg("--proxy").arg(proxy);
    }
    command
        .arg("-g")
        .arg(format!("https://music.youtube.com/watch?v={video_id}"))
        .stdin(Stdio::null());

    let output = command
        .output()
        .map_err(|error| HelperError::helper_failure(format!("cannot start yt-dlp: {error}")))?;
    if !output.status.success() {
        let diagnostic = last_diagnostic(&output.stderr);
        return Err(HelperError::remote_response(format!(
            "yt-dlp could not resolve the authenticated stream: {diagnostic}"
        )));
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with("https://") || line.starts_with("http://"))
        .map(str::to_string)
        .ok_or_else(|| HelperError::helper_failure("yt-dlp returned no playable stream URL"))
}

fn last_diagnostic(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    text.lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| line.chars().take(500).collect())
        .unwrap_or_else(|| "unknown yt-dlp failure".to_string())
}

struct TemporaryCookieFile {
    path: PathBuf,
}

impl TemporaryCookieFile {
    fn create(auth: &AuthConfig) -> Result<Self> {
        let cookie_header = auth
            .header("cookie")
            .ok_or_else(|| HelperError::auth_required("auth file is missing the cookie header"))?;
        let contents = netscape_cookie_contents(cookie_header)?;
        for attempt in 0..32 {
            let path = temporary_cookie_path(attempt);
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            match options.open(&path) {
                Ok(mut file) => {
                    let cookie_file = Self { path };
                    file.write_all(contents.as_bytes()).map_err(|error| {
                        HelperError::helper_failure(format!(
                            "cannot write temporary yt-dlp cookie file: {error}"
                        ))
                    })?;
                    return Ok(cookie_file);
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(HelperError::helper_failure(format!(
                        "cannot create temporary yt-dlp cookie file: {error}"
                    )));
                }
            }
        }
        Err(HelperError::helper_failure(
            "cannot allocate temporary yt-dlp cookie file",
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryCookieFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn temporary_cookie_path(attempt: u8) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    env::temp_dir().join(format!(
        "ytm-radio-{}-{nonce}-{attempt}.cookies",
        std::process::id()
    ))
}

fn netscape_cookie_contents(cookie_header: &str) -> Result<String> {
    let mut output = String::from("# Netscape HTTP Cookie File\n");
    let mut count = 0;
    for part in cookie_header.split(';') {
        let Some((name, value)) = part.trim().split_once('=') else {
            continue;
        };
        if name.is_empty() {
            continue;
        }
        if [name, value]
            .iter()
            .any(|field| field.contains(['\t', '\r', '\n']))
        {
            return Err(HelperError::auth_required(
                "auth cookie contains an invalid control character",
            ));
        }
        output.push_str(".youtube.com\tTRUE\t/\tTRUE\t0\t");
        output.push_str(name);
        output.push('\t');
        output.push_str(value);
        output.push('\n');
        count += 1;
    }
    if count == 0 {
        return Err(HelperError::auth_required(
            "auth file contains no usable YouTube cookies",
        ));
    }
    Ok(output)
}

#[cfg(test)]
#[path = "playback/tests.rs"]
mod tests;
