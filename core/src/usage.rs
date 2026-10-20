use crate::{PrumoError, SessionRow, SkillRow};
use rusqlite::params;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, uniffi::Record)]
pub struct SkillUsage {
    pub skill_id: String,
    pub uses: u64,
    pub codex_uses: u64,
    pub claude_uses: u64,
    pub last_used_ms: i64,
    pub sessions: Vec<SessionRow>,
}

pub(crate) struct UsageEvent {
    pub id: String,
    pub reference: String,
    pub by_name: bool,
    pub timestamp: i64,
}

#[derive(Default)]
pub(crate) struct UsageParser {
    pending: HashMap<String, Vec<UsageEvent>>,
    completed: Vec<UsageEvent>,
    legacy_reads: Vec<UsageEvent>,
    command_events: bool,
}

impl UsageParser {
    pub fn observe(&mut self, value: &Value, agent: &str, project: &str) {
        let payload = &value["payload"];
        let time = value["timestamp"]
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|t| t.timestamp_millis())
            .or_else(|| payload["completed_at_ms"].as_i64())
            .unwrap_or_default();
        if agent == "codex" {
            let item = &payload["item"];
            if value["type"] == "event_msg"
                && payload["type"] == "item_completed"
                && item["type"] == "CommandExecution"
            {
                self.command_events = true;
                if item["exit_code"] != 0 || item["status"] != "completed" {
                    return;
                }
                let id = item["id"].as_str().unwrap_or_default();
                let cwd = item["cwd"]
                    .as_str()
                    .unwrap_or(project)
                    .trim_start_matches("file://");
                if let Some(commands) = item["parsed_cmd"].as_array() {
                    for command in commands {
                        if command["type"] == "read"
                            && let Some(path) = command["path"].as_str()
                        {
                            self.completed.extend(path_event(id, path, cwd, time));
                        }
                    }
                }
            }
            if value["type"] == "response_item" {
                let id = payload["call_id"].as_str().unwrap_or_default();
                if payload["type"] == "function_call" {
                    if let Ok(input) = serde_json::from_str::<Value>(
                        payload["arguments"].as_str().unwrap_or_default(),
                    ) {
                        let name = payload["name"].as_str().unwrap_or_default();
                        let mut events = Vec::new();
                        if matches!(name, "exec_command" | "shell_command" | "shell") {
                            let command =
                                input["cmd"].as_str().or_else(|| input["command"].as_str());
                            let cwd = input["workdir"].as_str().unwrap_or(project);
                            if let Some(command) = command {
                                events = shell_reads(id, command, cwd, time);
                            }
                            if let Some(parts) = input["command"].as_array()
                                && let Some(command) = parts.last().and_then(Value::as_str)
                            {
                                events = shell_reads(id, command, cwd, time);
                            }
                        }
                        if !events.is_empty() {
                            self.pending.insert(id.into(), events);
                        }
                    }
                } else if payload["type"] == "function_call_output" {
                    let output = &payload["output"];
                    let success = output
                        .as_str()
                        .is_some_and(|s| s.contains("Process exited with code 0"))
                        || output["exit_code"] == 0;
                    if let Some(events) = self.pending.remove(id)
                        && success
                    {
                        self.legacy_reads.extend(events);
                    }
                }
            }
        } else if agent == "claude" {
            let Some(blocks) = value["message"]["content"].as_array() else {
                return;
            };
            for block in blocks {
                if block["type"] == "tool_use" && value["type"] == "assistant" {
                    let id = block["id"].as_str().unwrap_or_default();
                    let input = &block["input"];
                    let events = match block["name"].as_str().unwrap_or_default() {
                        "Skill" => input["skill"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .map(|name| {
                                vec![UsageEvent {
                                    id: id.into(),
                                    reference: name.into(),
                                    by_name: true,
                                    timestamp: time,
                                }]
                            })
                            .unwrap_or_default(),
                        "Read" => input["file_path"]
                            .as_str()
                            .map(|path| path_event(id, path, project, time))
                            .unwrap_or_default(),
                        "Bash" => input["command"]
                            .as_str()
                            .map(|cmd| shell_reads(id, cmd, project, time))
                            .unwrap_or_default(),
                        _ => vec![],
                    };
                    if !events.is_empty() {
                        self.pending.insert(id.into(), events);
                    }
                } else if block["type"] == "tool_result" && value["type"] == "user" {
                    let id = block["tool_use_id"].as_str().unwrap_or_default();
                    if let Some(events) = self.pending.remove(id)
                        && block["is_error"] != true
                    {
                        self.completed.extend(events);
                    }
                }
            }
        }
    }

    pub fn finish(mut self) -> Vec<UsageEvent> {
        if !self.command_events {
            self.completed.extend(self.legacy_reads);
        }
        let mut seen = HashSet::new();
        self.completed.retain(|event| {
            !event.id.is_empty()
                && seen.insert((event.id.clone(), event.reference.clone(), event.by_name))
        });
        self.completed
    }
}

fn path_event(id: &str, path: &str, cwd: &str, timestamp: i64) -> Vec<UsageEvent> {
    let path = if let Some(tail) = path.strip_prefix("~/") {
        std::env::var("HOME")
            .map(|home| PathBuf::from(home).join(tail))
            .unwrap_or_else(|_| PathBuf::from(path))
    } else {
        PathBuf::from(path)
    };
    if path.file_name().is_none_or(|name| name != "SKILL.md") {
        return vec![];
    }
    let path = if path.is_absolute() {
        path
    } else {
        Path::new(cwd).join(path)
    };
    vec![UsageEvent {
        id: id.into(),
        reference: path.to_string_lossy().into_owned(),
        by_name: false,
        timestamp,
    }]
}

