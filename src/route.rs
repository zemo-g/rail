/// Route — capability system for Rail programs.
/// The conductor decides which rooms the program can work in.
/// No --allow flags = pure sandbox. --allow all = full access.

#[derive(Debug, Clone)]
pub struct Route {
    /// Allowed filesystem paths (prefix match)
    pub fs_paths: Vec<String>,
    /// Allowed network hosts (host or host:port)
    pub net_hosts: Vec<String>,
    /// Shell access allowed
    pub shell: bool,
    /// AI/LLM access allowed
    pub ai: bool,
    /// Env var access (specific names, or "*" for all)
    pub env_vars: Vec<String>,
    /// Allow everything
    pub allow_all: bool,
}

impl Route {
    /// Sandbox — no system access at all
    pub fn sandbox() -> Self {
        Route {
            fs_paths: vec![],
            net_hosts: vec![],
            shell: false,
            ai: false,
            env_vars: vec![],
            allow_all: false,
        }
    }

    /// Full access — no restrictions
    pub fn open() -> Self {
        Route {
            fs_paths: vec![],
            net_hosts: vec![],
            shell: true,
            ai: true,
            env_vars: vec!["*".into()],
            allow_all: true,
        }
    }

    /// Parse --allow flags from CLI args.
    /// Returns (Route, remaining_args) with --allow flags consumed.
    pub fn from_args(args: &[String]) -> (Self, Vec<String>) {
        let mut route = Route::sandbox();
        let mut remaining = Vec::new();
        let mut i = 0;

        while i < args.len() {
            if args[i] == "--allow" {
                i += 1;
                if i < args.len() {
                    route.add_allow(&args[i]);
                }
            } else if args[i].starts_with("--allow=") {
                let val = &args[i]["--allow=".len()..];
                route.add_allow(val);
            } else if args[i] == "--sandbox" {
                // Explicit sandbox — already default, but clear any prior allows
                route = Route::sandbox();
            } else if args[i] == "--open" {
                route = Route::open();
            } else {
                remaining.push(args[i].clone());
            }
            i += 1;
        }

        (route, remaining)
    }

    fn add_allow(&mut self, spec: &str) {
        if spec == "all" {
            *self = Route::open();
            return;
        }

        if let Some(path) = spec.strip_prefix("fs:") {
            // Normalize: ensure trailing slash for directory matching
            let path = if path.ends_with('/') || path.ends_with('*') {
                path.to_string()
            } else {
                format!("{}/", path)
            };
            self.fs_paths.push(path);
        } else if let Some(host) = spec.strip_prefix("net:") {
            self.net_hosts.push(host.to_string());
        } else if spec == "shell" {
            self.shell = true;
        } else if spec == "ai" {
            self.ai = true;
        } else if let Some(var) = spec.strip_prefix("env:") {
            self.env_vars.push(var.to_string());
        } else if spec == "env" {
            self.env_vars.push("*".into());
        } else {
            eprintln!("warning: unknown --allow spec: {}", spec);
        }
    }

    // ---- Capability checks ----

    pub fn check_fs(&self, path: &str) -> Result<(), String> {
        if self.allow_all {
            return Ok(());
        }
        if self.fs_paths.is_empty() {
            return Err(format!(
                "filesystem access denied: no --allow fs:<path> specified\n  \
                 tried to access: {}\n  \
                 hint: rail run file.rail --allow fs:{}",
                path,
                std::path::Path::new(path)
                    .parent()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_else(|| "/".into())
            ));
        }

        // Resolve to absolute path for matching
        let abs = if path.starts_with('/') {
            path.to_string()
        } else {
            std::env::current_dir()
                .map(|d| d.join(path).to_string_lossy().to_string())
                .unwrap_or_else(|_| path.to_string())
        };

        for allowed in &self.fs_paths {
            let allowed_clean = allowed.trim_end_matches('/');
            if abs.starts_with(allowed_clean) {
                return Ok(());
            }
        }

        Err(format!(
            "filesystem access denied: {} is outside allowed paths\n  \
             allowed: {:?}",
            path, self.fs_paths
        ))
    }

    pub fn check_net(&self, url: &str) -> Result<(), String> {
        if self.allow_all {
            return Ok(());
        }
        if self.net_hosts.is_empty() {
            return Err(format!(
                "network access denied: no --allow net:<host> specified\n  \
                 tried to access: {}\n  \
                 hint: rail run file.rail --allow net:localhost",
                url
            ));
        }

        // Extract host from URL
        let host = extract_host(url);

        for allowed in &self.net_hosts {
            if allowed == "*" || allowed == &host {
                return Ok(());
            }
            // Allow "localhost" to match "localhost:8080"
            if host.starts_with(&format!("{}:", allowed)) {
                return Ok(());
            }
            // Allow "localhost:8080" to match exactly
            if allowed == &host {
                return Ok(());
            }
        }

        Err(format!(
            "network access denied: {} is not in allowed hosts\n  \
             allowed: {:?}",
            host, self.net_hosts
        ))
    }

