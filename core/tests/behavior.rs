use prumo_core::{AgentSource, SearchOrder, SessionIndex, SkillStore};
use std::{fs, path::Path};
use tempfile::TempDir;

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn codex(id: &str, prompt: &str, answer: &str) -> String {
    [
        serde_json::json!({"type":"session_meta","payload":{"id":id,"cwd":"/work/example"}}),
        serde_json::json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":prompt}]}}),
        serde_json::json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":answer}]}}),
    ].into_iter().map(|v|v.to_string()).collect::<Vec<_>>().join("\n")+"\n"
}

fn source(root: &Path) -> AgentSource {
    AgentSource {
        agent: "codex".into(),
        root: root.display().to_string(),
    }
}

#[test]
fn incomplete_record_does_not_hide_valid_messages_and_append_is_indexed() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("sessions/thread.jsonl");
    write(
        &path,
        &(codex("abc", "Fix café search", "Unicode search is enabled.") + "{unfinished"),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    let report = index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(report.malformed_lines, 1);
    assert_eq!(
        index
            .search(
                "café".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .len(),
        1
    );
    write(
        &path,
        &codex(
            "abc",
            "Fix café search",
            "Use the unicode tokenizer for accents.",
        ),
    );
    index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(
        index.transcript("codex:abc".into()).unwrap().messages.len(),
        2
    );
    assert!(
        index
            .search(
                "accents".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()[0]
            .excerpt
            .contains("accents")
    );
}

#[test]
fn malformed_session_does_not_prevent_other_sessions_or_delete_last_good_copy() {
    let dir = TempDir::new().unwrap();
    let good = dir.path().join("sessions/good.jsonl");
    write(
        &good,
        &codex(
            "good",
            "Database migration",
            "Set the timeout to 40 seconds.",
        ),
    );
    write(&dir.path().join("sessions/broken.jsonl"), "{bad}\n");
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    assert_eq!(index.scan(vec![source(dir.path())]).unwrap().skipped, 1);
    write(&good, "{not-valid\n");
    index.scan(vec![source(dir.path())]).unwrap();
    assert!(
        index.transcript("codex:good".into()).unwrap().messages[1]
            .text
            .contains("40 seconds")
    );
}

#[test]
fn unreadable_source_preserves_cached_sessions_after_many_warnings() {
    use std::os::unix::fs::PermissionsExt;

    let dir = TempDir::new().unwrap();
    let sessions = dir.path().join("sessions");
    write(
        &sessions.join("saved.jsonl"),
        &codex("saved", "Keep this session", "Still available."),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();

    let mut sources = (0..20)
        .map(|i| source(&dir.path().join(format!("missing-{i}"))))
        .collect::<Vec<_>>();
    sources.push(source(dir.path()));
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o000)).unwrap();
    let report = index.scan(sources);
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(report.unwrap().warnings.len() >= 20);
    assert_eq!(
        index.transcript("codex:saved".into()).unwrap().messages[1].text,
        "Still available."
    );
}

#[test]
fn filtering_and_literal_fts_inputs_do_not_broaden_search() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/one.jsonl"),
        &codex("one", "Cache timeout", "Use Redis."),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    assert!(
        index
            .search(
                "\" OR * NOT".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .is_empty()
    );
    assert!(
        index
            .search(
                "cache".into(),
                "claude".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .is_empty()
    );
    assert!(
        index
            .search(
                "cache".into(),
                "".into(),
                "/different".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        index
            .search(
                "cache timeout".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn source_removal_prunes_the_index_without_touching_original_files() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("sessions/thread.jsonl");
    write(&path, &codex("abc", "Configure database", "Done."));
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    index.scan(vec![]).unwrap();
    assert_eq!(index.stats().unwrap().sessions, 0);
    assert!(path.exists());
}

#[test]
fn claude_custom_root_ignores_tool_results_and_duplicate_records() {
    let dir = TempDir::new().unwrap();
    let record = serde_json::json!({"type":"user","sessionId":"custom-id","cwd":"/work/claude","uuid":"same","message":{"role":"user","content":"Implement invoices"}}).to_string();
    let tool = serde_json::json!({"type":"user","sessionId":"custom-id","uuid":"tool","message":{"role":"user","content":[{"type":"tool_result","content":"Secret tool output"}]}}).to_string();
    write(
        &dir.path().join("claude-work/projects/example/thread.jsonl"),
        &format!("{record}\n{record}\n{tool}\n"),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index
        .scan(vec![AgentSource {
            agent: "claude".into(),
            root: dir.path().join("claude-work").display().to_string(),
        }])
        .unwrap();
    let detail = index.transcript("claude:custom-id".into()).unwrap();
    assert_eq!(detail.messages.len(), 1);
    assert_eq!(detail.session.title, "Implement invoices");
}

fn store(dir: &Path) -> std::sync::Arc<SkillStore> {
    SkillStore::new(
        vec![
            dir.join("shared").display().to_string(),
            dir.join("codex").display().to_string(),
            dir.join("claude").display().to_string(),
        ],
        dir.join("codex").display().to_string(),
        dir.join("claude").display().to_string(),
        dir.join("shared").display().to_string(),
    )
}

#[test]
fn skill_edit_rejects_a_stale_revision_without_overwriting_external_changes() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store.create("build-tools".into(), "---\nname: Build tools\ndescription: >\n  Reliable builds\n  for everyone\n---\nInstructions".into(),dir.path().join("shared").display().to_string()).unwrap();
    assert_eq!(skill.skill.description, "Reliable builds for everyone");
    fs::write(
        Path::new(&skill.skill.path).join("SKILL.md"),
        "External edit",
    )
    .unwrap();
    assert!(
        store
            .save(skill.skill.id, "My edit".into(), skill.revision)
            .is_err()
    );
    assert_eq!(
        fs::read_to_string(Path::new(&skill.skill.path).join("SKILL.md")).unwrap(),
        "External edit"
    );
}

#[test]
fn agent_link_refuses_name_collisions_and_never_removes_an_original_folder() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let root = dir.path().join("shared").display().to_string();
    let skill = store
        .create("review".into(), "Review safely".into(), root)
        .unwrap();
    write(
        &dir.path().join("claude/review/SKILL.md"),
        "Original Claude skill",
    );
    assert!(
        store
            .set_link(skill.skill.id.clone(), "claude".into(), true)
            .is_err()
    );
    assert!(
        store
            .set_link(skill.skill.id, "claude".into(), false)
            .is_err()
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("claude/review/SKILL.md")).unwrap(),
        "Original Claude skill"
    );
}

#[test]
fn link_and_unlink_preserve_skill_content_and_deduplicate_inventory() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Review safely".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    assert_eq!(
        store
            .set_link(skill.skill.id.clone(), "claude".into(), true)
            .unwrap()
            .skill
            .claude_state,
        "linked"
    );
    assert_eq!(store.list("".into()).unwrap().len(), 1);
    store
        .set_link(skill.skill.id.clone(), "claude".into(), false)
        .unwrap();
    assert!(!dir.path().join("claude/review").exists());
    assert_eq!(store.detail(skill.skill.id).unwrap().text, "Review safely");
}

#[test]
fn skill_paths_cannot_escape_the_configured_roots() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    assert!(
        store
            .create(
                "../escape".into(),
                "text".into(),
                dir.path().join("shared").display().to_string()
            )
            .is_err()
    );
    assert!(
        store
            .create(
                "valid".into(),
                "text".into(),
                dir.path().join("outside").display().to_string()
            )
            .is_err()
    );
    write(&dir.path().join("outside/SKILL.md"), "Private document");
    assert!(
        store
            .detail(dir.path().join("outside").display().to_string())
            .is_err()
    );
    fs::create_dir_all(dir.path().join("shared/linked-file")).unwrap();
    std::os::unix::fs::symlink(
        dir.path().join("outside/SKILL.md"),
        dir.path().join("shared/linked-file/SKILL.md"),
    )
    .unwrap();
    assert!(store.list("".into()).unwrap().is_empty());
}

