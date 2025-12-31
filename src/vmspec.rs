use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Error, Result, anyhow};
use k8s_expand::{expand, mapping_func_for};
use log::{debug, info};
use rustix::fs::{Mode, chmod};
use serde::{Deserialize, Serialize};

use crate::constants;
use crate::container::ConfigFile;
use crate::login::user_group_id;
use crate::system::{find_executable_in_path, sysctl};

#[derive(Debug, PartialEq)]
struct UserGroupNames {
    user: String,
    group: Option<String>,
}

impl TryFrom<String> for UserGroupNames {
    type Error = Error;

    fn try_from(user_data_str: String) -> Result<Self> {
        if user_data_str.is_empty() {
            return Err(anyhow!("user group string cannot be empty"));
        }
        let mut fields = user_data_str.split(':');
        let user = fields.next();
        let group = fields.next();
        if fields.next().is_some() {
            return Err(anyhow!("too many fields in user group string"));
        }
        Ok(UserGroupNames {
            user: user.unwrap().into(),
            group: group.map(String::from),
        })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct UserData {
    pub args: Option<Vec<String>>,
    pub command: Option<Vec<String>>,
    pub debug: Option<bool>,
    pub disable_services: Option<Vec<String>>,
    pub env: Option<NameValues>,
    pub env_from: Option<EnvFromSources>,
    pub init_scripts: Option<Vec<String>>,
    pub replace_init: Option<bool>,
    pub security: Option<Security>,
    pub shutdown_grace_period: Option<u64>,
    pub sysctls: Option<NameValues>,
    pub volumes: Option<Volumes>,
    pub working_dir: Option<String>,
}

impl UserData {
    pub fn from_string(value: &str) -> Result<Option<Self>> {
        if value.is_empty() {
            return Ok(None);
        }
        serde_yaml2::from_str::<UserData>(value).map_or_else(
            |e| Err(anyhow!("unable to parse user data: {}", e)),
            |ud| Ok(Some(ud)),
        )
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct VmSpec {
    pub args: Vec<String>,
    pub command: Vec<String>,
    pub debug: bool,
    pub disable_services: Vec<String>,
    pub env: NameValues,
    pub env_from: EnvFromSources,
    pub init_scripts: Vec<String>,
    pub replace_init: bool,
    pub security: Security,
    pub shutdown_grace_period: u64,
    pub sysctls: NameValues,
    pub volumes: Volumes,
    pub working_dir: String,
}

impl Default for VmSpec {
    fn default() -> Self {
        VmSpec {
            args: Vec::new(),
            command: Vec::new(),
            debug: false,
            disable_services: Vec::new(),
            env: Vec::new(),
            env_from: Vec::new(),
            init_scripts: Vec::new(),
            replace_init: false,
            security: Security::default(),
            shutdown_grace_period: 10,
            sysctls: Vec::new(),
            volumes: Vec::new(),
            working_dir: "/".into(),
        }
    }
}

impl VmSpec {
    pub fn full_command(&self, env: &NameValues) -> Result<Vec<String>> {
        let cap = self.command.len() + self.args.len();
        if cap == 0 {
            return Ok(vec![format!("{}/sh", constants::DIR_ET_BIN)]);
        }

        let mut exe = Vec::with_capacity(cap);
        exe.extend(self.command.clone());
        exe.extend(self.args.clone());

        let path_var = env
            .find("PATH")
            .unwrap_or_else(|| unreachable!("PATH should have been defined"));

        if !exe[0].starts_with(constants::DIR_ROOT) {
            let exe_path = find_executable_in_path(&exe[0], &path_var.value)
                .ok_or_else(|| anyhow!("unable to find executable in PATH: {}", exe[0]))?
                .to_str()
                .ok_or_else(|| anyhow!("unable to convert path to string: {}", exe[0]))?
                .into();
            exe[0] = exe_path;
        }

        let env_refs = HashMap::from_iter(env.to_map_rc());
        let maps = vec![&env_refs];
        let mapping = mapping_func_for(&maps);
        let mut expanded_exe = Vec::with_capacity(exe.len());
        for arg in exe.iter() {
            expanded_exe.push(expand(arg, &mapping));
        }

        Ok(expanded_exe)
    }

    fn run_init_script<P: AsRef<Path>>(
        &self,
        path: P,
        contents: &[u8],
        env: &NameValues,
    ) -> Result<()> {
        fs::write(&path, contents)
            .map_err(|e| anyhow!("unable to write init script to {:?}: {}", path.as_ref(), e))?;
        chmod(path.as_ref(), Mode::from(0o755))
            .map_err(|e| anyhow!("unable to set init script as executable: {}", e))?;
        Command::new(path.as_ref())
            .stdout(Stdio::inherit())
            .envs(env.to_map())
            .output()
            .map_err(|e| anyhow!("unable to run init script: {}", e))?;
        fs::remove_file(&path).map_err(|e| anyhow!("failed to remove init script: {}", e))
    }

    fn update_defaults(&mut self) {
        for volume in &mut self.volumes {
            match volume {
                Volume::Ebs(ebs) => {
                    if let Some(mount) = &mut ebs.mount {
                        if mount.group_id.is_none() {
                            mount.group_id = self.security.run_as_group_id;
                        }
                        if mount.user_id.is_none() {
                            mount.user_id = self.security.run_as_user_id;
                        }
                        if mount.mode.is_none() {
                            mount.mode = Some("0755".into());
                        }
                    }
                }
                Volume::S3(s3) => {
                    if s3.mount.group_id.is_none() {
                        s3.mount.group_id = self.security.run_as_group_id;
                    }
                    if s3.mount.user_id.is_none() {
                        s3.mount.user_id = self.security.run_as_user_id;
                    }
                }
                Volume::SecretsManager(secrets_manager) => {
                    if secrets_manager.mount.group_id.is_none() {
                        secrets_manager.mount.group_id = self.security.run_as_group_id;
                    }
                    if secrets_manager.mount.user_id.is_none() {
                        secrets_manager.mount.user_id = self.security.run_as_user_id;
                    }
                }
                Volume::Ssm(ssm) => {
                    if ssm.mount.group_id.is_none() {
                        ssm.mount.group_id = self.security.run_as_group_id;
                    }
                    if ssm.mount.user_id.is_none() {
                        ssm.mount.user_id = self.security.run_as_user_id;
                    }
                }
            }
        }
    }

    pub fn from_config_file(config_file: &ConfigFile) -> Result<Self> {
        let config = config_file.config.clone().unwrap_or_default();
        let config_env = config.env.unwrap_or_default();
        let env = config_env.to_name_values();
        let mut vmspec = Self {
            env,
            ..Default::default()
        };
        if let Some(cmd) = config.cmd {
            vmspec.args = cmd;
        }
        if let Some(entrypoint) = config.entrypoint {
            vmspec.command = entrypoint;
        }
        if let Some(working_dir) = config.working_dir {
            vmspec.working_dir = working_dir;
        }
        if let Some(user) = config.user {
            let user_group_names: UserGroupNames = user.try_into()?;
            let fp = File::open(constants::FILE_ETC_PASSWD)?;
            let uid = user_group_id(BufReader::new(fp), &user_group_names.user)?;
            vmspec.security.run_as_user_id = Some(uid);
            if let Some(group_name) = user_group_names.group {
                let fg = File::open(constants::FILE_ETC_GROUP)?;
                let gid = user_group_id(BufReader::new(fg), &group_name)?;
                vmspec.security.run_as_group_id = Some(gid);
            }
        }
        Ok(vmspec)
    }

    pub fn merge_user_data(&mut self, other: UserData) {
        if let Some(args) = &other.args {
            self.args = args.clone();
        }
        if let Some(command) = other.command {
            self.command = command;
            // If args is not set in other, set it to empty here to
            // make sure it is overridden, since command was overridden.
            if other.args.is_none() {
                self.args = Vec::new();
            }
        }
        if other.debug.is_some() {
            self.debug = other.debug.unwrap();
        }
        if let Some(disable_services) = other.disable_services
            && !disable_services.is_empty() {
                self.disable_services = disable_services;
            }
        if let Some(env) = other.env {
            self.env = (&self.env).merge(&env);
        }
        if let Some(env_from) = other.env_from {
            self.env_from = env_from;
        }
        if let Some(init_scripts) = other.init_scripts {
            self.init_scripts = init_scripts;
        }
        if other.replace_init.is_some() {
            self.replace_init = other.replace_init.unwrap();
        }
        if let Some(security) = other.security {
            self.security.merge(security);
        }
        if other.shutdown_grace_period.is_some() {
            self.shutdown_grace_period = other.shutdown_grace_period.unwrap();
        }
        if let Some(sysctls) = other.sysctls {
            self.sysctls = (&self.sysctls).merge(&sysctls);
        }
        if let Some(volumes) = other.volumes {
            self.volumes = volumes;
        }
        if other.working_dir.is_some() {
            self.working_dir = other.working_dir.unwrap();
        }
        self.update_defaults();
    }

    pub fn run_init_scripts<P: AsRef<Path>>(&self, base_dir: P, env: &NameValues) -> Result<()> {
        for (i, script) in self.init_scripts.iter().enumerate() {
            let path = PathBuf::from_iter(&[
                base_dir.as_ref(),
                constants::DIR_ET_RUN.as_ref(),
                format!("init-{}", i).as_ref(),
            ]);
            info!("Running init script {:?}", &path);
            self.run_init_script(&path, script.as_bytes(), env)?;
        }
        Ok(())
    }

    pub fn set_sysctls<P: AsRef<Path>>(&self, base_dir: P) -> Result<()> {
        for nv in &self.sysctls {
            debug!("Setting sysctl {}={}", &nv.name, &nv.value);
            sysctl(&base_dir, &nv.name, &nv.value)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct NameValue {
    pub name: String,
    pub value: String,
}

pub type NameValues = Vec<NameValue>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EnvFromSource {
    Imds(ImdsEnvSource),
    S3(S3EnvSource),
    SecretsManager(SecretsManagerEnvSource),
    Ssm(SsmEnvSource),
}

pub type EnvFromSources = Vec<EnvFromSource>;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct ImdsEnvSource {
    pub name: String,
    pub optional: Option<bool>,
    pub path: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct S3EnvSource {
    pub base64_encode: Option<bool>,
    pub bucket: String,
    pub key: String,
    pub name: Option<String>,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct SecretsManagerEnvSource {
    pub base64_encode: Option<bool>,
    pub name: Option<String>,
    pub optional: Option<bool>,
    pub secret_id: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct SsmEnvSource {
    pub base64_encode: Option<bool>,
    pub name: Option<String>,
    pub path: String,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct Security {
    pub readonly_root_fs: Option<bool>,
    pub run_as_group_id: Option<u32>,
    pub run_as_user_id: Option<u32>,
}

impl Default for Security {
    fn default() -> Self {
        Security {
            readonly_root_fs: Some(false),
            run_as_group_id: Some(0),
            run_as_user_id: Some(0),
        }
    }
}

impl Security {
    fn merge(&mut self, other: Self) {
        if other.readonly_root_fs.is_some() {
            self.readonly_root_fs = other.readonly_root_fs;
        }
        if other.run_as_group_id.is_some() {
            self.run_as_group_id = other.run_as_group_id;
        }
        if other.run_as_user_id.is_some() {
            self.run_as_user_id = other.run_as_user_id;
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Volume {
    Ebs(EbsVolumeSource),
    S3(S3VolumeSource),
    SecretsManager(SecretsManagerVolumeSource),
    Ssm(SsmVolumeSource),
}

pub type Volumes = Vec<Volume>;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct EbsVolumeSource {
    pub attachment: Option<EbsVolumeAttachment>,
    pub device: String,
    pub mount: Option<Mount>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct EbsVolumeAttachment {
    pub tags: Vec<AwsTag>,
    pub timeout: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AwsTag {
    pub key: String,
    pub value: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct S3VolumeSource {
    pub bucket: String,
    pub key_prefix: String,
    pub optional: Option<bool>,
    pub mount: Mount,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct SecretsManagerVolumeSource {
    pub secret_id: String,
    pub mount: Mount,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct SsmVolumeSource {
    pub path: String,
    pub mount: Mount,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct Mount {
    pub destination: String,
    pub fs_type: Option<String>,
    pub group_id: Option<u32>,
    pub mode: Option<String>,
    pub options: Option<Vec<String>>,
    pub user_id: Option<u32>,
}

pub trait NameValuesExt<T> {
    fn find(&self, key: &str) -> Option<NameValue>;
    fn merge(&self, other: &T) -> T;
    fn to_env_strings(&self) -> Vec<String>;
    fn to_map(&self) -> HashMap<String, String>;
    fn to_map_rc(&self) -> HashMap<String, RefCell<String>>;
}

impl NameValuesExt<NameValues> for &NameValues {
    fn find(&self, key: &str) -> Option<NameValue> {
        for nv in self.iter() {
            if nv.name == *key {
                return Some(nv.clone());
            }
        }
        None
    }

    fn to_env_strings(&self) -> Vec<String> {
        self.iter()
            .map(|nv| format!("{}={}", nv.name, nv.value))
            .collect()
    }

    fn merge(&self, other: &NameValues) -> NameValues {
        let mut nvs = NameValues::with_capacity(self.len() + other.len());
        for nv in self.iter() {
            if other.find(&nv.name).is_none() {
                nvs.push(nv.clone());
            }
        }
        for nv in other {
            nvs.push(nv.clone());
        }
        nvs
    }

    fn to_map(&self) -> HashMap<String, String> {
        let mut map = std::collections::HashMap::new();
        for nv in self.iter() {
            map.insert(nv.name.clone(), nv.value.clone());
        }
        map
    }

    fn to_map_rc(&self) -> HashMap<String, RefCell<String>> {
        let mut map = std::collections::HashMap::new();
        for nv in self.iter() {
            map.insert(nv.name.clone(), nv.value.clone().into());
        }
        map
    }
}

trait StringSliceExt {
    fn to_name_values(&self) -> NameValues;
}

impl StringSliceExt for Vec<String> {
    fn to_name_values(&self) -> NameValues {
        self.iter()
            .map(|s| {
                let mut parts = s.splitn(2, '=');
                NameValue {
                    name: parts.next().unwrap_or("").into(),
                    value: parts.next().unwrap_or("").into(),
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_user_group_try_from() {
        struct Case {
            input: String,
            expected: Option<UserGroupNames>,
        }
        let cases = [
            Case {
                input: "".into(),
                expected: None,
            },
            Case {
                input: "user".into(),
                expected: Some(UserGroupNames {
                    user: "user".into(),
                    group: None,
                }),
            },
            Case {
                input: "user:group".into(),
                expected: Some(UserGroupNames {
                    user: "user".into(),
                    group: Some("group".into()),
                }),
            },
        ];
        for case in cases {
            let result = case.input.try_into();
            if case.expected.is_none() {
                assert_eq!(true, result.is_err());
            } else {
                assert_eq!(case.expected.unwrap(), result.unwrap());
            }
        }
    }
}
