mod library;
mod parser;
mod skills;
mod usage;

pub use library::*;
pub use skills::*;
pub use usage::SkillUsage;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PrumoError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<std::io::Error> for PrumoError {
    fn from(error: std::io::Error) -> Self {
        Self::Failed {
            message: error.to_string(),
        }
    }
}

impl From<rusqlite::Error> for PrumoError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Failed {
            message: error.to_string(),
        }
    }
}

fn fail(message: impl Into<String>) -> PrumoError {
    PrumoError::Failed {
        message: message.into(),
    }
}

fn shorten(text: &str, limit: usize) -> String {
    let mut chars = text.chars();
    let result: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{result}…")
    } else {
        result
    }
}

fn fingerprint(text: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    format!("{:x}", hasher.finish())
}
