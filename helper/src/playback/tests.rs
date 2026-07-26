// SPDX-License-Identifier: GPL-3.0-or-later

use super::*;

#[test]
fn converts_cookie_header_to_private_yt_dlp_format() {
    let contents = netscape_cookie_contents("SID=one; __Secure-3PAPISID=two").unwrap();
    assert!(contents.starts_with("# Netscape HTTP Cookie File\n"));
    assert!(contents.contains(".youtube.com\tTRUE\t/\tTRUE\t0\tSID\tone\n"));
    assert!(contents.contains(".youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PAPISID\ttwo\n"));
}

#[test]
fn rejects_cookie_control_characters() {
    let error = netscape_cookie_contents("SID=one\nInjected=value").unwrap_err();
    assert!(error.auth_required);
}

#[cfg(unix)]
#[test]
fn wait_with_output_timeout_kills_stalled_processes() {
    let child = Command::new("sh")
        .args(["-c", "sleep 30"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn stalled shell");
    let started = Instant::now();
    let error = wait_with_output_timeout(child, Duration::from_millis(200)).unwrap_err();
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(error.code, "network");
    assert!(error.retryable);
    assert!(!error.auth_required);
    assert!(error.message.contains("did not finish within"));
}

#[cfg(unix)]
#[test]
fn wait_with_output_timeout_collects_completed_output() {
    let child = Command::new("sh")
        .args([
            "-c",
            "printf 'https://media.example/x\\n'; printf 'diag\\n' >&2",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn echoing shell");
    let output = wait_with_output_timeout(child, Duration::from_secs(10)).expect("child output");
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "https://media.example/x\n"
    );
    assert_eq!(String::from_utf8_lossy(&output.stderr), "diag\n");
}
