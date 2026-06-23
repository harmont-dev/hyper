use super::Error;
use std::fmt;
use std::str::FromStr;

/// A thin-pool message we permit: provision or drop a thin device by id.
#[derive(Clone)]
pub enum ThinMessage {
    CreateThin(u64),
    Delete(u64),
}

impl FromStr for ThinMessage {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_whitespace().collect::<Vec<_>>().as_slice() {
            ["create_thin", id] => Ok(ThinMessage::CreateThin(
                id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            )),
            ["delete", id] => Ok(ThinMessage::Delete(
                id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            )),
            _ => Err(Error::BadTable(s.to_string())),
        }
    }
}

impl fmt::Display for ThinMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ThinMessage::CreateThin(id) => write!(f, "create_thin {id}"),
            ThinMessage::Delete(id) => write!(f, "delete {id}"),
        }
    }
}
