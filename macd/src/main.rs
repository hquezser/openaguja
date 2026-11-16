//! openaguja-macd — micro-daemon HTTP de commandes pour OpenAguja.
//!
//! L'iPhone (app OpenAguja) envoie `POST /cmd/<action>` avec un jeton
//! Bearer quand la montre déclenche une action routée « Mac (HTTP local) ».
//! Chaque commande est un script shell défini dans le fichier TOML de
//! configuration — les clés de `[commands]` portent le nom de l'action
//! (`play`, `find_phone`, `sos`…).
//!
//! Endpoints :
//!   GET  /health      → {"ok":true} (sans auth, pour les tests)
//!   GET  /cmd         → liste des commandes (Bearer requis)
//!   POST /cmd/{name}  → exécute la commande (Bearer requis)
//!
//! Usage : `openaguja-macd [--config ~/.config/openaguja-macd/config.toml]`
//! Le jeton peut aussi venir de `OPENAGUJA_DAEMON_TOKEN` (prioritaire).

use axum::{
    Router,
    extract::{Path, Request, State},
    http::{HeaderMap, StatusCode, header::AUTHORIZATION},
    middleware::{self, Next},
    response::{Json, Response},
    routing::get,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::process::Command;
use tracing::{info, warn};

#[derive(Debug, Deserialize)]
struct Config {
    /// Adresse d'écoute — 0.0.0.0 pour être joignable depuis l'iPhone.
    #[serde(default = "default_bind")]
    bind: String,
    /// Jeton Bearer — surchargeable via OPENAGUJA_DAEMON_TOKEN.
    token: Option<String>,
    /// Délai max d'exécution par défaut (secondes).
    #[serde(default = "default_timeout")]
    timeout_secs: u64,
    #[serde(default)]
    commands: HashMap<String, CommandSpec>,
}

fn default_bind() -> String {
    "0.0.0.0:9876".into()
}
fn default_timeout() -> u64 {
    10
}

/// Commande : chaîne shell simple ou table `{ run, timeout_secs? }`.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum CommandSpec {
    Shell(String),
    Detailed {
        run: String,
        timeout_secs: Option<u64>,
    },
}

impl CommandSpec {
    fn run(&self) -> &str {
        match self {
            Self::Shell(cmd) => cmd,
            Self::Detailed { run, .. } => run,
        }
    }
    fn timeout(&self, default: Duration) -> Duration {
        let secs = match self {
            Self::Shell(_) => default.as_secs(),
            Self::Detailed { timeout_secs, .. } => {
                timeout_secs.unwrap_or_else(|| default.as_secs())
            }
        };
        Duration::from_secs(secs)
    }
}

struct App {
    token: String,
    timeout: Duration,
    commands: HashMap<String, CommandSpec>,
}

type Shared = Arc<App>;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "openaguja_macd=info".into()),
        )
        .init();

    let config_path = config_path();
    let text = std::fs::read_to_string(&config_path).unwrap_or_else(|e| {
        eprintln!(
            "openaguja-macd : impossible de lire {} : {e}",
            config_path.display()
        );
        eprintln!("Copie macd/config.example.toml vers ce chemin et adapte-le.");
        std::process::exit(2);
    });
    let mut config: Config = toml::from_str(&text).unwrap_or_else(|e| {
        eprintln!(
            "openaguja-macd : TOML invalide dans {} : {e}",
            config_path.display()
        );
        std::process::exit(2);
    });
    // La variable d'environnement prime sur le fichier (secrets hors config).
    if let Ok(token) = std::env::var("OPENAGUJA_DAEMON_TOKEN") {
        config.token = Some(token);
    }

    let app = Shared::new(App {
        token: config.token.unwrap_or_default(),
        timeout: Duration::from_secs(config.timeout_secs),
        commands: config.commands,
    });
    if app.token.is_empty() {
        warn!("aucun jeton configuré : les POST /cmd/* seront refusés (503)");
    }
    info!(commands = app.commands.len(), "commandes chargées");

    let addr: SocketAddr = app_addr(&config.bind);
    let router = Router::new()
        .route("/health", get(health))
        .route("/cmd", get(list_commands))
        .route("/cmd/{name}", axum::routing::post(run_command))
        .layer(middleware::from_fn(log_request))
        .with_state(app);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .unwrap_or_else(|e| {
            eprintln!("openaguja-macd : écoute {addr} impossible : {e}");
            std::process::exit(2);
        });
    info!(%addr, "openaguja-macd en écoute");
    axum::serve(listener, router).await.expect("serveur");
}

