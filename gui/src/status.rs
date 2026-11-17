//! Everything that is not rendering: reading the installed state, and the two
//! ways out of the process — an unprivileged `zapret-arch` call, and the
//! privileged helper through `sudo -n` (see gui/install-gui.sh).

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

pub const STATE_DIR: &str = "/usr/local/lib/zapret-arch/state";
pub const PROFILES_DIR: &str = "/usr/local/lib/zapret-arch/profiles";
pub const CLI: &str = "/usr/local/lib/zapret-arch/app/zapret-arch";
pub const HELPER: &str = "/usr/local/bin/zapret-arch-helper";
const NFQWS_PATTERN: &str = "/usr/local/lib/zapret-arch/engine/nfq/[n]fqws";

#[derive(Default)]
pub struct Status {
    pub strategy: Option<String>,
    pub games: bool,
    pub voice: bool,
    pub minecraft: bool,
    /// "active" | "inactive" | "failed" | "unknown"
    pub service: String,
    pub pid: Option<u32>,
}

fn read_trim(name: &str) -> Option<String> {
    let p = PathBuf::from(STATE_DIR).join(name);
    let s = fs::read_to_string(p).ok()?;
    let s = s.trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn flag(name: &str, default_on: bool) -> bool {
    match read_trim(name).as_deref() {
        Some("on") => true,
        Some("off") => false,
        _ => default_on,
    }
}

fn first_pid(pattern: &str) -> Option<u32> {
    let out = Command::new("pgrep").arg("-f").arg(pattern).output().ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .and_then(|l| l.trim().parse().ok())
}

pub fn read_status() -> Status {
    let service = Command::new("systemctl")
        .args(["is-active", "zapret-arch.service"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    Status {
        strategy: read_trim("strategy"),
        // Absent files carry the tool's own defaults: games off, voice on, mc off.
        games: flag("games", false),
        voice: flag("voice", true),
        minecraft: flag("minecraft", false),
        service: if service.is_empty() { "unknown".into() } else { service },
        pid: first_pid(NFQWS_PATTERN),
    }
}

/// Alphabetical with numeric runs compared as numbers, so `general-alt2`
/// sorts before `general-alt10` — the TUI uses `sort -V` for the same reason.
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    fn take_num(s: &mut &[u8]) -> u64 {
        let mut n = 0u64;
        let mut i = 0;
        while i < s.len() && s[i].is_ascii_digit() {
            n = n.saturating_mul(10).saturating_add((s[i] - b'0') as u64);
            i += 1;
        }
        *s = &s[i..];
        n
    }
    let (mut a, mut b) = (a.as_bytes(), b.as_bytes());
    while !a.is_empty() && !b.is_empty() {
        if a[0].is_ascii_digit() && b[0].is_ascii_digit() {
            match take_num(&mut a).cmp(&take_num(&mut b)) {
                std::cmp::Ordering::Equal => continue,
                other => return other,
            }
        }
        match a[0].cmp(&b[0]) {
            std::cmp::Ordering::Equal => {
                a = &a[1..];
                b = &b[1..];
            }
            other => return other,
        }
    }
    a.len().cmp(&b.len())
}

/// Sorted strategy slugs: every `*.opt` in the profiles dir.
pub fn strategies() -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(PROFILES_DIR)
        .map(|d| {
            d.filter_map(|e| e.ok())
                .filter_map(|e| {
                    let n = e.file_name().to_string_lossy().to_string();
                    n.strip_suffix(".opt").map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| natural_cmp(a, b));
    v
}

/// `state/test-results`: one `name score` per line, score is `7/9` or `FAIL`.
pub fn test_results() -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    let Ok(text) = fs::read_to_string(PathBuf::from(STATE_DIR).join("test-results")) else {
        return m;
    };
    for line in text.lines() {
        if let Some((name, score)) = line.split_once(' ') {
            m.insert(name.to_string(), score.trim().to_string());
        }
    }
    m
}

fn run(cmd: &mut Command) -> Result<String, String> {
    let out = cmd.output().map_err(|e| format!("не запускается: {e}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if out.status.success() {
        Ok(text)
    } else {
        Err(if text.trim().is_empty() {
            format!("выход {}", out.status.code().unwrap_or(-1))
        } else {
            text.trim().to_string()
        })
    }
}

/// Unprivileged CLI call: `probe`, `status`.
pub fn cli(args: &[&str]) -> Result<String, String> {
    run(Command::new(CLI).args(args))
}

/// `Some(true)` queue 201 present, `Some(false)` table readable and empty of it,
/// `None` no permission to read netfilter — the GUI must say "неизвестно".
pub fn queue_state() -> Option<bool> {
    let out = Command::new("nft")
        .args(["list", "table", "inet", "zapret_arch"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    Some(text.lines().any(|l| l.contains("queue num 201") || l.contains("queue num 201 ")))
}

/// Privileged call through the sudo drop-in installed by install-gui.sh. `-n`
/// keeps it from blocking on a password prompt it can never show.
pub fn helper(args: &[&str]) -> Result<String, String> {
    run(Command::new("sudo").arg("-n").arg(HELPER).args(args))
}
