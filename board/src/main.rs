//! FEMME issues board: one page plus a JSON API over a single file.
//! Sign-in: a magic link to the one allowed address (BOARD_EMAIL), sent through Resend,
//! then a 7-day cookie. Listens on localhost; Caddy in front adds TLS.
//! The worker (worker.sh) uses the same API with the bearer token in <state>/worker.token.

use serde_json::{json, Value};
use std::{
    collections::HashMap,
    env, fs,
    io::{Cursor, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tiny_http::{Header, Method, Request, Response, Server};

const PAGE: &str = include_str!("index.html");
const LOGIN: &str = include_str!("login.html");
const MAX_BODY: u64 = 1 << 20;
const SESSION_SECS: u64 = 7 * 86400;
const LINK_SECS: u64 = 15 * 60;
const STATUSES: &[&str] = &["open", "working", "waiting", "paused", "pr", "done", "failed"];
// Keys the chat panel may press in an agent's terminal (answering Claude's choice prompts).
const KEYS: &[&str] = &["enter", "esc", "up", "down", "tab", "1", "2", "3", "4"];
const PATCHABLE: &[&str] = &["repo", "title", "body", "status", "pr_url", "note", "pane", "resume_at"];

type Resp = Response<Cursor<Vec<u8>>>;

struct App {
    issues: Vec<Value>,
    sessions: HashMap<String, u64>, // token -> expiry; persisted so restarts don't log you out
    links: HashMap<String, u64>,    // token -> expiry; memory only, 15 minutes is short anyway
    last_mail: u64,
    worker_token: String,
    db: PathBuf,
    sessions_path: PathBuf,
    meta: PathBuf,
    home: PathBuf,
    email: String,
    url: String,
    resend_key: String,
    from: String,
}

fn main() {
    let var = |k: &str| env::var(k).unwrap_or_default();
    let dir = env::var_os("FEMME_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(var("HOME")).join(".local/state/femme"));
    fs::create_dir_all(&dir).expect("cannot create the state dir");

    let mut app = App {
        issues: load(&dir.join("issues.json")).unwrap_or_default(),
        sessions: load(&dir.join("sessions.json")).unwrap_or_default(),
        links: HashMap::new(),
        last_mail: 0,
        worker_token: worker_token(&dir.join("worker.token")),
        db: dir.join("issues.json"),
        sessions_path: dir.join("sessions.json"),
        meta: dir.join("meta.json"),
        home: PathBuf::from(var("HOME")),
        email: var("BOARD_EMAIL").trim().to_lowercase(),
        url: var("BOARD_URL").trim_end_matches('/').into(),
        resend_key: var("RESEND_API_KEY"),
        from: var("MAIL_FROM"),
    };
    assert!(!app.email.is_empty() && !app.url.is_empty(), "BOARD_EMAIL and BOARD_URL must be set");
    if app.resend_key.is_empty() {
        eprintln!("RESEND_API_KEY is not set: sign-in links are printed here instead of emailed");
    }

    let addr = env::var("FEMME_BOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let server = Server::http(&addr).expect("cannot bind");
    eprintln!("femme-board on http://{addr} for {}, data in {}", app.url, dir.display());
    for mut req in server.incoming_requests() {
        let resp = route(&mut req, &mut app);
        let _ = req.respond(resp);
    }
}

fn route(req: &mut Request, app: &mut App) -> Resp {
    let url = req.url().split('?').next().unwrap_or("").to_string();
    let parts: Vec<&str> = url.trim_matches('/').split('/').collect();
    let method = req.method().clone();

    // Bodies must be JSON: a cross-site form can't send that without a CORS preflight,
    // which this server never answers, so this doubles as CSRF protection.
    if matches!(method, Method::Post | Method::Patch) && !header(req, "Content-Type").starts_with("application/json") {
        return err(415, "expected application/json");
    }

    // Public routes: the sign-in flow.
    match (&method, parts.as_slice()) {
        (Method::Get, ["login"]) | (Method::Get, ["magic", _]) => return html(LOGIN),
        (Method::Post, ["api", "login"]) => {
            let input = read_json(req).unwrap_or_default();
            let asked = input["email"].as_str().unwrap_or("").trim().to_lowercase();
            // Same answer either way, so the page never reveals which address is allowed.
            if asked == app.email && now() >= app.last_mail + 60 {
                app.last_mail = now();
                let token = random_hex();
                app.links.retain(|_, exp| *exp > now());
                app.links.insert(token.clone(), now() + LINK_SECS);
                if let Err(e) = send_link(app, &format!("{}/magic/{token}", app.url)) {
                    eprintln!("sign-in mail failed: {e}");
                }
            }
            return ok(json!({"ok": true}));
        }
        (Method::Post, ["api", "magic"]) => {
            let input = read_json(req).unwrap_or_default();
            let token = input["token"].as_str().unwrap_or("");
            match app.links.remove(token) {
                Some(exp) if exp > now() => {
                    let session = random_hex();
                    app.sessions.retain(|_, exp| *exp > now());
                    app.sessions.insert(session.clone(), now() + SESSION_SECS);
                    if let Err(e) = write_private(&app.sessions_path, &json!(app.sessions).to_string()) {
                        return e;
                    }
                    return ok(json!({"ok": true})).with_header(cookie(app, &session, SESSION_SECS));
                }
                _ => return err(400, "this link has expired or was already used; ask for a new one"),
            }
        }
        _ => {}
    }

    if !signed_in(req, app) {
        return match parts.as_slice() {
            ["api", ..] => err(401, "sign in first"),
            _ => redirect("/login"),
        };
    }

    match (method, parts.as_slice()) {
        (Method::Get, [""]) => html(PAGE),
        (Method::Post, ["api", "logout"]) => {
            let token = session_cookie(req).unwrap_or_default();
            app.sessions.remove(&token);
            let _ = write_private(&app.sessions_path, &json!(app.sessions).to_string());
            ok(json!({"ok": true})).with_header(cookie(app, "", 0))
        }
        (Method::Get, ["api", "issues"]) => ok(Value::from(app.issues.clone())),
        (Method::Get, ["api", "meta"]) => {
            ok(fs::read_to_string(&app.meta).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!({})))
        }
        (Method::Post, ["api", "issues"]) => {
            let Ok(input) = read_json(req) else { return err(400, "invalid JSON") };
            let mut issue = json!({"status": "open", "body": "", "created": now()});
            if let Err(e) = apply(&mut issue, &input) {
                return err(400, &e);
            }
            if text(&issue, "repo").is_empty() || text(&issue, "title").is_empty() {
                return err(400, "repo and title are required");
            }
            issue["id"] = (app.issues.iter().filter_map(|i| i["id"].as_u64()).max().unwrap_or(0) + 1).into();
            app.issues.push(issue.clone());
            save_issues(app).unwrap_or_else(|| ok(issue).with_status_code(201))
        }
        (Method::Patch, ["api", "issues", id]) => {
            let Ok(input) = read_json(req) else { return err(400, "invalid JSON") };
            let Some(issue) = app.issues.iter_mut().find(|i| id_matches(i, id)) else { return err(404, "not found") };
            let mut updated = issue.clone();
            if let Err(e) = apply(&mut updated, &input) {
                return err(400, &e);
            }
            *issue = updated.clone();
            save_issues(app).unwrap_or_else(|| ok(updated))
        }
        // Terminals on this box (herdr workspaces): list, open, close, read, type into.
        // Issue chat uses the same routes through the issue's pane. herdr runs as this same
        // user; arguments go straight to it, never through a shell.
        (Method::Get, ["api", "terminals"]) => match herdr(&["api", "snapshot"]) {
            Ok(out) => ok(terminals(&out, &app.home)),
            Err(e) => err(502, &e),
        },
        (Method::Post, ["api", "terminals"]) => {
            let Ok(input) = read_json(req) else { return err(400, "invalid JSON") };
            let Some(cwd) = home_dir(&app.home, input["cwd"].as_str().unwrap_or("")) else {
                return err(400, "folder must exist inside your home directory")
            };
            let label = input["label"].as_str().unwrap_or("").trim().chars().take(60).collect::<String>();
            let mut args = vec!["workspace", "create", "--cwd", &cwd, "--no-focus"];
            if !label.is_empty() {
                args.extend(["--label", &label]);
            }
            let pane = match herdr(&args).ok().and_then(|o| serde_json::from_str::<Value>(&o).ok()) {
                Some(v) => text(&v["result"]["root_pane"], "pane_id").to_string(),
                None => return err(502, "herdr could not open a workspace"),
            };
            if let Some(kind) = input["agent"].as_str().filter(|k| ["claude", "codex", "pi"].contains(k)) {
                wait_for_shell(&pane);
                let name = format!("t-{}", &random_hex()[..8]);
                let _ = herdr(&["agent", "start", &name, "--kind", kind, "--pane", &pane, "--timeout", "60000"]);
                let _ = herdr(&["agent", "rename", &pane, "--clear"]);
            }
            ok(json!({"pane_id": pane}))
        }
        (Method::Delete, ["api", "terminals", ws]) if valid_id(ws, false) => {
            herdr(&["workspace", "close", ws]).map(|_| ok(json!({"ok": true}))).unwrap_or_else(|e| err(502, &e))
        }
        (Method::Get, ["api", "terminals", pane, "screen"]) if valid_id(pane, true) => {
            match herdr(&["pane", "read", pane, "--source", "recent-unwrapped", "--lines", "150"]) {
                Ok(screen) => ok(json!({"screen": screen, "status": pane_status(pane)})),
                Err(e) => err(404, &e),
            }
        }
        (Method::Post, ["api", "terminals", pane, "say"]) if valid_id(pane, true) => {
            let Ok(input) = read_json(req) else { return err(400, "invalid JSON") };
            let text = input["text"].as_str().unwrap_or("").trim();
            if text.is_empty() {
                return err(400, "say something");
            }
            // An agent gets a prompt; a plain shell gets the line as a command.
            let sent = match pane_status(pane) {
                Some(_) => herdr(&["agent", "prompt", pane, text]),
                None => herdr(&["pane", "run", pane, text]),
            };
            match sent {
                Ok(_) => ok(json!({"ok": true})),
                Err(e) if e.contains("agent_blocked") => {
                    err(409, "the agent is waiting on a choice: answer with the buttons (1, 2, Enter, Esc)")
                }
                Err(e) => err(502, &e),
            }
        }
        (Method::Post, ["api", "terminals", pane, "keys"]) if valid_id(pane, true) => {
            let Ok(input) = read_json(req) else { return err(400, "invalid JSON") };
            let key = input["key"].as_str().unwrap_or("");
            if !KEYS.contains(&key) {
                return err(400, &format!("key must be one of {}", KEYS.join(", ")));
            }
            herdr(&["pane", "send-keys", pane, key]).map(|_| ok(json!({"ok": true}))).unwrap_or_else(|e| err(502, &e))
        }
        (Method::Delete, ["api", "issues", id]) => {
            let before = app.issues.len();
            app.issues.retain(|i| !id_matches(i, id));
            if app.issues.len() == before {
                return err(404, "not found");
            }
            save_issues(app).unwrap_or_else(|| ok(json!({"ok": true})))
        }
        _ => err(404, "not found"),
    }
}

fn signed_in(req: &Request, app: &App) -> bool {
    if header(req, "Authorization") == format!("Bearer {}", app.worker_token) {
        return true;
    }
    session_cookie(req).and_then(|t| app.sessions.get(&t).copied()).is_some_and(|exp| exp > now())
}

fn session_cookie(req: &Request) -> Option<String> {
    header(req, "Cookie")
        .split(';')
        .find_map(|c| c.trim().strip_prefix("femme_session=").map(String::from))
        .filter(|t| !t.is_empty())
}

fn cookie(app: &App, value: &str, max_age: u64) -> Header {
    // Secure only on https, so the board still works over plain http on localhost.
    let secure = if app.url.starts_with("https://") { "; Secure" } else { "" };
    let c = format!("femme_session={value}; HttpOnly; SameSite=Lax; Path=/; Max-Age={max_age}{secure}");
    Header::from_bytes("Set-Cookie", c).unwrap()
}

fn send_link(app: &App, link: &str) -> Result<(), String> {
    if app.resend_key.is_empty() {
        eprintln!("sign-in link: {link}");
        return Ok(());
    }
    let body = json!({
        "from": app.from,
        "to": [app.email],
        "subject": "Sign in to FEMME",
        "text": format!("Sign in to your FEMME board (valid 15 minutes, once):\n\n{link}\n"),
        "html": format!(r#"<p>Sign in to your FEMME board (valid 15 minutes, once):</p><p><a href="{link}">Sign in to FEMME</a></p>"#),
    });
    ureq::post("https://api.resend.com/emails")
        .set("Authorization", &format!("Bearer {}", app.resend_key))
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
        .map(|_| ())
        .map_err(|e| e.to_string())
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

/// herdr ids: workspaces look like `w9`, panes like `w9:p1`. Anything else never reaches herdr.
fn valid_id(id: &str, pane: bool) -> bool {
    let word = |w: &str| w.len() > 1 && w.len() < 16 && w.chars().all(|c| c.is_ascii_alphanumeric());
    match id.split_once(':') {
        Some((ws, p)) => pane && ws.starts_with('w') && word(ws) && p.starts_with('p') && word(p),
        None => !pane && id.starts_with('w') && word(id),
    }
}

/// The agent status of a pane, or None if it is a plain shell.
fn pane_status(pane: &str) -> Option<String> {
    let v: Value = serde_json::from_str(&herdr(&["agent", "get", pane]).ok()?).ok()?;
    v["result"]["agent"]["agent_status"].as_str().map(String::from)
}

fn wait_for_shell(pane: &str) {
    for _ in 0..30 {
        let ready = herdr(&["pane", "process-info", "--pane", pane])
            .ok()
            .and_then(|o| serde_json::from_str::<Value>(&o).ok())
            .is_some_and(|v| v["result"]["process_info"]["foreground_processes"].as_array().is_some_and(|a| a.len() == 1));
        if ready {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}

/// Workspaces with their panes, plus folders you can open a new terminal in.
fn terminals(snapshot: &str, home: &Path) -> Value {
    let snap: Value = serde_json::from_str(snapshot).unwrap_or_default();
    let snap = &snap["result"]["snapshot"];
    let panes = snap["panes"].as_array().cloned().unwrap_or_default();
    let workspaces: Vec<Value> = snap["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|w| {
            let id = text(&w, "workspace_id").to_string();
            let ps: Vec<Value> = panes
                .iter()
                .filter(|p| text(p, "workspace_id") == id)
                .map(|p| {
                    json!({"pane_id": p["pane_id"], "agent": p["agent"], "status": p["agent_status"],
                           "cwd": p["foreground_cwd"].as_str().or(p["cwd"].as_str()), "title": p["terminal_title_stripped"]})
                })
                .collect();
            json!({"workspace_id": id, "label": w["label"], "status": w["agent_status"], "panes": ps})
        })
        .collect();
    let mut folders = vec![home.display().to_string()];
    for base in ["Documents", "femme-work"] {
        for d in fs::read_dir(home.join(base)).into_iter().flatten().flatten() {
            if d.path().is_dir() {
                folders.push(d.path().display().to_string());
                if base == "Documents" {
                    for sub in fs::read_dir(d.path()).into_iter().flatten().flatten() {
                        if sub.path().is_dir() && !sub.file_name().to_string_lossy().starts_with('.') {
                            folders.push(sub.path().display().to_string());
                        }
                    }
                }
            }
        }
    }
    folders.sort();
    json!({"workspaces": workspaces, "folders": folders})
}

/// An existing directory inside home, resolved (no `..` escapes, no symlinks out).
fn home_dir(home: &Path, dir: &str) -> Option<String> {
    let dir = if dir.trim().is_empty() { home.to_path_buf() } else { PathBuf::from(dir.trim()) };
    let real = fs::canonicalize(dir).ok()?;
    (real.is_dir() && real.starts_with(fs::canonicalize(home).ok()?)).then(|| real.display().to_string())
}

fn herdr(args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new("herdr").args(args).output().map_err(|e| format!("herdr: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn valid_repo(s: &str) -> bool {
    let ok = |p: &str| {
        !p.is_empty() && !p.starts_with(['.', '-']) && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    matches!(s.split_once('/'), Some((o, n)) if ok(o) && ok(n))
}

fn id_matches(issue: &Value, id: &str) -> bool {
    issue["id"].as_u64().map(|n| n.to_string()).as_deref() == Some(id)
}

/// A corrupt file must never be silently replaced by an empty one.
fn load<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let s = fs::read_to_string(path).ok()?;
    Some(serde_json::from_str(&s).unwrap_or_else(|e| {
        panic!("{} is not valid JSON ({e}); fix or move it, refusing to overwrite", path.display())
    }))
}

fn save_issues(app: &App) -> Option<Resp> {
    write_private(&app.db, &serde_json::to_string_pretty(&app.issues).unwrap()).err()
}

/// Write-then-rename (a crash never leaves half a file), readable only by this user.
fn write_private(path: &Path, data: &str) -> Result<(), Resp> {
    let tmp = path.with_extension("tmp");
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(data.as_bytes()))
        .and_then(|_| fs::rename(&tmp, path))
        .map_err(|e| err(500, &format!("save failed: {e}")))
}

fn worker_token(path: &Path) -> String {
    if let Ok(t) = fs::read_to_string(path) {
        return t.trim().into();
    }
    let t = random_hex();
    write_private(path, &t).unwrap_or_else(|_| panic!("cannot write {}", path.display()));
    t
}

fn random_hex() -> String {
    let mut b = [0u8; 32];
    fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).expect("no /dev/urandom");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn read_json(req: &mut Request) -> Result<Value, String> {
    let mut s = String::new();
    req.as_reader().take(MAX_BODY).read_to_string(&mut s).map_err(|e| e.to_string())?;
    serde_json::from_str(&s).map_err(|e| format!("invalid JSON: {e}"))
}

fn header(req: &Request, name: &'static str) -> String {
    req.headers().iter().find(|h| h.field.equiv(name)).map(|h| h.value.to_string()).unwrap_or_default()
}

fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn ok(v: Value) -> Resp {
    with_type(Response::from_string(v.to_string()), "application/json")
}

fn err(code: u16, msg: &str) -> Resp {
    ok(json!({"error": msg})).with_status_code(code)
}

fn html(page: &str) -> Resp {
    with_type(Response::from_string(page), "text/html; charset=utf-8")
}

fn redirect(to: &str) -> Resp {
    Response::from_string("").with_status_code(302).with_header(Header::from_bytes("Location", to).unwrap())
}

fn with_type(r: Resp, ctype: &str) -> Resp {
    r.with_header(Header::from_bytes("Content-Type", ctype).unwrap())
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
    fn herdr_ids_are_strict() {
        assert!(valid_id("w9", false) && valid_id("wC", false) && valid_id("w9:p1", true) && valid_id("wA:p12", true));
        for bad in ["", "w", "9", "w9;ls", "w9 p1", "w9:p1", "../w9", "-w9", "w9:x1"] {
            assert!(!valid_id(bad, false), "{bad} is not a workspace");
        }
        for bad in ["w9", "w9:", ":p1", "w9:p1;rm", "w9:p1:p2", "w9:p", "x9:p1"] {
            assert!(!valid_id(bad, true), "{bad} is not a pane");
        }
    }

    #[test]
    fn home_dir_stays_inside_home() {
        let home = env::temp_dir().join(format!("femme-home-{}", std::process::id()));
        fs::create_dir_all(home.join("proj")).unwrap();
        assert!(home_dir(&home, "").is_some());
        assert!(home_dir(&home, home.join("proj").to_str().unwrap()).is_some());
        assert!(home_dir(&home, home.join("proj/../..").to_str().unwrap()).is_none());
        assert!(home_dir(&home, "/etc").is_none());
        assert!(home_dir(&home, home.join("missing").to_str().unwrap()).is_none());
        fs::remove_dir_all(&home).unwrap();
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