    pub fn check_shell(&self) -> Result<(), String> {
        if self.allow_all || self.shell {
            return Ok(());
        }
        Err(
            "shell access denied: --allow shell not specified\n  \
             hint: rail run file.rail --allow shell"
                .into(),
        )
    }

    pub fn check_ai(&self) -> Result<(), String> {
        if self.allow_all || self.ai {
            return Ok(());
        }
        Err(
            "AI/LLM access denied: --allow ai not specified\n  \
             hint: rail run file.rail --allow ai"
                .into(),
        )
    }

    pub fn check_env(&self, var_name: &str) -> Result<(), String> {
        if self.allow_all {
            return Ok(());
        }
        for allowed in &self.env_vars {
            if allowed == "*" || allowed == var_name {
                return Ok(());
            }
        }
        Err(format!(
            "env access denied: {} not in allowed env vars\n  \
             hint: rail run file.rail --allow env:{}",
            var_name, var_name
        ))
    }

    /// Display summary of what this route allows
    pub fn describe(&self) -> String {
        if self.allow_all {
            return "open (full access)".into();
        }

        let mut parts = Vec::new();
        if !self.fs_paths.is_empty() {
            parts.push(format!("fs:{}", self.fs_paths.join(",")));
        }
        if !self.net_hosts.is_empty() {
            parts.push(format!("net:{}", self.net_hosts.join(",")));
        }
        if self.shell {
            parts.push("shell".into());
        }
        if self.ai {
            parts.push("ai".into());
        }
        if !self.env_vars.is_empty() {
            parts.push(format!("env:{}", self.env_vars.join(",")));
        }

        if parts.is_empty() {
            "sandbox (no system access)".into()
        } else {
            parts.join(" + ")
        }
    }
}

fn extract_host(url: &str) -> String {
    let url = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://")).unwrap_or(url);
    // Take everything up to the first /
    let host = url.split('/').next().unwrap_or(url);
    host.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sandbox_denies_everything() {
        let r = Route::sandbox();
        assert!(r.check_fs("/tmp/foo").is_err());
        assert!(r.check_net("http://example.com").is_err());
        assert!(r.check_shell().is_err());
        assert!(r.check_ai().is_err());
        assert!(r.check_env("HOME").is_err());
    }

    #[test]
    fn test_open_allows_everything() {
        let r = Route::open();
        assert!(r.check_fs("/tmp/foo").is_ok());
        assert!(r.check_net("http://example.com").is_ok());
        assert!(r.check_shell().is_ok());
        assert!(r.check_ai().is_ok());
        assert!(r.check_env("HOME").is_ok());
    }

    #[test]
    fn test_fs_path_scoping() {
        let args = vec!["--allow".into(), "fs:/Users/me/projects".into()];
        let (r, _) = Route::from_args(&args);
        assert!(r.check_fs("/Users/me/projects/foo.txt").is_ok());
        assert!(r.check_fs("/Users/me/projects/sub/bar.txt").is_ok());
        assert!(r.check_fs("/etc/passwd").is_err());
        assert!(r.check_fs("/Users/me/other/file.txt").is_err());
    }

    #[test]
    fn test_net_host_scoping() {
        let args = vec!["--allow".into(), "net:localhost".into()];
        let (r, _) = Route::from_args(&args);
        assert!(r.check_net("http://localhost:8080/v1/models").is_ok());
        assert!(r.check_net("http://localhost/foo").is_ok());
        assert!(r.check_net("http://example.com/api").is_err());
    }

    #[test]
    fn test_selective_capabilities() {
        let args = vec![
            "--allow".into(), "shell".into(),
            "--allow".into(), "ai".into(),
        ];
        let (r, _) = Route::from_args(&args);
        assert!(r.check_shell().is_ok());
        assert!(r.check_ai().is_ok());
        assert!(r.check_fs("/tmp/foo").is_err());
        assert!(r.check_net("http://example.com").is_err());
    }

    #[test]
    fn test_remaining_args() {
        let args = vec![
            "run".into(), "file.rail".into(),
            "--allow".into(), "shell".into(),
            "--allow".into(), "fs:/tmp".into(),
        ];
        let (r, remaining) = Route::from_args(&args);
        assert_eq!(remaining, vec!["run", "file.rail"]);
        assert!(r.check_shell().is_ok());
        assert!(r.check_fs("/tmp/foo.txt").is_ok());
    }

    #[test]
    fn test_allow_all() {
        let args = vec!["--allow".into(), "all".into()];
        let (r, _) = Route::from_args(&args);
        assert!(r.allow_all);
        assert!(r.check_fs("/anything").is_ok());
        assert!(r.check_shell().is_ok());
    }

    #[test]
    fn test_env_scoping() {
        let args = vec!["--allow".into(), "env:HOME".into()];
        let (r, _) = Route::from_args(&args);
        assert!(r.check_env("HOME").is_ok());
        assert!(r.check_env("SECRET_KEY").is_err());
    }

    #[test]
    fn test_describe() {
        assert_eq!(Route::sandbox().describe(), "sandbox (no system access)");
        assert_eq!(Route::open().describe(), "open (full access)");
    }
}
