#[derive(Debug, Copy, Clone, Error)]
pub enum LoadingError {
}

/// Hyper's /etc/hyper/config.toml file format.
#[derive(Debug, Clone, Deserialize)]
struct Config {
}

impl Config {
    pub fn safe_load() -> Result<Self, LoadingError> {
    }
}
