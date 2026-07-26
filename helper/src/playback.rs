// SPDX-License-Identifier: GPL-3.0-or-later

use crate::auth::AuthConfig;
use crate::error::{HelperError, Result};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Hard ceiling for one yt-dlp stream resolution.
///
/// Stream resolution is the only helper request without an inherent network
/// timeout: reqwest bounds YouTube Music HTTP calls and login has an explicit
/// deadline, but a stalled yt-dlp subprocess would otherwise hang the Emacs
/// playback state machine indefinitely.
const YT_DLP_TIMEOUT_SECS: u64 = 120;

/// Grace period for draining yt-dlp output pipes after its exit status is
/// known. Descendant processes that inherited the pipes are killed when they
/// outlive this grace, and unfinished reader threads are abandoned so the
/// helper never blocks past its deadlines waiting for a pipe to close.
const PIPE_DRAIN_GRACE_MILLIS: u64 = 2000;

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
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let child = spawn_process_group(&mut command)
        .map_err(|error| HelperError::helper_failure(format!("cannot start yt-dlp: {error}")))?;
    let output = wait_with_output_timeout(child, Duration::from_secs(YT_DLP_TIMEOUT_SECS))?;
    if !output.status.success() {
        let diagnostic =
            last_diagnostic(&output.stderr).unwrap_or_else(|| "unknown yt-dlp failure".to_string());
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

fn last_diagnostic(stderr: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(stderr);
    text.lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| line.chars().take(500).collect())
}

/// Spawn COMMAND in its own process group on Unix.
///
/// yt-dlp may start descendant processes (external JS runtimes, helpers)
/// that inherit its stdout/stderr pipes. Killing only the direct child would
/// leave those descendants holding the pipes and keep the reader threads
/// blocked; a dedicated process group lets the timeout kill the whole tree.
fn spawn_process_group(command: &mut Command) -> std::io::Result<Child> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command.spawn()
}

#[cfg(unix)]
fn kill_process_group(child: &Child) {
    // SAFETY: kill(2) only sends a signal. The negative pid addresses the
    // process group created for the child via `process_group(0)`.
    unsafe {
        libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_process_group(_child: &Child) {}

/// Wait for CHILD collecting stdout/stderr, killing it after TIMEOUT.
///
/// A timeout kills the child's entire Unix process group so descendants
/// cannot keep the output pipes open, and it is reported as a retryable
/// network error: stream resolution is read-only, so repeating it cannot
/// apply an account action twice, and a stalled extraction is
/// indistinguishable from a stuck network read.
fn wait_with_output_timeout(mut child: Child, timeout: Duration) -> Result<Output> {
    let stdout_reader = spawn_pipe_reader(child.stdout.take());
    let stderr_reader = spawn_pipe_reader(child.stderr.take());
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if started.elapsed() >= timeout {
                    kill_process_group(&child);
                    let _ = child.kill();
                    let _ = child.wait();
                    let drain = pipe_drain_deadline();
                    let _ = collect_pipe(stdout_reader, drain);
                    let stderr = collect_pipe(stderr_reader, drain);
                    let message = match last_diagnostic(&stderr) {
                        Some(diagnostic) => format!(
                            "yt-dlp did not finish within {} seconds: {diagnostic}",
                            timeout.as_secs()
                        ),
                        None => {
                            format!("yt-dlp did not finish within {} seconds", timeout.as_secs())
                        }
                    };
                    return Err(HelperError::network(message));
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => {
                kill_process_group(&child);
                let _ = child.kill();
                let _ = child.wait();
                let drain = pipe_drain_deadline();
                let _ = collect_pipe(stdout_reader, drain);
                let _ = collect_pipe(stderr_reader, drain);
                return Err(HelperError::helper_failure(format!(
                    "cannot wait for yt-dlp: {error}"
                )));
            }
        }
    };
    // The child exited, but descendants it spawned may still hold the output
    // pipes. Give the readers a short grace, then kill the leftover process
    // group so the collection below cannot block indefinitely.
    let grace = pipe_drain_deadline();
    while Instant::now() < grace
        && !(reader_finished(&stdout_reader) && reader_finished(&stderr_reader))
    {
        thread::sleep(Duration::from_millis(20));
    }
    if !(reader_finished(&stdout_reader) && reader_finished(&stderr_reader)) {
        kill_process_group(&child);
    }
    let drain = pipe_drain_deadline();
    Ok(Output {
        status,
        stdout: collect_pipe(stdout_reader, drain),
        stderr: collect_pipe(stderr_reader, drain),
    })
}

fn pipe_drain_deadline() -> Instant {
    Instant::now() + Duration::from_millis(PIPE_DRAIN_GRACE_MILLIS)
}

fn spawn_pipe_reader<R>(pipe: Option<R>) -> Option<thread::JoinHandle<Vec<u8>>>
where
    R: Read + Send + 'static,
{
    pipe.map(|mut pipe| {
        thread::spawn(move || {
            let mut buffer = Vec::new();
            let _ = pipe.read_to_end(&mut buffer);
            buffer
        })
    })
}

fn reader_finished(reader: &Option<thread::JoinHandle<Vec<u8>>>) -> bool {
    reader.as_ref().is_none_or(|handle| handle.is_finished())
}

/// Join READER, abandoning it when it is still blocked at DEADLINE.
///
/// An abandoned reader thread ends with the short-lived helper process, so
/// a pipe held open by an unkillable descendant cannot block the response.
fn collect_pipe(reader: Option<thread::JoinHandle<Vec<u8>>>, deadline: Instant) -> Vec<u8> {
    let Some(handle) = reader else {
        return Vec::new();
    };
    while !handle.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    if handle.is_finished() {
        handle.join().unwrap_or_default()
    } else {
        Vec::new()
    }
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
