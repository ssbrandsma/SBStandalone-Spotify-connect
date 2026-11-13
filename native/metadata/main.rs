use std::{env, fs::{self, OpenOptions}, io::Write};

fn esc(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r")
}

fn main() -> std::io::Result<()> {
    let path = env::args().nth(1).ok_or_else(|| std::io::Error::other("metadata path required"))?;
    let event = env::var("PLAYER_EVENT").unwrap_or_default();
    if event == "volume_changed" {
        let volume_path = format!("{}.volume", path);
        fs::write(volume_path, env::var("VOLUME").unwrap_or_default().as_bytes())?;
        return Ok(());
    }
    if event == "loading" {
        let loading_path = format!("{}.loading", path);
        let tmp = format!("{}.tmp", loading_path);
        let loading = format!("{}:{}", env::var("TRACK_ID").unwrap_or_default(),
            env::var("PLAY_REQUEST_ID").unwrap_or_default());
        fs::write(&tmp, loading.as_bytes())?;
        fs::rename(tmp, loading_path)?;
    }
    if matches!(event.as_str(), "playing" | "paused" | "seeked" | "position_correction") {
        let position_path = format!("{}.position", path);
        let tmp = format!("{}.tmp", position_path);
        let value = format!("{}\n{}", env::var("TRACK_ID").unwrap_or_default(), env::var("POSITION_MS").unwrap_or_default());
        fs::write(&tmp, value.as_bytes())?;
        fs::rename(tmp, position_path)?;
        if event == "seeked" || event == "position_correction" { return Ok(()); }
    }
    let state = match event.as_str() {
        "paused" => "paused",
        // Natural EOF must not flush the local decoder/output tail.
        "end_of_track" => return Ok(()),
        "stopped" | "unavailable" => "stopped",
        "playing" | "track_changed" | "loading" => "playing",
        _ => return Ok(()),
    };
    if event != "track_changed" {
        let state_path = format!("{}.state", path);
        fs::write(state_path, state.as_bytes())?;
        return Ok(());
    }
    let track_id = env::var("TRACK_ID").unwrap_or_default();
    let title = env::var("NAME").unwrap_or_default();
    let artist = env::var("ARTISTS").unwrap_or_default().replace('\n', ", ");
    let album = env::var("ALBUM").unwrap_or_default();
    let duration = env::var("DURATION_MS").unwrap_or_default();
    let covers = env::var("COVERS").unwrap_or_default();
    let artwork = covers.lines().next().unwrap_or("");
    let json = format!(r#"{{"playback_state":"{}","track_id":"{}","title":"{}","artist":"{}","album":"{}","duration_ms":"{}","artwork_url":"{}"}}
"#, state, esc(&track_id), esc(&title), esc(&artist), esc(&album), esc(&duration), esc(artwork));
    if let Some(parent) = std::path::Path::new(&path).parent() { let _ = fs::create_dir_all(parent); }
    let tmp = format!("{}.tmp", path);
    let mut f = OpenOptions::new().create(true).write(true).truncate(true).open(&tmp)?;
    f.write_all(json.as_bytes())?;
    fs::rename(tmp, path)?;
    Ok(())
}