// Only literal read commands qualify. Scripts, searches, writes, and echoed paths do not.
fn shell_reads(id: &str, command: &str, cwd: &str, timestamp: i64) -> Vec<UsageEvent> {
    if command.contains(['$', '`', '>', '<', '*', '?', '(', ')']) {
        return vec![];
    }
    let mut commands = Vec::new();
    let mut tokens = Vec::new();
    let mut token = String::new();
    let mut quote = None;
    let mut escaped = false;
    for c in command.chars() {
        if escaped {
            token.push(c);
            escaped = false;
            continue;
        }
        if c == '\\' && quote != Some('\'') {
            escaped = true;
            continue;
        }
        if quote == Some(c) {
            quote = None;
            continue;
        }
        if quote.is_none() && matches!(c, '\'' | '"') {
            quote = Some(c);
            continue;
        }
        if quote.is_none() && c == '#' {
            return vec![];
        }
        if quote.is_none() && (c.is_whitespace() || matches!(c, ';' | '&' | '|')) {
            if !token.is_empty() {
                tokens.push(std::mem::take(&mut token));
            }
            if matches!(c, ';' | '&' | '|' | '\n') && !tokens.is_empty() {
                commands.push(std::mem::take(&mut tokens));
            }
        } else {
            token.push(c);
        }
    }
    if quote.is_some() || escaped {
        return vec![];
    }
    if !token.is_empty() {
        tokens.push(token);
    }
    if !tokens.is_empty() {
        commands.push(tokens);
    }
    // A compound command can succeed after an earlier read failed.
    if commands.len() != 1 || command.contains([';', '&', '|', '\n']) {
        return vec![];
    }
    let tokens = &commands[0];
    let first = &tokens[0];
    if !matches!(
        Path::new(first).file_name().and_then(|s| s.to_str()),
        Some("cat" | "head" | "tail" | "sed")
    ) {
        return vec![];
    }
    if first.ends_with("sed") && tokens.iter().any(|s| s.starts_with("-i")) {
        return vec![];
    }
    tokens
        .iter()
        .skip(1)
        .flat_map(|path| path_event(id, path, cwd, timestamp))
        .collect()
}

impl crate::SessionIndex {
    pub(crate) fn collect_skill_usage(
        &self,
        skills: Vec<SkillRow>,
    ) -> Result<Vec<SkillUsage>, PrumoError> {
        let db = self.connection()?;
        let mut rows = skills
            .iter()
            .map(|skill| SkillUsage {
                skill_id: skill.id.clone(),
                uses: 0,
                codex_uses: 0,
                claude_uses: 0,
                last_used_ms: 0,
                sessions: vec![],
            })
            .collect::<Vec<_>>();
        let paths: HashMap<PathBuf, usize> = skills
            .iter()
            .enumerate()
            .map(|(i, s)| (PathBuf::from(&s.path), i))
            .collect();
        let mut names = HashMap::<String, Vec<usize>>::new();
        for (i, skill) in skills.iter().enumerate() {
            for name in [
                Some(skill.name.as_str()),
                Path::new(&skill.path).file_name().and_then(|s| s.to_str()),
            ]
            .into_iter()
            .flatten()
            {
                let matches = names.entry(name.into()).or_default();
                if !matches.contains(&i) {
                    matches.push(i);
                }
            }
        }
        let sql = format!(
            "SELECT {},u.event_id,u.reference,u.by_name,u.used_ms FROM skill_events u JOIN sessions s ON s.key=u.session_key ORDER BY s.updated_ms,s.key",
            crate::library::SESSION_COLUMNS
        );
        let mut statement = db.prepare(&sql)?;
        let mut query = statement.query(params![])?;
        let mut seen = HashSet::new();
        let mut resolved = HashMap::new();
        while let Some(row) = query.next()? {
            let session = crate::library::session_row(row)?;
            let event: String = row.get(9)?;
            let reference: String = row.get(10)?;
            let by_name: bool = row.get(11)?;
            let time: i64 = row.get(12)?;
            let matched = *resolved
                .entry((reference.clone(), by_name))
                .or_insert_with(|| {
                    if by_name {
                        let direct = names.get(&reference).cloned().unwrap_or_default();
                        let matches = if direct.is_empty() {
                            if let Some((namespace, name)) = reference.rsplit_once(':') {
                                names
                                    .get(name)
                                    .into_iter()
                                    .flatten()
                                    .copied()
                                    .filter(|i| {
                                        Path::new(&skills[*i].path)
                                            .components()
                                            .any(|part| part.as_os_str() == namespace)
                                    })
                                    .collect::<Vec<_>>()
                            } else {
                                vec![]
                            }
                        } else {
                            direct
                        };
                        if matches.len() == 1 {
                            Some(matches[0])
                        } else {
                            None
                        }
                    } else {
                        Path::new(&reference)
                            .parent()
                            .and_then(|p| p.canonicalize().ok())
                            .and_then(|p| paths.get(&p).copied())
                    }
                });
            let Some(i) = matched else {
                continue;
            };
            if !seen.insert((i, session.agent.clone(), event)) {
                continue;
            }
            let usage = &mut rows[i];
            usage.uses += 1;
            if session.agent == "codex" {
                usage.codex_uses += 1;
            } else {
                usage.claude_uses += 1;
            }
            usage.last_used_ms = usage.last_used_ms.max(time);
            if !usage.sessions.iter().any(|s| s.key == session.key) {
                usage.sessions.push(session);
            }
        }
        for row in &mut rows {
            row.sessions
                .sort_by_key(|s| std::cmp::Reverse(s.updated_ms));
        }
        Ok(rows)
    }
}
