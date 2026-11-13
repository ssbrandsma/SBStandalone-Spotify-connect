//! Filesystem handshake with the stock SqueezePlay output owner.
//! Producer EOF is not audible EOF. Tokens fence acknowledgements across skips.
use std::{fs, io, path::PathBuf};

pub(crate) struct DrainGate {
    base: PathBuf,
    token: Option<String>,
}

impl DrainGate {
    pub(crate) fn from_env() -> Option<Self> {
        std::env::var_os("SBSPOTIFY_DRAIN_PATH").map(|base| Self {
            base: base.into(), token: None,
        })
    }

    fn path(&self, suffix: &str) -> PathBuf {
        let mut path = self.base.as_os_str().to_owned();
        path.push(suffix);
        path.into()
    }

    pub(crate) fn begin(&mut self, token: String) -> io::Result<()> {
        self.cancel();
        fs::write(self.path(".tmp"), token.as_bytes())?;
        fs::rename(self.path(".tmp"), &self.base)?;
        self.token = Some(token);
        Ok(())
    }

    pub(crate) fn acknowledged(&self) -> bool {
        self.token.as_ref().is_some_and(|token| {
            fs::read_to_string(self.path(".ack")).ok().as_ref() == Some(token)
        })
    }

    pub(crate) fn cancel(&mut self) {
        self.token = None;
        let _ = fs::remove_file(&self.base);
        let _ = fs::remove_file(self.path(".ack"));
    }
}

impl Drop for DrainGate {
    fn drop(&mut self) { self.cancel(); }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_requires_matching_ack_and_skip_cancels_it() {
        let base = std::env::temp_dir().join(format!("spotify-drain-test-{}", std::process::id()));
        let mut gate = DrainGate { base, token: None };
        gate.begin("first".into()).unwrap();
        assert!(!gate.acknowledged());
        fs::write(gate.path(".ack"), "old").unwrap();
        assert!(!gate.acknowledged());
        fs::write(gate.path(".ack"), "first").unwrap();
        assert!(gate.acknowledged());
        gate.cancel();
        assert!(!gate.base.exists());
        assert!(!gate.acknowledged());
        gate.begin("second".into()).unwrap();
        fs::write(gate.path(".ack"), "first").unwrap();
        assert!(!gate.acknowledged());
    }
}
