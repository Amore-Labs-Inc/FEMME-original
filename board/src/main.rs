//! FEMME issues board: one page plus a JSON API over a single file.
//! Listens on localhost only; Caddy in front adds TLS and the password.
//! The worker (worker.sh) talks to the same API on localhost.

use serde_json::{json, Value};
use std::{
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tiny_http::{Header, Method, Request, Response, Server};

const PAGE: &str = include_str!("index.html");
const JSON: &str = "application/json";
const MAX_BODY: u64 = 1 << 20;
const STATUSES: &[&str] = &["open", "working", "paused", "pr", "done", "failed"];
const PATCHABLE: &[&str] = &["repo", "title", "body", "status", "pr_url", "note", "pane", "resume_at"];

type Reply = (u16, String, &'static str);

fn main() {
    let dir = env::var_os("FEMME_STATE").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(env::var_os("HOME").expect("HOME is not set")).join(".local/state/femme")
    });
    fs::create_dir_all(&dir).expect("cannot create the state dir");
    let db = dir.join("issues.json");
    let meta = dir.join("meta.json");

    // A corrupt file must never be silently replaced by an empty board.
    let mut issues: Vec<Value> = match fs::read_to_string(&db) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            panic!("{} is not valid JSON ({e}); fix or move it, refusing to overwrite", db.display())
        }),
        Err(_) => Vec::new(),
    };

    let addr = env::var("FEMME_BOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let server = Server::http(&addr).expect("cannot bind");
    eprintln!("femme-board on http://{addr}, data in {}", db.display());

    for mut req in server.incoming_requests() {
        let (code, body, ctype) = route(&mut req, &mut issues, &db, &meta);
        let header = Header::from_bytes("Content-Type", ctype).unwrap();
        let _ = req.respond(Response::from_string(body).with_status_code(code).with_header(header));
    }
}

fn route(req: &mut Request, issues: &mut Vec<Value>, db: &Path, meta: &Path) -> Reply {
    let url = req.url().split('?').next().unwrap_or("").to_string();
    let parts: Vec<&str> = url.trim_matches('/').split('/').collect();
    let method = req.method().clone();

    match (method, parts.as_slice()) {
        (Method::Get, [""]) => (200, PAGE.into(), "text/html; charset=utf-8"),
        (Method::Get, ["api", "issues"]) => (200, Value::from(issues.clone()).to_string(), JSON),
        (Method::Get, ["api", "meta"]) => (200, fs::read_to_string(meta).unwrap_or_else(|_| "{}".into()), JSON),
        (Method::Post, ["api", "issues"]) => {
            let input = match read_json(req) {
                Ok(v) => v,
                Err(e) => return bad(&e),
            };
            let mut issue = json!({"status": "open", "body": "", "created": now()});
            if let Err(e) = apply(&mut issue, &input) {
                return bad(&e);
            }
            if text(&issue, "repo").is_empty() || text(&issue, "title").is_empty() {
                return bad("repo and title are required");
            }
            issue["id"] = (issues.iter().filter_map(|i| i["id"].as_u64()).max().unwrap_or(0) + 1).into();
            issues.push(issue.clone());
            save(db, issues).map(|_| (201, issue.to_string(), JSON)).unwrap_or_else(|e| e)
        }
        (Method::Patch, ["api", "issues", id]) => {
            let input = match read_json(req) {
                Ok(v) => v,
                Err(e) => return bad(&e),
            };
            let Some(issue) = find(issues, id) else { return not_found() };
            let mut updated = issue.clone();
            if let Err(e) = apply(&mut updated, &input) {
                return bad(&e);
            }
            *issue = updated.clone();
            save(db, issues).map(|_| (200, updated.to_string(), JSON)).unwrap_or_else(|e| e)
        }
        (Method::Delete, ["api", "issues", id]) => {
            let before = issues.len();
            issues.retain(|i| i["id"].as_u64().map(|n| n.to_string()).as_deref() != Some(*id));
            if issues.len() == before {
                return not_found();
            }
            save(db, issues).map(|_| (204, String::new(), JSON)).unwrap_or_else(|e| e)
        }
        _ => not_found(),
    }
}