#[test]
fn codex_completed_events_are_read_without_duplicating_response_messages() {
    let dir = TempDir::new().unwrap();
    let records = [
        serde_json::json!({"type":"session_meta","payload":{"id":"events","cwd":"/work/example"}}),
        serde_json::json!({"type":"response_item","payload":{"type":"message","id":"context","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nInternal scaffold"}]}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"prompt","content":[{"type":"Text","text":"Configure the cache"}]}}}),
        serde_json::json!({"type":"response_item","payload":{"type":"message","id":"other-prompt-id","role":"user","content":[{"type":"input_text","text":"Configure the cache"}]}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"reply","content":[{"type":"Text","text":"The cache uses Redis."}]}}}),
    ];
    write(
        &dir.path().join("sessions/events.jsonl"),
        &records
            .iter()
            .map(|r| r.to_string())
            .collect::<Vec<_>>()
            .join("\n"),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let detail = index.transcript("codex:events".into()).unwrap();
    assert_eq!(detail.messages.len(), 2);
    assert_eq!(detail.session.title, "Configure the cache");
    assert!(
        index
            .search(
                "scaffold".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()
            .is_empty()
    );
    assert!(
        index
            .search(
                "Redis".into(),
                "".into(),
                "".into(),
                10,
                SearchOrder::Relevance
            )
            .unwrap()[0]
            .excerpt
            .contains("Redis")
    );
}

#[test]
fn evidence_keeps_the_source_message_and_adjacent_result_for_a_natural_question() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/one.jsonl"),
        &codex(
            "one",
            "Configure database timeout",
            "The database timeout was set to 40 seconds.",
        ),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let hits = index
        .evidence(
            "Where did we configure the database timeout?".into(),
            "".into(),
            "".into(),
        )
        .unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].session.key, "codex:one");
    assert!(hits[0].excerpt.contains("40 seconds"));
    assert!(
        index
            .transcript(hits[0].session.key.clone())
            .unwrap()
            .messages
            .iter()
            .any(|m| m.index == hits[0].message_index)
    );
}