fn config_path() -> PathBuf {
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--config")
        && let Some(path) = args.get(i + 1)
    {
        return PathBuf::from(path);
    }
    dirs_home().join(".config/openaguja-macd/config.toml")
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/"))
}

fn app_addr(bind: &str) -> SocketAddr {
    bind.parse().unwrap_or_else(|_| {
        eprintln!("openaguja-macd : adresse « {bind} » invalide");
        std::process::exit(2);
    })
}

// MARK: - Handlers

/// Journalise chaque requête avec son statut — sans ça les rejets
/// (401 jeton, 404 commande inconnue) sont invisibles.
async fn log_request(req: Request, next: Next) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let response = next.run(req).await;
    let status = response.status();
    if status.is_success() || status.is_redirection() {
        info!(%method, %path, %status, "requête");
    } else {
        warn!(%method, %path, %status, "requête refusée");
    }
    response
}

async fn health(State(app): State<Shared>) -> Json<Value> {
    let mut names: Vec<&String> = app.commands.keys().collect();
    names.sort();
    Json(json!({ "ok": true, "service": "openaguja-macd", "commands": names }))
}

async fn list_commands(
    State(app): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    authorized(&app, &headers)?;
    let mut names: Vec<&String> = app.commands.keys().collect();
    names.sort();
    Ok(Json(json!({ "commands": names })))
}

async fn run_command(
    State(app): State<Shared>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    authorized(&app, &headers)?;
    let Some(spec) = app.commands.get(&name) else {
        return Err(err(
            StatusCode::NOT_FOUND,
            format!("commande « {name} » inconnue"),
        ));
    };
    let timeout = spec.timeout(app.timeout);
    let started = Instant::now();
    info!(command = %name, run = spec.run(), "exécution");

    let child = Command::new("/bin/sh")
        .arg("-c")
        .arg(spec.run())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("spawn : {e}")))?;

    let result = tokio::time::timeout(timeout, child.wait_with_output()).await;
    let output = match result {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            return Err(err(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("exec : {e}"),
            ));
        }
        Err(_) => {
            warn!(command = %name, "timeout — kill");
            return Err(err(
                StatusCode::GATEWAY_TIMEOUT,
                format!("timeout {} s", timeout.as_secs()),
            ));
        }
    };

    let stdout = truncate(&output.stdout);
    let stderr = truncate(&output.stderr);
    let code = output.status.code().unwrap_or(-1);
    let duration_ms = started.elapsed().as_millis() as u64;
    info!(command = %name, code, duration_ms, "terminé");

    Ok(Json(json!({
        "ok": output.status.success(),
        "command": name,
        "exit": code,
        "duration_ms": duration_ms,
        "stdout": stdout,
        "stderr": stderr,
    })))
}

// MARK: - Auth

fn authorized(app: &App, headers: &HeaderMap) -> Result<(), (StatusCode, Json<Value>)> {
    if app.token.is_empty() {
        return Err(err(
            StatusCode::SERVICE_UNAVAILABLE,
            "aucun jeton configuré côté daemon",
        ));
    }
    let bearer = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    match bearer {
        Some(given) if constant_time_eq(given.as_bytes(), app.token.as_bytes()) => Ok(()),
        _ => {
            warn!("autorisation Bearer refusée");
            Err(err(StatusCode::UNAUTHORIZED, "jeton Bearer invalide"))
        }
    }
}

/// Comparaison à temps constant (évite les fuites par timing sur le LAN).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn err(status: StatusCode, message: impl Into<String>) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({ "ok": false, "error": message.into() })),
    )
}

fn truncate(bytes: &[u8]) -> String {
    const MAX: usize = 8192;
    let slice = if bytes.len() > MAX {
        &bytes[..MAX]
    } else {
        bytes
    };
    String::from_utf8_lossy(slice).trim().to_string()
}
