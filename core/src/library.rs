use crate::{PrumoError, fail, parser};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use walkdir::WalkDir;

#[derive(Clone, Debug, uniffi::Record)]
pub struct AgentSource {
    pub agent: String,
    pub root: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SessionRow {
    pub key: String,
    pub agent: String,
    pub external_id: String,
    pub title: String,
    pub project: String,
    pub updated_ms: i64,
    pub message_count: u32,
    pub source_path: String,
    pub source_root: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SessionMessage {
    pub index: u32,
    pub role: String,
    pub text: String,
    pub timestamp: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SessionDetail {
    pub session: SessionRow,
    pub messages: Vec<SessionMessage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SearchOrder {
    Newest,
    Oldest,
    Relevance,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchHit {
    pub session: SessionRow,
    pub message_index: u32,
    pub excerpt: String,
    pub role: String,
    pub message_digest: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryStats {
    pub sessions: u32,
    pub messages: u64,
    pub projects: u32,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ScanReport {
    pub indexed: u32,
    pub unchanged: u32,
    pub skipped: u32,
    pub malformed_lines: u32,
    pub cancelled: bool,
    pub warnings: Vec<String>,
}

#[derive(uniffi::Object)]
pub struct SessionIndex {
    database: PathBuf,
    scan_lock: Mutex<()>,
    cancelled: AtomicBool,
}

pub(crate) const SESSION_COLUMNS: &str = "s.key,s.agent,s.external_id,s.title,s.project,s.updated_ms,s.message_count,s.source_path,s.source_root";

#[uniffi::export]
impl SessionIndex {
    #[uniffi::constructor]
    pub fn new(database_path: String) -> Result<Arc<Self>, PrumoError> {
        let database = PathBuf::from(database_path);
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent)?;
        }
        let index = Arc::new(Self {
            database,
            scan_lock: Mutex::new(()),
            cancelled: AtomicBool::new(false),
        });
        let db = index.connection()?;
        let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != 2 {
            db.execute_batch(
                "DROP TRIGGER IF EXISTS message_insert;
                DROP TRIGGER IF EXISTS message_delete;
                DROP TABLE IF EXISTS passages;
                DROP TABLE IF EXISTS messages;
                DROP TABLE IF EXISTS sessions;
                DROP TABLE IF EXISTS skill_events;",
            )?;
        }
        db.execute_batch("PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sessions (
                key TEXT PRIMARY KEY, agent TEXT NOT NULL, external_id TEXT NOT NULL,
                title TEXT NOT NULL, project TEXT NOT NULL, updated_ms INTEGER NOT NULL,
                message_count INTEGER NOT NULL, source_path TEXT NOT NULL UNIQUE,
                source_root TEXT NOT NULL, file_size INTEGER NOT NULL, file_modified INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY, text TEXT NOT NULL, session_key TEXT NOT NULL,
                message_index INTEGER NOT NULL, role TEXT NOT NULL, timestamp TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS message_session ON messages(session_key,message_index);
            CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(
                text, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS message_insert AFTER INSERT ON messages BEGIN
                INSERT INTO passages(rowid,text) VALUES(new.id,new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS message_delete AFTER DELETE ON messages BEGIN
                INSERT INTO passages(passages,rowid,text) VALUES('delete',old.id,old.text);
            END;
            CREATE TABLE IF NOT EXISTS skill_events (
                session_key TEXT NOT NULL, event_id TEXT NOT NULL, reference TEXT NOT NULL,
                by_name INTEGER NOT NULL, used_ms INTEGER NOT NULL,
                PRIMARY KEY(session_key,event_id,reference,by_name)
            );
            CREATE INDEX IF NOT EXISTS skill_event_session ON skill_events(session_key);
            CREATE INDEX IF NOT EXISTS session_activity ON sessions(updated_ms DESC);
            CREATE INDEX IF NOT EXISTS session_project ON sessions(project);")?;
        db.pragma_update(None, "user_version", 2)?;
        Ok(index)
    }

    pub fn cancel_scan(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    pub fn scan(&self, sources: Vec<AgentSource>) -> Result<ScanReport, PrumoError> {
        let _guard = self
            .scan_lock
            .lock()
            .map_err(|_| fail("The index is busy. Restart Prumo."))?;
        self.cancelled.store(false, Ordering::Relaxed);
        let mut db = self.connection()?;
        let mut report = ScanReport {
            indexed: 0,
            unchanged: 0,
            skipped: 0,
            malformed_lines: 0,
            cancelled: false,
            warnings: vec![],
        };
        let mut seen = HashSet::new();
        let mut available_roots = HashSet::new();
        for source in &sources {
            if !matches!(source.agent.as_str(), "codex" | "claude") {
                return Err(fail("Unsupported agent source."));
            }
            let root = Path::new(&source.root);
            if !root.is_dir() {
                report.warnings.push(format!(
                    "{} folder is unavailable: {}",
                    source.agent, source.root
                ));
                continue;
            }
            available_roots.insert(source.root.clone());
            let titles = if source.agent == "codex" {
                read_titles(root)
            } else {
                HashMap::new()
            };
            let folders = if source.agent == "codex" {
                vec![root.join("sessions"), root.join("archived_sessions")]
            } else {
                vec![root.join("projects")]
            };
            let mut paths = Vec::new();
            for folder in folders {
                if !folder.exists() {
                    continue;
                }
                for entry in WalkDir::new(&folder)
                    .follow_links(false)
                    .into_iter()
                    .filter_entry(|e| e.file_name() != "subagents")
                {
                    match entry {
                        Ok(entry)
                            if entry.file_type().is_file()
                                && entry.path().extension().is_some_and(|ext| ext == "jsonl") =>
                        {
                            if !entry.file_name().to_string_lossy().starts_with("agent-") {
                                paths.push(entry.into_path());
                            }
                        }
                        Err(error) => {
                            available_roots.remove(&source.root);
                            if report.warnings.len() < 20 {
                                report.warnings.push(error.to_string());
                            }
                        }
                        _ => {}
                    }
                }
            }
            paths.sort_by_cached_key(|p| {
                std::cmp::Reverse(
                    p.metadata()
                        .and_then(|m| m.modified())
                        .unwrap_or(UNIX_EPOCH),
                )
            });
            for path in paths {
                if self.cancelled.load(Ordering::Relaxed) {
                    report.cancelled = true;
                    return Ok(report);
                }
                let path_string = path.to_string_lossy().into_owned();
                seen.insert(path_string.clone());
                let metadata = match path.metadata() {
                    Ok(m) => m,
                    Err(_) => {
                        report.skipped += 1;
                        continue;
                    }
                };
                if metadata.len() > 512 * 1024 * 1024 {
                    report.skipped += 1;
                    if report.warnings.len() < 20 {
                        report
                            .warnings
                            .push(format!("Session exceeds 512 MB: {}", path.display()));
                    }
                    continue;
                }
                let modified = milliseconds(metadata.modified().unwrap_or(UNIX_EPOCH));
                let old: Option<(i64, i64, String)> = db.query_row("SELECT file_size,file_modified,external_id FROM sessions WHERE source_path=?1", [&path_string], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
                if old.as_ref().is_some_and(|(size, time, _)| {
                    *size == metadata.len() as i64 && *time == modified
                }) {
                    if let Some((_, _, id)) = &old
                        && let Some(title) = titles.get(id)
                    {
                        db.execute(
                            "UPDATE sessions SET title=?1 WHERE source_path=?2",
                            params![title, path_string],
                        )?;
                    }
                    report.unchanged += 1;
                    continue;
                }
                let mut parsed = match parser::parse(&path, &source.agent) {
                    Ok(parsed) => parsed,
                    Err(error) => {
                        report.skipped += 1;
                        if report.warnings.len() < 20 {
                            report.warnings.push(format!("{}: {error}", path.display()));
                        }
                        continue;
                    }
                };
                report.malformed_lines += parsed.malformed_lines;
                if parsed.messages.is_empty() {
                    report.skipped += 1;
                    continue;
                }
                if let Some(title) = titles.get(&parsed.external_id) {
                    parsed.title = title.clone();
                }
                let key = format!("{}:{}", source.agent, parsed.external_id);
                let activity = if parsed.activity_ms > 0 {
                    parsed.activity_ms
                } else {
                    modified
                };
                let duplicate: Option<(String, i64, u32)> = db
                    .query_row(
                        "SELECT source_path,updated_ms,message_count FROM sessions WHERE key=?1",
                        [&key],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .optional()?;
                if duplicate.is_some_and(|(existing, time, count)| {
                    existing != path_string
                        && (time > activity
                            || (time == activity && count >= parsed.messages.len() as u32))
                }) {
                    report.unchanged += 1;
                    continue;
                }
                let tx = db.transaction()?;
                if let Some(old_key) = tx
                    .query_row(
                        "SELECT key FROM sessions WHERE source_path=?1",
                        [&path_string],
                        |r| r.get::<_, String>(0),
                    )
                    .optional()?
                {
                    tx.execute("DELETE FROM messages WHERE session_key=?1", [&old_key])?;
                    tx.execute("DELETE FROM skill_events WHERE session_key=?1", [&old_key])?;
                    tx.execute("DELETE FROM sessions WHERE key=?1", [&old_key])?;
                }
                tx.execute("DELETE FROM messages WHERE session_key=?1", [&key])?;
                tx.execute("DELETE FROM skill_events WHERE session_key=?1", [&key])?;
                tx.execute(
                    "INSERT OR REPLACE INTO sessions VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                    params![
                        key,
                        source.agent,
                        parsed.external_id,
                        parsed.title,
                        parsed.project,
                        activity,
                        parsed.messages.len() as u32,
                        path_string,
                        source.root,
                        metadata.len() as i64,
                        modified
                    ],
                )?;
                {
                    let mut insert = tx.prepare_cached("INSERT INTO messages(text,session_key,message_index,role,timestamp) VALUES (?1,?2,?3,?4,?5)")?;
                    for message in parsed.messages {
                        insert.execute(params![
                            message.text,
                            key,
                            message.index,
                            message.role,
                            message.timestamp
                        ])?;
                    }
                }
                for event in parsed.usage {
                    tx.execute(
                        "INSERT OR IGNORE INTO skill_events VALUES (?1,?2,?3,?4,?5)",
                        params![
                            key,
                            event.id,
                            event.reference,
                            event.by_name,
                            event.timestamp
                        ],
                    )?;
                }
                tx.commit()?;
                report.indexed += 1;
            }
        }
        let stale = {
            let mut query = db.prepare("SELECT key,source_path,source_root,agent FROM sessions")?;
            query
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let tx = db.transaction()?;
        for (key, path, root, agent) in stale {
            let configured = sources.iter().any(|s| s.root == root && s.agent == agent);
            if !configured || (available_roots.contains(&root) && !seen.contains(&path)) {
                tx.execute("DELETE FROM messages WHERE session_key=?1", [&key])?;
                tx.execute("DELETE FROM skill_events WHERE session_key=?1", [&key])?;
                tx.execute("DELETE FROM sessions WHERE key=?1", [&key])?;
            }
        }
        tx.commit()?;
        Ok(report)
    }

    pub fn skill_usage(
        &self,
        skills: Vec<crate::SkillRow>,
    ) -> Result<Vec<crate::SkillUsage>, PrumoError> {
        self.collect_skill_usage(skills)
    }

    pub fn stats(&self) -> Result<LibraryStats, PrumoError> {
        self.connection()?.query_row("SELECT count(*),coalesce(sum(message_count),0),count(DISTINCT project) FROM sessions", [], |row| Ok(LibraryStats { sessions: row.get(0)?, messages: row.get::<_,i64>(1)? as u64, projects: row.get(2)? })).map_err(Into::into)
    }

    pub fn projects(&self) -> Result<Vec<String>, PrumoError> {
        let db = self.connection()?;
        let mut statement = db.prepare("SELECT DISTINCT project FROM sessions WHERE project != '' ORDER BY project COLLATE NOCASE")?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub fn search(
        &self,
        query: String,
        agent: String,
        project: String,
        limit: u32,
        order: SearchOrder,
    ) -> Result<Vec<SearchHit>, PrumoError> {
        struct PassageMatch {
            id: i64,
            index: u32,
            role: String,
            score: f64,
        }

        let mut connection = self.connection()?;
        let db = connection.transaction()?;
        let query = query.trim();
        let expression = search_expression(query);
        let mut matches = HashMap::<String, PassageMatch>::new();
        if !expression.is_empty() {
            let mut statement = db.prepare(
                "SELECT m.session_key,m.id,m.message_index,m.role,bm25(passages)
                 FROM passages JOIN messages m ON m.id=passages.rowid
                 JOIN sessions s ON s.key=m.session_key
                 WHERE passages MATCH ?1 AND (?2='' OR s.agent=?2) AND (?3='' OR s.project=?3)",
            )?;
            let mut rows = statement.query(params![expression, agent, project])?;
            while let Some(row) = rows.next()? {
                let key: String = row.get(0)?;
                let hit = PassageMatch {
                    id: row.get(1)?,
                    index: row.get(2)?,
                    role: row.get(3)?,
                    score: row.get(4)?,
                };
                let replace = matches.get(&key).is_none_or(|previous| {
                    hit.score
                        .total_cmp(&previous.score)
                        .then(hit.index.cmp(&previous.index))
                        .is_lt()
                });
                if replace {
                    matches.insert(key, hit);
                }
            }
        }
        let mut candidates = Vec::new();
        {
            let sql = format!(
                "SELECT {SESSION_COLUMNS},(?3='' OR instr(lower(s.title),lower(?3))>0 OR instr(lower(s.external_id),lower(?3))>0)
                 FROM sessions s WHERE (?1='' OR s.agent=?1) AND (?2='' OR s.project=?2)"
            );
            let mut statement = db.prepare(&sql)?;
            let mut rows = statement.query(params![agent, project, query])?;
            while let Some(row) = rows.next()? {
                let session = session_row(row)?;
                let passage = matches.remove(&session.key);
                if passage.is_some() || row.get::<_, bool>(9)? {
                    candidates.push((session, passage));
                }
            }
        }
        candidates.sort_by(|(left, left_match), (right, right_match)| {
            let primary = match order {
                SearchOrder::Newest => right.updated_ms.cmp(&left.updated_ms),
                SearchOrder::Oldest => left.updated_ms.cmp(&right.updated_ms),
                SearchOrder::Relevance => match (left_match, right_match) {
                    (Some(left), Some(right)) => left.score.total_cmp(&right.score),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                },
            };
            primary
                .then_with(|| right.updated_ms.cmp(&left.updated_ms))
                .then_with(|| left.key.cmp(&right.key))
        });
        candidates.truncate(limit.clamp(1, 500) as usize);
        let results = {
            let mut snippet = db.prepare("SELECT snippet(passages,0,'','',' … ',48) FROM passages WHERE rowid=?1 AND passages MATCH ?2")?;
            let mut first_message = db.prepare("SELECT message_index,text,role FROM messages WHERE session_key=?1 ORDER BY message_index LIMIT 1")?;
            let mut results = Vec::with_capacity(candidates.len());
            for (session, passage) in candidates {
                let (message_index, excerpt, role) = if let Some(passage) = passage {
                    let excerpt =
                        snippet.query_row(params![passage.id, expression], |row| row.get(0))?;
                    (passage.index, excerpt, passage.role)
                } else {
                    first_message.query_row([&session.key], |row| {
                        Ok((
                            row.get(0)?,
                            crate::shorten(&row.get::<_, String>(1)?, 300),
                            row.get(2)?,
                        ))
                    })?
                };
                results.push(SearchHit {
                    session,
                    message_index,
                    excerpt,
                    role,
                    message_digest: String::new(),
                });
            }
            results
        };
        db.commit()?;
        Ok(results)
    }

    pub fn transcript(&self, key: String) -> Result<SessionDetail, PrumoError> {
        let db = self.connection()?;
        let sql = format!("SELECT {SESSION_COLUMNS} FROM sessions s WHERE key=?1");
        let session = db
            .query_row(&sql, [&key], session_row)
            .optional()?
            .ok_or_else(|| {
                fail("This session is no longer in the library. Refresh your sources.")
            })?;
        let mut statement = db.prepare("SELECT message_index,role,text,timestamp FROM messages WHERE session_key=?1 ORDER BY message_index")?;
        let messages = statement
            .query_map([&key], |row| {
                Ok(SessionMessage {
                    index: row.get(0)?,
                    role: row.get(1)?,
                    text: row.get(2)?,
                    timestamp: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(SessionDetail { session, messages })
    }

    pub fn evidence(
        &self,
        question: String,
        agent: String,
        project: String,
    ) -> Result<Vec<SearchHit>, PrumoError> {
        let stopwords = [
            "what", "where", "when", "which", "with", "that", "this", "from", "have", "does",
            "were", "about", "there", "please", "find", "how", "did", "the", "and", "for", "was",
            "are", "can", "you", "our", "any", "why", "has", "had",
        ];
        let keywords = question
            .split(|c: char| !c.is_alphanumeric())
            .filter(|s| s.chars().count() > 2 && !stopwords.contains(&s.to_lowercase().as_str()))
            .collect::<Vec<_>>()
            .join(" ");
        let query = if keywords.is_empty() {
            question
        } else {
            keywords
        };
        let mut hits = self.search(
            query.clone(),
            agent.clone(),
            project.clone(),
            8,
            SearchOrder::Relevance,
        )?;
        if hits.is_empty() {
            let mut seen = HashSet::new();
            for keyword in query.split_whitespace().take(10) {
                for hit in self.search(
                    keyword.into(),
                    agent.clone(),
                    project.clone(),
                    3,
                    SearchOrder::Relevance,
                )? {
                    if seen.insert(hit.session.key.clone()) {
                        hits.push(hit);
                    }
                    if hits.len() >= 8 {
                        break;
                    }
                }
                if hits.len() >= 8 {
                    break;
                }
            }
        }
        let mut evidence = Vec::new();
        for mut hit in hits {
            let detail = self.transcript(hit.session.key.clone())?;
            let position = detail
                .messages
                .iter()
                .position(|m| m.index == hit.message_index)
                .unwrap_or_default();
            hit.message_digest = crate::fingerprint(&detail.messages[position].text);
            let first = position.saturating_sub(1);
            hit.excerpt = detail
                .messages
                .iter()
                .skip(first)
                .take(3)
                .map(|m| format!("{}: {}", m.role, crate::shorten(&m.text, 2400)))
                .collect::<Vec<_>>()
                .join("\n\n");
            evidence.push(hit);
        }
        Ok(evidence)
    }

    pub fn resolve_citation(
        &self,
        key: String,
        message_index: u32,
        message_digest: String,
    ) -> Result<u32, PrumoError> {
        let detail = self.transcript(key)?;
        if let Some(message) = detail
            .messages
            .iter()
            .find(|m| m.index == message_index && crate::fingerprint(&m.text) == message_digest)
        {
            return Ok(message.index);
        }
        detail.messages.iter().find(|m| crate::fingerprint(&m.text) == message_digest).map(|m| m.index)
            .ok_or_else(|| fail("This passage changed or was removed. Find passages again to refresh the citation."))
    }
}

impl SessionIndex {
    pub(crate) fn connection(&self) -> Result<Connection, PrumoError> {
        let connection = Connection::open(&self.database)?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        connection.busy_timeout(std::time::Duration::from_secs(15))?;
        Ok(connection)
    }
}

pub(crate) fn session_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRow> {
    Ok(SessionRow {
        key: row.get(0)?,
        agent: row.get(1)?,
        external_id: row.get(2)?,
        title: row.get(3)?,
        project: row.get(4)?,
        updated_ms: row.get(5)?,
        message_count: row.get(6)?,
        source_path: row.get(7)?,
        source_root: row.get(8)?,
    })
}

fn search_expression(query: &str) -> String {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .take(20)
        .map(|word| format!("\"{word}\"*"))
        .collect::<Vec<_>>()
        .join(" AND ")
}

fn milliseconds(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

fn read_titles(root: &Path) -> HashMap<String, String> {
    use std::io::{BufRead, BufReader};
    let Ok(file) = fs::File::open(root.join("session_index.jsonl")) else {
        return HashMap::new();
    };
    let mut titles = HashMap::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line)
            && let (Some(id), Some(title)) = (
                value["id"].as_str(),
                value["thread_name"]
                    .as_str()
                    .or_else(|| value["title"].as_str()),
            )
        {
            titles.insert(id.into(), title.into());
        }
    }
    titles
}