#[test]
fn citations_survive_appends_but_reject_changed_source_text() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("sessions/one.jsonl");
    write(
        &path,
        &codex(
            "one",
            "Database timeout",
            "The database timeout was set to 40 seconds.",
        ),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let hit = index
        .evidence("database timeout".into(), "".into(), "".into())
        .unwrap()
        .remove(0);
    assert_eq!(
        index
            .resolve_citation(
                hit.session.key.clone(),
                hit.message_index,
                hit.message_digest.clone()
            )
            .unwrap(),
        hit.message_index
    );
    let appended = serde_json::json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"A later follow-up"}]}}).to_string();
    write(
        &path,
        &(codex(
            "one",
            "Database timeout",
            "The database timeout was set to 40 seconds.",
        ) + &appended
            + "\n"),
    );
    index.scan(vec![source(dir.path())]).unwrap();
    assert!(
        index
            .resolve_citation(
                hit.session.key.clone(),
                hit.message_index,
                hit.message_digest.clone()
            )
            .is_ok()
    );
    write(
        &path,
        &codex("one", "New task", "The earlier messages were removed."),
    );
    index.scan(vec![source(dir.path())]).unwrap();
    assert!(
        index
            .resolve_citation(hit.session.key, hit.message_index, hit.message_digest)
            .is_err()
    );
}

