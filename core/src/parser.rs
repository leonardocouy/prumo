use crate::{PrumoError, fail, shorten};
use serde_json::Value;
use std::{
    collections::HashSet,
    fs::File,
    io::{BufRead, BufReader},
    path::Path,
};

pub(crate) struct ParsedSession {
    pub external_id: String,
    pub title: String,
    pub project: String,
    pub messages: Vec<ParsedMessage>,
    pub usage: Vec<crate::usage::UsageEvent>,
    pub malformed_lines: u32,
    pub activity_ms: i64,
}

pub(crate) struct ParsedMessage {
    pub index: u32,
    pub role: String,
    pub text: String,
    pub timestamp: String,
}

pub(crate) fn parse(path: &Path, agent: &str) -> Result<ParsedSession, PrumoError> {
    let file = File::open(path)?;
    let mut session = ParsedSession {
        external_id: String::new(),
        title: String::new(),
        project: String::new(),
        messages: Vec::new(),
        usage: Vec::new(),
        malformed_lines: 0,
        activity_ms: 0,
    };
    let mut seen = HashSet::new();
    let mut usage = crate::usage::UsageParser::default();
    let mut line = String::new();
    let mut reader = BufReader::new(file);
    let mut index = 0u32;
    let mut previous_family = "";
    loop {
        line.clear();
        let read = reader.by_ref().take(8 * 1024 * 1024).read_line(&mut line)?;
        if read == 0 {
            break;
        }
        if read >= 8 * 1024 * 1024 && !line.ends_with('\n') {
            return Err(fail("A session record exceeds the 8 MB safety limit."));
        }
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(_) => {
                session.malformed_lines += 1;
                continue;
            }
        };
        let kind = string(&value, "type");
        let payload = &value["payload"];
        if agent == "codex" && kind == "session_meta" {
            session.external_id = string(payload, "id").into();
            session.project = string(payload, "cwd").into();
            if let Some(title) = payload.get("title").and_then(Value::as_str) {
                session.title = title.into();
            }
        }
        if agent == "claude" {
            if value["isSidechain"].as_bool() == Some(true) {
                continue;
            }
            if session.external_id.is_empty() {
                session.external_id = string(&value, "sessionId").into();
            }
            if session.project.is_empty() {
                session.project = string(&value, "cwd").into();
            }
            if kind == "custom-title" && !string(&value, "customTitle").is_empty() {
                session.title = string(&value, "customTitle").into();
            }
            if let Some(uuid) = value.get("uuid").and_then(Value::as_str)
                && !seen.insert(uuid.to_owned())
            {
                continue;
            }
        }
        usage.observe(&value, agent, &session.project);
        let event =
            agent == "codex" && kind == "event_msg" && string(payload, "type") == "item_completed";
        let message = if event
            && matches!(
                string(&payload["item"], "type"),
                "UserMessage" | "AgentMessage"
            ) {
            &payload["item"]
        } else if agent == "codex"
            && kind == "response_item"
            && string(payload, "type") == "message"
        {
            payload
        } else if agent == "claude" && matches!(kind, "user" | "assistant") {
            &value["message"]
        } else {
            continue;
        };
        let role = match string(message, "type") {
            "UserMessage" => "user",
            "AgentMessage" => "assistant",
            _ => string(message, "role"),
        };
        if !matches!(role, "user" | "assistant") {
            continue;
        }
        let text = content_text(&message["content"]);
        if text.trim().is_empty() {
            continue;
        }
        if agent == "codex"
            && let Some(id) = message.get("id").and_then(Value::as_str)
            && !seen.insert(id.to_owned())
        {
            continue;
        }
        if role == "user" && context_only(&text) {
            continue;
        }
        let family = if event { "event" } else { "message" };
        if agent == "codex"
            && previous_family != family
            && session
                .messages
                .last()
                .is_some_and(|previous| previous.role == role && previous.text == text)
        {
            continue;
        }
        if session.title.is_empty()
            && role == "user"
            && let Some(title) = title_text(&text)
        {
            session.title = title;
        }
        session.messages.push(ParsedMessage {
            index,
            role: role.into(),
            text: shorten(&text, 500_000),
            timestamp: string(&value, "timestamp").into(),
        });
        let activity = value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|t| t.timestamp_millis())
            .or_else(|| payload.get("completed_at_ms").and_then(Value::as_i64))
            .unwrap_or_default();
        session.activity_ms = session.activity_ms.max(activity);
        previous_family = family;
        index += 1;
    }
    session.usage = usage.finish();
    if agent == "codex"
        && let Some(id) = file_session_id(path)
    {
        session.external_id = id;
    }
    if session.external_id.is_empty() {
        return Err(fail("No session identity was found."));
    }
    if session.title.is_empty() {
        session.title = "Untitled session".into();
    }
    Ok(session)
}

use std::io::Read;

fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn content_text(value: &Value) -> String {
    if let Some(text) = value.as_str() {
        return text.into();
    }
    value
        .as_array()
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(|block| match string(block, "type") {
                    "text" | "Text" | "input_text" | "output_text" => {
                        block.get("text").and_then(Value::as_str)
                    }
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n\n")
        })
        .unwrap_or_default()
}

fn title_text(text: &str) -> Option<String> {
    let text = text
        .rsplit_once("## My request:")
        .map(|(_, text)| text)
        .unwrap_or(text)
        .trim();
    if text.starts_with("# AGENTS.md")
        || text.starts_with("<environment_context>")
        || text.starts_with("<INSTRUCTIONS>")
        || text.starts_with("<permissions instructions>")
        || text.starts_with("<local-command")
        || text.starts_with("<command-name>")
        || text.starts_with("<system-reminder>")
        || text.starts_with("<task-notification>")
    {
        return None;
    }
    let first = text.lines().find(|line| !line.trim().is_empty())?;
    Some(shorten(first.trim().trim_start_matches('#').trim(), 110))
}

fn context_only(text: &str) -> bool {
    title_text(text).is_none() || text.trim_start().starts_with("<turn_aborted>")
}

fn file_session_id(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let tail = stem.get(stem.len().checked_sub(36)?..)?;
    if tail.bytes().enumerate().all(|(index, byte)| {
        if [8, 13, 18, 23].contains(&index) {
            byte == b'-'
        } else {
            byte.is_ascii_hexdigit()
        }
    }) {
        Some(tail.into())
    } else {
        None
    }
}
