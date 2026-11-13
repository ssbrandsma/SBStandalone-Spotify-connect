//! Lightweight librespot supervisor owned by the Spotify Connect applet.
use std::{env, fs::{self, OpenOptions}, io::{BufRead, BufReader, Write}, process::{Child, Command, Stdio}, sync::atomic::{AtomicBool, Ordering}, thread, time::{Duration, Instant}};

static STOP: AtomicBool = AtomicBool::new(false);
const SIGTERM: i32 = 15;
const SIGINT: i32 = 2;
unsafe extern "C" { fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize; fn kill(pid: i32, sig: i32) -> i32; }
extern "C" fn request_stop(_: i32) { STOP.store(true, Ordering::SeqCst); }

fn esc(value: &str) -> String { value.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r") }
fn status_body(state: &str, extra: Option<(&str, &str)>) -> String {
    let mut body = format!(r#"{{"state":"{}""#, esc(state));
    if let Some((key, value)) = extra {
        body.push_str(&format!(r#","{}":"{}""#, esc(key), esc(value)));
    }
    body.push_str("}\n");
    body
}
fn write_status(path: &str, state: &str, extra: Option<(&str, &str)>) {
    let body = status_body(state, extra);
    let tmp = format!("{path}.tmp");
    if let Ok(mut file) = OpenOptions::new().create(true).write(true).truncate(true).open(&tmp) {
        if file.write_all(body.as_bytes()).is_ok() {
            #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)); }
            let _ = fs::rename(tmp, path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::status_body;

    #[test]
    fn status_extra_field_is_valid_json_shape() {
        assert_eq!(
            status_body("pairing", Some(("url", "https://spotify.com/pair?code=A&B"))),
            "{\"state\":\"pairing\",\"url\":\"https://spotify.com/pair?code=A&B\"}\n"
        );
    }
}
fn parse_status(path: &str, line: &str) {
    if let Some(pos) = line.find("Browse to: ") { write_status(path, "pairing", Some(("url", line[pos + 11..].trim()))); }
    else if line.contains("Authenticated as") { write_status(path, "connected", None); }
}
fn relay(child: &mut Child, status: &str) -> Vec<thread::JoinHandle<()>> {
    let mut handles = Vec::new();
    if let Some(out) = child.stdout.take() { let path = status.to_string(); handles.push(thread::spawn(move || for line in BufReader::new(out).lines().map_while(Result::ok) { println!("{line}"); parse_status(&path, &line); })); }
    if let Some(err) = child.stderr.take() { let path = status.to_string(); handles.push(thread::spawn(move || for line in BufReader::new(err).lines().map_while(Result::ok) { eprintln!("{line}"); parse_status(&path, &line); })); }
    handles
}
fn stop_child(child: &mut Child) {
    unsafe { kill(child.id() as i32, SIGTERM); }
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline { if child.try_wait().ok().flatten().is_some() { return; } thread::sleep(Duration::from_millis(100)); }
    let _ = child.kill();
}
fn main() -> std::io::Result<()> {
    let mut it = env::args().skip(1);
    let status = it.next().filter(|x| x == "--status").and_then(|_| it.next()).ok_or_else(|| std::io::Error::other("--status PATH required"))?;
    let child_pid = it.next().filter(|x| x == "--child-pid").and_then(|_| it.next()).ok_or_else(|| std::io::Error::other("--child-pid PATH required"))?;
    if it.next().as_deref() != Some("--") { return Err(std::io::Error::other("-- separates supervisor and librespot arguments")); }
    let args: Vec<String> = it.collect(); if args.is_empty() { return Err(std::io::Error::other("librespot command required")); }
    unsafe { signal(SIGTERM, request_stop); signal(SIGINT, request_stop); }
    let delays = [1u64, 2, 5, 10, 30]; let mut failures = 0usize;
    while !STOP.load(Ordering::SeqCst) {
        write_status(&status, if failures == 0 { "starting" } else { "recovering" }, None);
        let started = Instant::now();
        let mut child = match Command::new(&args[0]).args(&args[1..]).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
            Ok(child) => child,
            Err(error) => { write_status(&status, "error", Some(("message", &format!("librespot start failed: {error}")))); failures = failures.saturating_add(1); thread::sleep(Duration::from_secs(delays[failures.min(delays.len()) - 1])); continue; }
        };
        fs::write(&child_pid, child.id().to_string().as_bytes())?; let handles = relay(&mut child, &status);
        let result = loop { if STOP.load(Ordering::SeqCst) { stop_child(&mut child); break child.wait()?; } if let Some(result) = child.try_wait()? { break result; } thread::sleep(Duration::from_millis(250)); };
        let _ = fs::remove_file(&child_pid); for handle in handles { let _ = handle.join(); }
        if STOP.load(Ordering::SeqCst) { break; }
        if started.elapsed() > Duration::from_secs(60) { failures = 0; }
        failures = failures.saturating_add(1); let delay = delays[failures.min(delays.len()) - 1];
        write_status(&status, "error", Some(("message", &format!("librespot exited: {result}; retry in {delay}s"))));
        let deadline = Instant::now() + Duration::from_secs(delay); while Instant::now() < deadline && !STOP.load(Ordering::SeqCst) { thread::sleep(Duration::from_millis(250)); }
    }
    let _ = fs::remove_file(&child_pid); write_status(&status, "stopped", None); Ok(())
}