#[test]
fn codex_fork_file_identity_overrides_inherited_metadata_and_activity_uses_message_time() {
    let dir = TempDir::new().unwrap();
    let own_id = "01990000-aaaa-7bbb-8ccc-000000000001";
    let text = codex("inherited-parent", "Fork work", "A result");
    let mut records = text
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .collect::<Vec<_>>();
    records[1]["timestamp"] = serde_json::json!("2024-01-02T12:30:00-03:00");
    records[2]["timestamp"] = serde_json::json!("2024-01-02T16:00:00Z");
    write(
        &dir.path()
            .join(format!("sessions/rollout-2024-01-02-{own_id}.jsonl")),
        &records
            .iter()
            .map(|r| r.to_string())
            .collect::<Vec<_>>()
            .join("\n"),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let detail = index.transcript(format!("codex:{own_id}")).unwrap();
    assert_eq!(detail.session.external_id, own_id);
    assert_eq!(detail.session.updated_ms, 1704211200000);
    assert!(index.transcript("codex:inherited-parent".into()).is_err());
}

fn records(values: Vec<serde_json::Value>) -> String {
    values.into_iter().map(|v| v.to_string() + "\n").collect()
}

fn skill_read(id: &str, path: &Path, success: bool) -> serde_json::Value {
    serde_json::json!({"type":"event_msg","timestamp":"2026-10-15T12:00:00Z","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":id,"cwd":"file:///tmp","status":"completed","exit_code":if success {0}else{1},"parsed_cmd":[{"type":"read","path":path.to_str().unwrap()}]}}})
}

#[test]
fn usage_deduplicates_records_and_forks_without_counting_mentions_or_failed_reads() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Review".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    let path = Path::new(&skill.skill.path).join("SKILL.md");
    let read = skill_read("read-one", &path, true);
    let data = codex(
        "original",
        &format!("Please read {}", path.display()),
        "Done",
    ) + &records(vec![
        read.clone(),
        read.clone(),
        skill_read("failed", &path, false),
    ]);
    write(&dir.path().join("sessions/original.jsonl"), &data);
    write(
        &dir.path().join("sessions/fork.jsonl"),
        &(codex("fork", "Different session", "Done") + &records(vec![read])),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let usage = index.skill_usage(store.list("".into()).unwrap()).unwrap();
    assert_eq!(usage[0].uses, 1);
    assert_eq!(usage[0].codex_uses, 1);
    assert_eq!(usage[0].sessions.len(), 1);
    assert_eq!(usage[0].last_used_ms, 1792065600000);
    assert_eq!(
        index
            .transcript("codex:original".into())
            .unwrap()
            .messages
            .len(),
        2
    );
}

#[test]
fn claude_usage_requires_success_and_resolves_symlinks_but_rejects_ambiguous_names() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "---\nname: review\n---\nReview".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    store
        .set_link(skill.skill.id.clone(), "claude".into(), true)
        .unwrap();
    write(
        &dir.path().join("codex/other/SKILL.md"),
        "---\nname: review\n---\nAnother skill",
    );
    let data = records(vec![
        serde_json::json!({"type":"user","sessionId":"claude-one","cwd":"/tmp","uuid":"u1","message":{"role":"user","content":"Use review, not a usage event."}}),
        serde_json::json!({"type":"assistant","sessionId":"claude-one","uuid":"a1","timestamp":"2026-10-15T12:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call-one","name":"Skill","input":{"skill":"review"}},{"type":"tool_use","id":"call-two","name":"Read","input":{"file_path":dir.path().join("claude/review/SKILL.md")}},{"type":"tool_use","id":"call-failed","name":"Read","input":{"file_path":dir.path().join("claude/review/SKILL.md")}}]}}),
        serde_json::json!({"type":"user","sessionId":"claude-one","uuid":"result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-one","is_error":false,"content":"Skill loaded"},{"type":"tool_result","tool_use_id":"call-two","content":"Review"},{"type":"tool_result","tool_use_id":"call-failed","is_error":true,"content":"No permission"}]}}),
    ]);
    write(&dir.path().join("projects/example/thread.jsonl"), &data);
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index
        .scan(vec![AgentSource {
            agent: "claude".into(),
            root: dir.path().display().to_string(),
        }])
        .unwrap();
    let usage = index.skill_usage(store.list("".into()).unwrap()).unwrap();
    let used = usage.iter().find(|u| u.skill_id == skill.skill.id).unwrap();
    assert_eq!(used.uses, 1);
    assert_eq!(used.claude_uses, 1);
    fs::remove_dir_all(dir.path().join("codex/other")).unwrap();
    let usage = index.skill_usage(store.list("".into()).unwrap()).unwrap();
    assert_eq!(usage[0].uses, 2);
}

