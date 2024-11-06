use serde::Deserialize;

#[derive(Clone, Debug, Default, Deserialize)]
pub struct ConfigFile {
    pub config: Option<Config>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Config {
    #[serde(rename = "Cmd")]
    pub cmd: Option<Vec<String>>,
    #[serde(rename = "Entrypoint")]
    pub entrypoint: Option<Vec<String>>,
    #[serde(rename = "Env")]
    pub env: Option<Vec<String>>,
    #[serde(rename = "User")]
    pub user: Option<String>,
    #[serde(rename = "WorkingDir")]
    pub working_dir: Option<String>,
}
