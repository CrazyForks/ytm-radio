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
fn spawn_test_shell(script: &str) -> Child {
    let mut command = Command::new("sh");
    command
        .args(["-c", script])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    spawn_process_group(&mut command).expect("spawn test shell")
}

#[cfg(unix)]
fn wait_for_process_group_death(pgid: u32) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        // SAFETY: signal 0 only checks whether the process group exists.
        let alive = unsafe { libc::kill(-(pgid as libc::pid_t), 0) } == 0;
        if !alive {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

#[cfg(unix)]
#[test]
fn wait_with_output_timeout_kills_stalled_processes() {
    let child = spawn_test_shell("sleep 30");
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
fn wait_with_output_timeout_kills_descendants_holding_pipes() {
    let child = spawn_test_shell("sleep 30 & exec sleep 30");
    let pgid = child.id();
    let started = Instant::now();
    let error = wait_with_output_timeout(child, Duration::from_millis(200)).unwrap_err();
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(error.code, "network");
    assert!(
        wait_for_process_group_death(pgid),
        "descendant processes survived the timeout group kill"
    );
}

#[cfg(unix)]
#[test]
fn wait_with_output_timeout_reaps_descendants_after_clean_exit() {
    let child = spawn_test_shell("sleep 30 & printf 'https://media.example/x\\n'");
    let pgid = child.id();
    let started = Instant::now();
    let output = wait_with_output_timeout(child, Duration::from_secs(30)).expect("child output");
    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "https://media.example/x\n"
    );
    assert!(
        wait_for_process_group_death(pgid),
        "descendant processes survived the pipe-drain group kill"
    );
}

#[cfg(unix)]
#[test]
fn wait_with_output_timeout_collects_completed_output() {
    let child = spawn_test_shell("printf 'https://media.example/x\\n'; printf 'diag\\n' >&2");
    let output = wait_with_output_timeout(child, Duration::from_secs(10)).expect("child output");
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "https://media.example/x\n"
    );
    assert_eq!(String::from_utf8_lossy(&output.stderr), "diag\n");
}