#[test]
fn usage_refresh_replaces_events_and_prunes_removed_sources() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Review".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    let read = skill_read("one", &Path::new(&skill.skill.path).join("SKILL.md"), true);
    let path = dir.path().join("sessions/thread.jsonl");
    let base = codex("one", "Review project", "Done");
    write(&path, &(base.clone() + &records(vec![read.clone()])));
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(
        index.skill_usage(store.list("".into()).unwrap()).unwrap()[0].uses,
        1
    );
    write(
        &path,
        &(base.clone()
            + &records(vec![
                read,
                skill_read("two", &Path::new(&skill.skill.path).join("SKILL.md"), true),
            ])),
    );
    index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(
        index.skill_usage(store.list("".into()).unwrap()).unwrap()[0].uses,
        2
    );
    write(&path, &base);
    index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(
        index.skill_usage(store.list("".into()).unwrap()).unwrap()[0].uses,
        0
    );
    index.scan(vec![]).unwrap();
    assert_eq!(
        index.skill_usage(store.list("".into()).unwrap()).unwrap()[0].uses,
        0
    );
}

#[test]
fn legacy_codex_counts_only_completed_literal_reads() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Review".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    let path = Path::new(&skill.skill.path).join("SKILL.md");
    let mut values = vec![];
    for (id, cmd, success) in [
        ("read", format!("cat '{}'", path.display()), true),
        ("mention", format!("echo '{}'", path.display()), true),
        (
            "edit",
            format!("sed -i 's/a/b/' '{}'", path.display()),
            true,
        ),
        ("fail", format!("cat '{}'", path.display()), false),
        (
            "compound",
            format!("cat '{}' || true", path.display()),
            true,
        ),
        (
            "echo-command",
            format!("echo 'hello; cat {}; done'", path.display()),
            true,
        ),
    ] {
        values.push(serde_json::json!({"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":id,"arguments":serde_json::json!({"cmd":cmd}).to_string()}}));
        values.push(serde_json::json!({"type":"response_item","payload":{"type":"function_call_output","call_id":id,"output":if success {"Process exited with code 0"} else {"Process exited with code 1"}}}));
    }
    write(
        &dir.path().join("sessions/thread.jsonl"),
        &(codex("one", "Review", "Done") + &records(values)),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    assert_eq!(
        index.skill_usage(store.list("".into()).unwrap()).unwrap()[0].uses,
        1
    );
}

#[test]
fn trash_plan_protects_managed_nested_and_unrelated_skills() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Review".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    store
        .set_link(skill.skill.id.clone(), "claude".into(), true)
        .unwrap();
    write(&dir.path().join("codex/unrelated/SKILL.md"), "Unrelated");
    let plan = store
        .prepare_trash(vec![skill.skill.id.clone(), skill.skill.id.clone()])
        .unwrap();
    assert_eq!(plan.len(), 1);
    assert_eq!(plan[0].links.len(), 1);
    assert!(Path::new(&plan[0].links[0].path).ends_with("claude/review"));
    write(
        &Path::new(&skill.skill.path).join("nested/SKILL.md"),
        "Nested",
    );
    assert!(store.prepare_trash(vec![skill.skill.id]).is_err());
    write(
        &dir.path().join("shared/plugins/cache/managed/SKILL.md"),
        "Managed",
    );
    let managed = store
        .list("".into())
        .unwrap()
        .into_iter()
        .find(|s| s.read_only)
        .unwrap();
    assert!(store.prepare_trash(vec![managed.id]).is_err());
    assert!(dir.path().join("codex/unrelated/SKILL.md").exists());
}

