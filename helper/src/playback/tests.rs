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
