use serde::Serialize;

#[derive(Serialize)]
pub struct Version {
    version: &'static str,
    checksum_blake3: String,
}

pub fn render() -> Version {
    Version {
        version: env!("CARGO_PKG_VERSION"),
        checksum_blake3: hyperrs_elfsum::checksum!().hex(),
    }
}