/// Copies the allowed fields from `input` onto `issue`, validating the ones the worker
/// later passes to git/gh, since anything typed on the board ends up on a command line.
fn apply(issue: &mut Value, input: &Value) -> Result<(), String> {
    let Some(fields) = input.as_object() else { return Err("expected a JSON object".into()) };
    for (k, v) in fields {
        if !PATCHABLE.contains(&k.as_str()) {
            return Err(format!("unknown field {k}"));
        }
        match k.as_str() {
            "repo" if !valid_repo(v.as_str().unwrap_or("")) => return Err("repo must look like owner/name".into()),
            "status" if !STATUSES.contains(&v.as_str().unwrap_or("")) => {
                return Err(format!("status must be one of {}", STATUSES.join(", ")))
            }
            "resume_at" if !v.is_u64() && !v.is_null() => return Err("resume_at must be unix seconds".into()),
            "resume_at" => {}
            _ if !v.is_string() => return Err(format!("{k} must be a string")),
            _ => {}
        }
        issue[k] = if v.is_string() { v.as_str().unwrap().trim().into() } else { v.clone() };
    }
    issue["updated"] = now().into();
    Ok(())
}

fn valid_repo(s: &str) -> bool {
    let ok = |p: &str| !p.is_empty() && !p.starts_with(['.', '-']) && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    matches!(s.split_once('/'), Some((o, n)) if ok(o) && ok(n))
}

fn find<'a>(issues: &'a mut [Value], id: &str) -> Option<&'a mut Value> {
    issues.iter_mut().find(|i| i["id"].as_u64().map(|n| n.to_string()).as_deref() == Some(id))
}

fn read_json(req: &mut Request) -> Result<Value, String> {
    let mut s = String::new();
    req.as_reader().take(MAX_BODY).read_to_string(&mut s).map_err(|e| e.to_string())?;
    serde_json::from_str(&s).map_err(|e| format!("invalid JSON: {e}"))
}

/// Write-then-rename, so a crash mid-write never leaves half a file.
fn save(db: &Path, issues: &[Value]) -> Result<(), Reply> {
    let tmp = db.with_extension("json.tmp");
    let data = serde_json::to_string_pretty(issues).unwrap();
    fs::write(&tmp, data)
        .and_then(|_| fs::rename(&tmp, db))
        .map_err(|e| (500, json!({"error": format!("save failed: {e}")}).to_string(), JSON))
}

fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn bad(msg: &str) -> Reply {
    (400, json!({"error": msg}).to_string(), JSON)
}

fn not_found() -> Reply {
    (404, json!({"error": "not found"}).to_string(), JSON)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_validation_blocks_shell_and_path_tricks() {
        assert!(valid_repo("Darkosxl/FEMME"));
        assert!(valid_repo("a-b/c_d.e"));
        for bad in ["", "x", "a/b/c", "../x", "a/..", "a/.git", "a b/c", "a/$(rm)", "a/b;c", "-o/x", "a/--upload-pack"] {
            assert!(!valid_repo(bad), "{bad} should be rejected");
        }
    }

    #[test]
    fn apply_whitelists_fields_and_statuses() {
        let mut i = json!({"status": "open"});
        assert!(apply(&mut i, &json!({"status": "pr", "pr_url": "https://x"})).is_ok());
        assert_eq!(i["status"], "pr");
        assert!(apply(&mut i, &json!({"status": "hacked"})).is_err());
        assert!(apply(&mut i, &json!({"id": 9})).is_err());
        assert!(apply(&mut i, &json!({"title": 5})).is_err());
        assert!(apply(&mut i, &json!({"resume_at": 1700000000})).is_ok());
        assert!(apply(&mut i, &json!([1])).is_err());
    }
}