#[test]
fn skill_added_date_uses_source_folder_creation_and_survives_edits_and_links() {
    let dir = TempDir::new().unwrap();
    let store = store(dir.path());
    let skill = store
        .create(
            "review".into(),
            "Original".into(),
            dir.path().join("shared").display().to_string(),
        )
        .unwrap();
    let folder = Path::new(&skill.skill.path);
    let expected = folder
        .metadata()
        .unwrap()
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64);
    fs::File::open(folder.join("SKILL.md"))
        .unwrap()
        .set_times(
            fs::FileTimes::new()
                .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(946684800)),
        )
        .unwrap();
    let listed = store.list("".into()).unwrap();
    assert_eq!(listed[0].added_ms, expected);
    if expected.is_some() {
        assert_ne!(listed[0].added_ms, Some(listed[0].modified_ms));
    }
    let saved = store
        .save(
            skill.skill.id.clone(),
            "Updated instructions".into(),
            skill.revision,
        )
        .unwrap();
    assert_eq!(saved.skill.added_ms, expected);
    let linked = store
        .set_link(skill.skill.id.clone(), "claude".into(), true)
        .unwrap();
    assert_eq!(linked.skill.added_ms, expected);
    let reopened = SkillStore::new(
        vec![dir.path().join("claude").display().to_string()],
        dir.path().join("codex").display().to_string(),
        dir.path().join("claude").display().to_string(),
        dir.path().join("shared").display().to_string(),
    );
    assert_eq!(reopened.list("".into()).unwrap()[0].added_ms, expected);
}

fn dated_codex(id: &str, title: &str, day: u32, messages: &[&str]) -> String {
    let mut values = vec![
        serde_json::json!({"type":"session_meta","payload":{"id":id,"title":title,"cwd":"/work/example"}}),
    ];
    values.extend(messages.iter().map(|text| serde_json::json!({"type":"response_item","timestamp":format!("2026-10-{day:02}T12:00:00Z"),"payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":text}]}})));
    records(values)
}

#[test]
fn session_date_order_merges_title_and_body_matches_before_limiting() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/new.jsonl"),
        &dated_codex("new", "needle announcement", 20, &["A title-only result."]),
    );
    write(
        &dir.path().join("sessions/old.jsonl"),
        &dated_codex("old", "Older work", 1, &["needle"]),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let newest = index
        .search(
            "needle".into(),
            "".into(),
            "".into(),
            1,
            SearchOrder::Newest,
        )
        .unwrap();
    assert_eq!(newest[0].session.external_id, "new");
    assert_eq!(newest[0].role, "assistant");
    assert_eq!(newest[0].excerpt, "A title-only result.");
    let oldest = index
        .search(
            "needle".into(),
            "".into(),
            "".into(),
            1,
            SearchOrder::Oldest,
        )
        .unwrap();
    assert_eq!(oldest[0].session.external_id, "old");
    let relevance = index
        .search(
            "needle".into(),
            "".into(),
            "".into(),
            1,
            SearchOrder::Relevance,
        )
        .unwrap();
    assert_eq!(relevance[0].session.external_id, "old");
}

