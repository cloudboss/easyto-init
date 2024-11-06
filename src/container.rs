use std::collections::HashMap;
use std::time;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct ConfigFile {
    pub architecture: String,
    pub author: Option<String>,
    pub container: Option<String>,
    pub created: Option<DateTime<Utc>>,
    pub docker_version: Option<String>,
    pub history: Vec<History>,
    pub os: String,
    pub rootfs: RootFS,
    pub config: Option<Config>,
    #[serde(rename = "os.version")]
    pub os_version: Option<String>,
    pub variant: Option<String>,
    #[serde(rename = "os.features")]
    pub os_features: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct History {
    pub author: Option<String>,
    pub created: Option<DateTime<Utc>>,
    pub created_by: Option<String>,
    pub comment: Option<String>,
    pub empty_layer: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct RootFS {
    #[serde(rename = "type")]
    pub typ: String,
    pub diff_ids: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Empty {}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Config {
    #[serde(rename = "AttachStderr")]
    pub attach_stderr: Option<bool>,
    #[serde(rename = "AttachStdin")]
    pub attach_stdin: Option<bool>,
    #[serde(rename = "AttachStdout")]
    pub attach_stdout: Option<bool>,
    #[serde(rename = "Cmd")]
    pub cmd: Option<Vec<String>>,
    #[serde(rename = "Healthcheck")]
    pub healthcheck: Option<HealthCheck>,
    #[serde(rename = "Domainname")]
    pub domain_name: Option<String>,
    #[serde(rename = "Entrypoint")]
    pub entrypoint: Option<Vec<String>>,
    #[serde(rename = "Env")]
    pub env: Option<Vec<String>>,
    #[serde(rename = "Hostname")]
    pub hostname: Option<String>,
    #[serde(rename = "Image")]
    pub image: Option<String>,
    #[serde(rename = "Labels")]
    pub labels: Option<HashMap<String, String>>,
    #[serde(rename = "OnBuild")]
    pub on_build: Option<Vec<String>>,
    #[serde(rename = "OpenStdin")]
    pub open_stdin: Option<bool>,
    #[serde(rename = "StdinOnce")]
    pub stdin_once: Option<bool>,
    #[serde(rename = "Tty")]
    pub tty: Option<bool>,
    #[serde(rename = "User")]
    pub user: Option<String>,
    #[serde(rename = "Volumes")]
    pub volumes: Option<HashMap<String, Empty>>,
    #[serde(rename = "WorkingDir")]
    pub working_dir: Option<String>,
    #[serde(rename = "ExposedPorts")]
    pub exposed_ports: Option<HashMap<String, Empty>>,
    #[serde(rename = "ArgsEscaped")]
    pub args_escaped: Option<bool>,
    #[serde(rename = "NetworkDisabled")]
    pub network_disabled: Option<bool>,
    #[serde(rename = "MacAddress")]
    pub mac_address: Option<String>,
    #[serde(rename = "StopSignal")]
    pub stop_signal: Option<String>,
    #[serde(rename = "Shell")]
    pub shell: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct HealthCheck {
    #[serde(rename = "Test")]
    pub test: Option<Vec<String>>,
    #[serde(rename = "Interval")]
    pub interval: Option<time::Duration>,
    #[serde(rename = "Timeout")]
    pub timeout: Option<time::Duration>,
    #[serde(rename = "StartPeriod")]
    pub start_period: Option<time::Duration>,
    #[serde(rename = "Retries")]
    pub retries: Option<i64>,
}
