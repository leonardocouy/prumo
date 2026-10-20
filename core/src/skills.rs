use crate::{PrumoError, fail, shorten};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
    time::UNIX_EPOCH,
};
use walkdir::WalkDir;

#[derive(Clone, Debug, uniffi::Record)]
pub struct SkillRow {
    pub id: String,
    pub name: String,
    pub description: String,
    pub path: String,
    pub read_only: bool,
    pub codex_state: String,
    pub claude_state: String,
    pub modified_ms: i64,
    pub added_ms: Option<i64>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SkillDetail {
    pub skill: SkillRow,
    pub text: String,
    pub revision: String,
    pub files: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SkillTrashLink {
    pub path: String,
    pub destination: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SkillTrashTarget {
    pub id: String,
    pub name: String,
    pub revision: String,
    pub links: Vec<SkillTrashLink>,
}

#[derive(uniffi::Object)]
pub struct SkillStore {
    roots: Vec<PathBuf>,
    codex: PathBuf,
    claude: PathBuf,
    shared: PathBuf,
}

#[uniffi::export]
impl SkillStore {
    #[uniffi::constructor]
    pub fn new(
        roots: Vec<String>,
        codex_skills: String,
        claude_skills: String,
        shared_skills: String,
    ) -> Arc<Self> {
        Arc::new(Self {
            roots: roots.into_iter().map(PathBuf::from).collect(),
            codex: codex_skills.into(),
            claude: claude_skills.into(),
            shared: shared_skills.into(),
        })
    }

    pub fn list(&self, query: String) -> Result<Vec<SkillRow>, PrumoError> {
        let mut skills = HashMap::new();
        for root in &self.roots {
            if !root.exists() {
                continue;
            }
            for entry in WalkDir::new(root)
                .follow_links(true)
                .max_depth(5)
                .into_iter()
                .filter_entry(|e| {
                    !matches!(
                        e.file_name().to_str(),
                        Some(".git" | "node_modules" | "target")
                    )
                })
            {
                let Ok(entry) = entry else {
                    continue;
                };
                if !entry.file_type().is_file() || entry.file_name() != "SKILL.md" {
                    continue;
                }
                let Some(parent) = entry.path().parent() else {
                    continue;
                };
                let Ok(folder) = parent.canonicalize() else {
                    continue;
                };
                if skills.contains_key(&folder) {
                    continue;
                }
                let Ok(row) = self.row(&folder) else {
                    continue;
                };
                if query.is_empty()
                    || format!("{} {}", row.name, row.description)
                        .to_lowercase()
                        .contains(&query.to_lowercase())
                {
                    skills.insert(folder, row);
                }
            }
        }
        let mut result = skills.into_values().collect::<Vec<_>>();
        result.sort_by_key(|skill| skill.name.to_lowercase());
        Ok(result)
    }

    pub fn detail(&self, id: String) -> Result<SkillDetail, PrumoError> {
        let folder = self.known_folder(&id)?;
        let skill = self.row(&folder)?;
        let text = read_document(&folder)?;
        let revision = revision(&text);
        let mut files = WalkDir::new(&folder)
            .max_depth(5)
            .follow_links(false)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file() && entry.file_name() != "SKILL.md")
            .filter_map(|entry| {
                entry
                    .path()
                    .strip_prefix(&folder)
                    .ok()
                    .map(|path| path.to_string_lossy().into_owned())
            })
            .take(500)
            .collect::<Vec<_>>();
        files.sort();
        Ok(SkillDetail {
            skill,
            text,
            revision,
            files,
        })
    }

    pub fn save(
        &self,
        id: String,
        text: String,
        expected_revision: String,
    ) -> Result<SkillDetail, PrumoError> {
        let folder = self.writable_folder(&id)?;
        let current = read_document(&folder)?;
        if revision(&current) != expected_revision {
            return Err(fail(
                "This skill changed outside Prumo. Reload it before saving.",
            ));
        }
        if text.len() > 2 * 1024 * 1024 {
            return Err(fail("A skill document must be smaller than 2 MB."));
        }
        atomic_write(&folder.join("SKILL.md"), &text)?;
        self.detail(id)
    }

    pub fn create(
        &self,
        name: String,
        text: String,
        root: String,
    ) -> Result<SkillDetail, PrumoError> {
        if name.is_empty()
            || name.len() > 100
            || !name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            || name.starts_with('-')
        {
            return Err(fail(
                "Use lowercase letters, numbers, and hyphens for the folder name.",
            ));
        }
        let root = PathBuf::from(root);
        if !self.roots.contains(&root) {
            return Err(fail("Choose one of your configured skill folders."));
        }
        if text.len() > 2 * 1024 * 1024 {
            return Err(fail("A skill document must be smaller than 2 MB."));
        }
        fs::create_dir_all(&root)?;
        let folder = root.join(name);
        fs::create_dir(&folder).map_err(|error| {
            fail(format!(
                "Could not create the skill. Its folder may already exist. {error}"
            ))
        })?;
        if let Err(error) = atomic_write(&folder.join("SKILL.md"), &text) {
            let _ = fs::remove_dir(&folder);
            return Err(error);
        }
        self.detail(folder.canonicalize()?.to_string_lossy().into_owned())
    }

    pub fn set_link(
        &self,
        id: String,
        agent: String,
        enabled: bool,
    ) -> Result<SkillDetail, PrumoError> {
        let folder = self.known_folder(&id)?;
        let root = match agent.as_str() {
            "codex" => &self.codex,
            "claude" => &self.claude,
            _ => return Err(fail("Unsupported agent.")),
        };
        let name = folder
            .file_name()
            .ok_or_else(|| fail("This skill has no folder name."))?;
        let target = root.join(name);
        match fs::symlink_metadata(&target) {
            Ok(metadata) => {
                if !metadata.file_type().is_symlink() {
                    return Err(fail(
                        "This agent has an original skill folder here. Prumo will not replace or unlink it.",
                    ));
                }
                if target.canonicalize().ok().as_deref() != Some(folder.as_path()) {
                    return Err(fail(
                        "A different skill already uses this name in the agent folder.",
                    ));
                }
                if !enabled {
                    fs::remove_file(&target)?;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if enabled {
                    fs::create_dir_all(root)?;
                    std::os::unix::fs::symlink(&folder, &target)?;
                }
            }
            Err(error) => return Err(error.into()),
        }
        self.detail(id)
    }

    pub fn prepare_trash(&self, ids: Vec<String>) -> Result<Vec<SkillTrashTarget>, PrumoError> {
        let inventory = self.list(String::new())?;
        let mut targets = Vec::new();
        let mut seen = HashSet::new();
        for id in ids {
            if !seen.insert(id.clone()) {
                continue;
            }
            let skill = inventory.iter().find(|s| s.id == id).ok_or_else(|| {
                fail("A selected skill is no longer installed. Refresh and try again.")
            })?;
            if skill.read_only {
                return Err(fail(format!(
                    "{} is managed and cannot be moved to Trash.",
                    skill.name
                )));
            }
            let folder = Path::new(&skill.path);
            if inventory
                .iter()
                .any(|s| s.id != id && Path::new(&s.path).starts_with(folder))
            {
                return Err(fail(format!(
                    "{} contains other installed skills. Remove its child skills separately.",
                    skill.name
                )));
            }
            let text = read_document(folder)?;
            let mut links = Vec::new();
            for root in [&self.codex, &self.claude, &self.shared] {
                let Ok(entries) = fs::read_dir(root) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path
                        .symlink_metadata()
                        .is_ok_and(|m| m.file_type().is_symlink())
                        && path.canonicalize().ok().as_deref() == Some(folder)
                    {
                        links.push(SkillTrashLink {
                            destination: fs::read_link(&path)?.to_string_lossy().into_owned(),
                            path: path.to_string_lossy().into_owned(),
                        });
                    }
                }
            }
            links.sort_by(|a, b| a.path.cmp(&b.path));
            links.dedup();
            targets.push(SkillTrashTarget {
                id,
                name: skill.name.clone(),
                revision: revision(&text),
                links,
            });
        }
        Ok(targets)
    }

    pub fn trash_path(&self, id: String) -> Result<String, PrumoError> {
        Ok(self.writable_folder(&id)?.to_string_lossy().into_owned())
    }
}

impl SkillStore {
    fn known_folder(&self, id: &str) -> Result<PathBuf, PrumoError> {
        let folder = Path::new(id).canonicalize()?;
        if self
            .list(String::new())?
            .iter()
            .any(|skill| Path::new(&skill.id) == folder)
        {
            Ok(folder)
        } else {
            Err(fail("This skill is outside your configured folders."))
        }
    }

    fn writable_folder(&self, id: &str) -> Result<PathBuf, PrumoError> {
        let folder = self.known_folder(id)?;
        if self.is_read_only(&folder) {
            return Err(fail(
                "This skill is managed or outside an editable skill folder.",
            ));
        }
        read_document(&folder)?;
        Ok(folder)
    }

    fn is_read_only(&self, folder: &Path) -> bool {
        folder.to_string_lossy().contains("/plugins/cache/")
            || !self
                .roots
                .iter()
                .filter_map(|root| root.canonicalize().ok())
                .any(|root| folder.starts_with(&root))
    }

    fn row(&self, folder: &Path) -> Result<SkillRow, PrumoError> {
        let text = read_document(folder)?;
        let (name, description) = frontmatter(&text);
        let fallback = folder.file_name().unwrap_or_default().to_string_lossy();
        let modified_ms = folder
            .join("SKILL.md")
            .metadata()?
            .modified()?
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let added_ms = folder
            .metadata()?
            .created()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .and_then(|duration| i64::try_from(duration.as_millis()).ok());
        Ok(SkillRow {
            added_ms,
            id: folder.to_string_lossy().into_owned(),
            name: if name.is_empty() {
                fallback.into_owned()
            } else {
                name
            },
            description,
            path: folder.to_string_lossy().into_owned(),
            read_only: self.is_read_only(folder),
            codex_state: self.link_state(folder, &self.codex, true),
            claude_state: self.link_state(folder, &self.claude, false),
            modified_ms,
        })
    }

    fn link_state(&self, folder: &Path, root: &Path, codex: bool) -> String {
        if codex
            && (self
                .shared
                .canonicalize()
                .ok()
                .is_some_and(|shared| folder.starts_with(shared))
                || self
                    .shared
                    .join(folder.file_name().unwrap_or_default())
                    .canonicalize()
                    .ok()
                    .as_deref()
                    == Some(folder))
        {
            return "shared".into();
        }
        let target = root.join(folder.file_name().unwrap_or_default());
        if target.canonicalize().ok().as_deref() != Some(folder) {
            return "absent".into();
        }
        if target
            .symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink())
        {
            "linked".into()
        } else {
            "source".into()
        }
    }
}

fn read_document(folder: &Path) -> Result<String, PrumoError> {
    let path = folder.join("SKILL.md");
    let canonical = path.canonicalize()?;
    if !canonical.starts_with(folder) {
        return Err(fail("SKILL.md points outside the skill folder."));
    }
    if path.metadata()?.len() > 2 * 1024 * 1024 {
        return Err(fail("This skill document exceeds 2 MB."));
    }
    Ok(fs::read_to_string(path)?)
}

fn revision(text: &str) -> String {
    crate::fingerprint(text)
}

fn atomic_write(path: &Path, text: &str) -> Result<(), PrumoError> {
    use std::os::unix::fs::PermissionsExt;
    let nonce = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = path.with_file_name(format!(".prumo-{}-{nonce}.tmp", std::process::id()));
    let result = (|| -> Result<(), PrumoError> {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        let mode = path
            .metadata()
            .map(|m| m.permissions().mode())
            .unwrap_or(0o644);
        fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn frontmatter(text: &str) -> (String, String) {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return (String::new(), String::new());
    }
    let mut fields = HashMap::<String, String>::new();
    let mut current = String::new();
    let allowed: HashSet<&str> = ["name", "description"].into_iter().collect();
    for line in lines {
        if line.trim() == "---" {
            break;
        }
        if line.starts_with(char::is_whitespace) && !current.is_empty() {
            let value = fields.entry(current.clone()).or_default();
            if !value.is_empty() {
                value.push(' ');
            }
            value.push_str(line.trim());
        } else if let Some((key, value)) = line.split_once(':') {
            current = if allowed.contains(key) {
                key.into()
            } else {
                String::new()
            };
            if !current.is_empty() {
                let value = value.trim();
                let decoded = if value.starts_with('"') {
                    serde_json::from_str::<String>(value).unwrap_or_else(|_| value.into())
                } else {
                    value.trim_matches('\'').replace("''", "'")
                };
                fields.insert(
                    current.clone(),
                    if matches!(value, "|" | ">" | "|-" | ">-") {
                        String::new()
                    } else {
                        decoded
                    },
                );
            }
        }
    }
    (
        fields.remove("name").unwrap_or_default(),
        shorten(&fields.remove("description").unwrap_or_default(), 600),
    )
}