#[test]
fn many_passages_in_one_session_do_not_hide_other_matching_sessions() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/many.jsonl"),
        &dated_codex("many", "Older repeated work", 1, &vec!["needle"; 1605]),
    );
    let weaker = format!("needle {}", "unrelated ".repeat(100));
    write(
        &dir.path().join("sessions/new.jsonl"),
        &dated_codex("new", "Recent work", 20, &[&weaker]),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    for order in [
        SearchOrder::Newest,
        SearchOrder::Oldest,
        SearchOrder::Relevance,
    ] {
        let hits = index
            .search("needle".into(), "".into(), "".into(), 2, order)
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert_ne!(hits[0].session.key, hits[1].session.key);
        let expected = if order == SearchOrder::Newest {
            "new"
        } else {
            "many"
        };
        assert_eq!(hits[0].session.external_id, expected);
    }
}

#[test]
fn relevance_selects_the_best_passage_while_date_order_uses_session_activity() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/old.jsonl"),
        &dated_codex("old", "Older work", 1, &["No match here.", "needle"]),
    );
    let weaker = format!("needle {}", "unrelated ".repeat(100));
    write(
        &dir.path().join("sessions/new.jsonl"),
        &dated_codex("new", "Recent work", 20, &[&weaker]),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    let hits = index
        .search(
            "needle".into(),
            "".into(),
            "".into(),
            10,
            SearchOrder::Relevance,
        )
        .unwrap();
    assert_eq!(hits[0].session.external_id, "old");
    assert_eq!(hits[0].message_index, 1);
    assert_eq!(hits[0].excerpt, "needle");
    let newest = index
        .search(
            "needle".into(),
            "".into(),
            "".into(),
            10,
            SearchOrder::Newest,
        )
        .unwrap();
    assert_eq!(newest[0].session.external_id, "new");
    assert_eq!(newest[1].message_index, 1);
    let evidence = index
        .evidence("needle".into(), "".into(), "".into())
        .unwrap();
    assert_eq!(evidence[0].session.external_id, "old");
}

#[test]
fn session_order_is_stable_for_equal_dates_and_handles_empty_or_punctuation_queries() {
    let dir = TempDir::new().unwrap();
    for id in ["z", "a", "m"] {
        write(
            &dir.path().join(format!("sessions/{id}.jsonl")),
            &dated_codex(id, "!!!", 20, &["needle"]),
        );
    }
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index.scan(vec![source(dir.path())]).unwrap();
    for query in ["", "  ", "!!!", "needle"] {
        for order in [
            SearchOrder::Newest,
            SearchOrder::Oldest,
            SearchOrder::Relevance,
        ] {
            let hits = index
                .search(query.into(), "".into(), "".into(), 10, order)
                .unwrap();
            assert_eq!(
                hits.iter()
                    .map(|h| h.session.external_id.as_str())
                    .collect::<Vec<_>>(),
                ["a", "m", "z"]
            );
        }
    }
}

#[test]
fn session_orders_preserve_agent_and_project_filters_before_limiting() {
    let dir = TempDir::new().unwrap();
    write(
        &dir.path().join("sessions/new.jsonl"),
        &dated_codex("new", "Other project", 20, &["needle"])
            .replace("/work/example", "/work/other"),
    );
    write(
        &dir.path().join("sessions/old.jsonl"),
        &dated_codex("old", "My project", 1, &["needle"]),
    );
    write(
        &dir.path().join("projects/claude.jsonl"),
        &records(vec![
            serde_json::json!({"type":"user","sessionId":"claude","cwd":"/work/example","timestamp":"2026-10-20T12:00:00Z","message":{"role":"user","content":"needle"}}),
        ]),
    );
    let index = SessionIndex::new(dir.path().join("cache.db").display().to_string()).unwrap();
    index
        .scan(vec![
            source(dir.path()),
            AgentSource {
                agent: "claude".into(),
                root: dir.path().display().to_string(),
            },
        ])
        .unwrap();
    for order in [
        SearchOrder::Newest,
        SearchOrder::Oldest,
        SearchOrder::Relevance,
    ] {
        let hits = index
            .search(
                "needle".into(),
                "codex".into(),
                "/work/example".into(),
                1,
                order,
            )
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].session.external_id, "old");
    }
}
