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
use serde::Deserialize;

use crate::constants;
use crate::container::ConfigFile;
use crate::login::user_group_id;
use crate::system::{find_executable_in_path, load_module, sysctl};

#[derive(Debug, PartialEq)]
struct UserGroupNames {
    user: String,
    group: Option<String>,
}

impl TryFrom<String> for UserGroupNames {
    type Error = Error;

    fn try_from(user_group_str: String) -> Result<Self> {
        if user_group_str.is_empty() {
            return Err(anyhow!("user group string cannot be empty"));
        }
        let mut fields = user_group_str.split(':');
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

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
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
    pub modules: Option<Vec<String>>,
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

#[derive(Clone, Debug, Deserialize, PartialEq)]
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
    pub modules: Vec<String>,
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
            modules: Vec::new(),
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
            && !disable_services.is_empty()
        {
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
        if let Some(modules) = other.modules {
            self.modules = modules;
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

    pub fn load_modules(&self) -> Result<()> {
        for module in &self.modules {
            debug!("Loading module {}", module);
            load_module(module)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct NameValue {
    pub name: String,
    pub value: String,
}

pub type NameValues = Vec<NameValue>;

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum EnvFromSource {
    Imds(ImdsEnvSource),
    S3(S3EnvSource),
    SecretsManager(SecretsManagerEnvSource),
    Ssm(SsmEnvSource),
}

pub type EnvFromSources = Vec<EnvFromSource>;

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct ImdsEnvSource {
    pub name: String,
    pub optional: Option<bool>,
    pub path: String,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub struct S3EnvSource {
    pub base64_encode: Option<bool>,
    pub bucket: String,
    pub key: String,
    pub name: Option<String>,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub struct SecretsManagerEnvSource {
    pub base64_encode: Option<bool>,
    pub name: Option<String>,
    pub optional: Option<bool>,
    pub secret_id: String,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub struct SsmEnvSource {
    pub base64_encode: Option<bool>,
    pub name: Option<String>,
    pub path: String,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
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

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Volume {
    Ebs(EbsVolumeSource),
    S3(S3VolumeSource),
    SecretsManager(SecretsManagerVolumeSource),
    Ssm(SsmVolumeSource),
}

pub type Volumes = Vec<Volume>;

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct EbsVolumeSource {
    pub attachment: Option<EbsVolumeAttachment>,
    pub device: String,
    pub mount: Option<Mount>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct EbsVolumeAttachment {
    pub tags: Vec<AwsTag>,
    pub timeout: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct AwsTag {
    pub key: String,
    pub value: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub struct S3VolumeSource {
    pub bucket: String,
    pub key_prefix: String,
    pub optional: Option<bool>,
    pub mount: Mount,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub struct SecretsManagerVolumeSource {
    pub secret_id: String,
    pub mount: Mount,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct SsmVolumeSource {
    pub path: String,
    pub mount: Mount,
    pub optional: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
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
    use crate::{
        constants::DIR_ET_BIN,
        container::{Config, ConfigFile},
    };

    macro_rules! case__user_group__try_from {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let user_group: String = $input;
                let expected: Option<UserGroupNames> = $expected;
                let result = user_group.try_into();
                if expected.is_none() {
                    assert!(result.is_err());
                } else {
                    assert_eq!(expected.unwrap(), result.unwrap());
                }
            }
        };
    }

    macro_rules! case__user_data__from_string {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input: &str = $input;
                let expected: Option<UserData> = $expected;
                let result = UserData::from_string(input);
                if expected.is_none() {
                    assert!(result.is_err() || result.is_ok_and(|v| v.is_none()));
                } else {
                    assert!(result.is_ok());
                    assert_eq!(expected, result.unwrap());
                }
            }
        };
    }

    macro_rules! case__vmspec__full_command {
        ($name:ident, $input_vmspec:expr, $input_env:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let vmspec: VmSpec = $input_vmspec;
                let env: NameValues = $input_env;
                let expected: Option<Vec<String>> = $expected;
                let result = vmspec.full_command(&env);
                if expected.is_none() {
                    assert!(result.is_err());
                } else {
                    assert!(result.is_ok());
                    assert_eq!(expected.unwrap(), result.unwrap());
                }
            }
        };
    }

    macro_rules! case__vmspec__merge {
        ($name:ident, $input_vmspec:expr, $input_user_data:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let mut vmspec = $input_vmspec;
                vmspec.merge_user_data($input_user_data);
                assert_eq!($expected, vmspec);
            }
        };
    }

    macro_rules! case__vmspec__from_config_file {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input: ConfigFile = $input;
                let expected: Option<VmSpec> = $expected;
                let result = VmSpec::from_config_file(&input);
                if expected.is_none() {
                    assert!(result.is_err());
                } else {
                    assert_eq!(expected.unwrap(), result.unwrap());
                }
            }
        };
    }

    macro_rules! case__vmspec__update_defaults {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let mut input: VmSpec = $input;
                input.update_defaults();
                assert_eq!($expected, input);
            }
        };
    }

    macro_rules! case__name_values__find {
        ($name:ident, $input:expr, $find:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input: NameValues = $input;
                let find: &str = $find;
                let expected: Option<NameValue> = $expected;
                assert_eq!((&input).find(find), expected);
            }
        };
    }

    macro_rules! case__name_values__to_env_strings {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input: NameValues = $input;
                let expected: Vec<String> = $expected;
                assert_eq!((&input).to_env_strings(), expected);
            }
        };
    }

    macro_rules! case__name_values__to_map {
        ($name:ident, $input:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input: NameValues = $input;
                let expected: HashMap<String, String> = $expected;
                assert_eq!((&input).to_map(), expected);
            }
        };
    }

    macro_rules! case__name_values__merge {
        ($name:ident, $input_a:expr, $input_b:expr, $expected:expr) => {
            #[test]
            fn $name() {
                let input_a: NameValues = $input_a;
                let input_b: NameValues = $input_b;
                let expected: NameValues = $expected;
                assert_eq!((&input_a).merge(&input_b), expected);
            }
        };
    }

    case__user_group__try_from!(
        test_user_group_try_from_empty,
        "".into(),
        Option::<UserGroupNames>::None
    );

    case__user_group__try_from!(
        test_user_group_try_from_just_user,
        "user".into(),
        Some(UserGroupNames {
            user: "user".into(),
            group: None
        })
    );

    case__user_group__try_from!(
        test_user_group_try_from_user_and_group,
        "user:group".into(),
        Some(UserGroupNames {
            user: "user".into(),
            group: Some("group".into()),
        })
    );

    case__user_data__from_string!(
        test_user_data_from_string_empty,
        "",
        Option::<UserData>::None
    );

    case__user_data__from_string!(
        test_user_data_from_string_env_from_and_ebs_volume,
        r#"
          env-from:
            - imds:
                name: "INSTANCE_ID"
                path: "instance-id"
          volumes:
            - ebs:
                device: "/dev/sdf"
                mount:
                  destination: "/var/lib/containerd"
                  fs-type: "ext4"
                  mode: "0700"
        "#,
        Some(UserData {
            env_from: Some(vec![EnvFromSource::Imds(ImdsEnvSource {
                name: "INSTANCE_ID".into(),
                path: "instance-id".into(),
                optional: None,
            })]),
            volumes: Some(vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/sdf".into(),
                mount: Some(Mount {
                    destination: "/var/lib/containerd".into(),
                    fs_type: Some("ext4".into()),
                    mode: Some("0700".into()),
                    ..Default::default()
                }),
                attachment: None,
            })]),
            ..Default::default()
        })
    );

    case__user_data__from_string!(
        test_user_data_from_string_invalid,
        r#"
          volumes:
          - invalid-type:
              some: value
        "#,
        Option::<UserData>::None
    );

    case__user_data__from_string!(
        test_user_data_from_string_special_characters,
        r#"
          env:
            - name: SPECIAL_CHARS
              value: "Hello\nWorld\t\"quoted\"\\ and ₹ unicode"
          command:
            - /bin/echo
          args:
            - "special chars: \n\t\r\""
        "#,
        Some(UserData {
            env: Some(vec![NameValue {
                name: "SPECIAL_CHARS".into(),
                value: "Hello\nWorld\t\"quoted\"\\ and ₹ unicode".into(),
            }]),
            command: Some(vec!["/bin/echo".into()]),
            args: Some(vec!["special chars: \n\t\r\"".into()]),
            ..Default::default()
        })
    );

    case__vmspec__full_command!(
        test_vmspec_full_command_empty,
        VmSpec::default(),
        NameValues::new(),
        Some(vec![format!("{}/sh", DIR_ET_BIN)])
    );

    case__vmspec__full_command!(
        test_vmspec_full_command_absolute,
        VmSpec {
            command: vec!["/absolute/path/to/app".into()],
            args: vec!["--flag".into()],
            ..Default::default()
        },
        vec![NameValue {
            name: "PATH".into(),
            value: "/bin:/usr/bin".into(),
        }],
        Some(vec!["/absolute/path/to/app".into(), "--flag".into()])
    );

    case__vmspec__full_command!(
        test_vmspec_full_command_variable_expansion,
        VmSpec {
            command: vec!["/bin/sh".into()],
            args: vec!["$(INIT_FILE_ARG)".into(), "~/$(INIT_FILE)".into()],
            ..Default::default()
        },
        vec![
            NameValue {
                name: "INIT_FILE_ARG".into(),
                value: "--init-file".into(),
            },
            NameValue {
                name: "INIT_FILE".into(),
                value: ".bashrc".into(),
            },
            NameValue {
                name: "PATH".into(),
                value: "/bin:/usr/bin".into(),
            },
        ],
        Some(vec![
            "/bin/sh".into(),
            "--init-file".into(),
            "~/.bashrc".into(),
        ])
    );

    case__vmspec__full_command!(
        test_vmspec_full_command_executable_not_found,
        VmSpec {
            command: vec!["nonexistent_app_12345_zyxwvu".into()],
            args: vec![],
            ..Default::default()
        },
        vec![NameValue {
            name: "PATH".into(),
            value: "/bin:/usr/bin".into(),
        }],
        None
    );

    case__vmspec__merge!(
        test_vmspec_merge_empty,
        VmSpec::default(),
        UserData::default(),
        VmSpec::default()
    );

    case__vmspec__merge!(
        test_vmspec_merge_command_overrides_args,
        VmSpec {
            command: vec!["/old/command".into()],
            args: vec!["old", "args"].iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        },
        UserData {
            command: Some(vec!["/new/command".into()]),
            args: None,
            ..Default::default()
        },
        VmSpec {
            command: vec!["/new/command".into()],
            args: Vec::new(),
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_command_overrides_just_args,
        VmSpec {
            command: vec!["/old/command".into()],
            args: vec!["old", "args"].iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        },
        UserData {
            args: Some(vec!["new", "args"].iter().map(|s| s.to_string()).collect()),
            ..Default::default()
        },
        VmSpec {
            command: vec!["/old/command".into()],
            args: vec!["new", "args"].iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_command_with_args,
        VmSpec {
            command: vec!["/old/command".into()],
            args: vec!["old", "args"].iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        },
        UserData {
            command: Some(vec!["/new/command".into()]),
            args: Some(vec!["new", "args"].iter().map(|s| s.to_string()).collect()),
            ..Default::default()
        },
        VmSpec {
            command: vec!["/new/command".into()],
            args: vec!["new", "args"].iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_env_variables,
        VmSpec {
            env: vec![
                NameValue {
                    name: "EXISTING".into(),
                    value: "original".into(),
                },
                NameValue {
                    name: "KEEP".into(),
                    value: "unchanged".into(),
                },
            ],
            ..Default::default()
        },
        UserData {
            env: Some(vec![
                NameValue {
                    name: "EXISTING".into(),
                    value: "overridden".into(),
                },
                NameValue {
                    name: "NEW".into(),
                    value: "added".into(),
                },
            ]),
            ..Default::default()
        },
        VmSpec {
            env: vec![
                NameValue {
                    name: "KEEP".into(),
                    value: "unchanged".into(),
                },
                NameValue {
                    name: "EXISTING".into(),
                    value: "overridden".into(),
                },
                NameValue {
                    name: "NEW".into(),
                    value: "added".into(),
                },
            ],
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_security,
        VmSpec {
            security: Security {
                readonly_root_fs: Some(false),
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
            },
            ..Default::default()
        },
        UserData {
            security: Some(Security {
                readonly_root_fs: Some(true),
                run_as_user_id: None,
                run_as_group_id: Some(2000),
            }),
            ..Default::default()
        },
        VmSpec {
            security: Security {
                readonly_root_fs: Some(true),
                run_as_user_id: Some(1000),  // Unchanged
                run_as_group_id: Some(2000), // Overridden
            },
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_realistic_java_application,
        VmSpec {
            command: vec!["java".into()],
            args: vec!["-jar", "app.jar"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            env: vec![
                NameValue {
                    name: "JAVA_HOME".into(),
                    value: "/usr/lib/jvm/java-11".into(),
                },
                NameValue {
                    name: "APP_ENV".into(),
                    value: "development".into(),
                },
                NameValue {
                    name: "JVM_OPTS".into(),
                    value: "-Xmx512m".into(),
                },
            ],
            ..Default::default()
        },
        UserData {
            env: Some(vec![
                NameValue {
                    name: "APP_ENV".into(), // Override
                    value: "production".into(),
                },
                NameValue {
                    name: "JVM_OPTS".into(), // Override
                    value: "-Xmx2g -XX:+UseG1GC".into(),
                },
                NameValue {
                    name: "DATABASE_URL".into(), // Add new
                    value: "postgres://db:5432/app".into(),
                },
            ]),
            ..Default::default()
        },
        VmSpec {
            command: vec!["java".into()],
            args: vec!["-jar", "app.jar"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            env: vec![
                NameValue {
                    name: "JAVA_HOME".into(),
                    value: "/usr/lib/jvm/java-11".into(),
                },
                NameValue {
                    name: "APP_ENV".into(),
                    value: "production".into(),
                },
                NameValue {
                    name: "JVM_OPTS".into(),
                    value: "-Xmx2g -XX:+UseG1GC".into(),
                },
                NameValue {
                    name: "DATABASE_URL".into(),
                    value: "postgres://db:5432/app".into(),
                },
            ],
            ..Default::default()
        }
    );

    case__vmspec__merge!(
        test_vmspec_merge_realistic_python_application,
        VmSpec {
            command: vec!["python".into()],
            args: vec!["app.py".into()],
            env: vec![
                NameValue {
                    name: "FLASK_APP".into(),
                    value: "app.py".into(),
                },
                NameValue {
                    name: "FLASK_ENV".into(),
                    value: "development".into(),
                },
            ],
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                readonly_root_fs: Some(false),
            },
            working_dir: "/application".into(),
            ..Default::default()
        },
        UserData {
            env: Some(vec![NameValue {
                name: "FLASK_ENV".into(),
                value: "production".into(),
            }]),
            env_from: Some(vec![EnvFromSource::SecretsManager(
                SecretsManagerEnvSource {
                    secret_id: "prod/flask-secrets".into(),
                    ..Default::default()
                },
            )]),
            volumes: Some(vec![Volume::S3(S3VolumeSource {
                bucket: "app-static".into(),
                key_prefix: "assets/".into(),
                mount: Mount {
                    destination: "/app/static".into(),
                    ..Default::default()
                },
                ..Default::default()
            })]),
            sysctls: Some(vec![NameValue {
                name: "net.core.somaxconn".into(),
                value: "4096".into(),
            }]),
            init_scripts: Some(vec!["#!/bin/sh\nmkdir -p /app/logs".into()]),
            working_dir: Some("/app".into()),
            ..Default::default()
        },
        VmSpec {
            command: vec!["python".into()],
            args: vec!["app.py".into()],
            env: vec![
                NameValue {
                    name: "FLASK_APP".into(),
                    value: "app.py".into(),
                },
                NameValue {
                    name: "FLASK_ENV".into(),
                    value: "production".into(),
                },
            ],
            env_from: vec![EnvFromSource::SecretsManager(SecretsManagerEnvSource {
                secret_id: "prod/flask-secrets".into(),
                ..Default::default()
            })],
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                readonly_root_fs: Some(false),
            },
            working_dir: "/app".into(),
            volumes: vec![Volume::S3(S3VolumeSource {
                bucket: "app-static".into(),
                key_prefix: "assets/".into(),
                mount: Mount {
                    destination: "/app/static".into(),
                    user_id: Some(1000),
                    group_id: Some(1000),
                    ..Default::default()
                },
                ..Default::default()
            })],
            sysctls: vec![NameValue {
                name: "net.core.somaxconn".into(),
                value: "4096".into(),
            }],
            init_scripts: vec!["#!/bin/sh\nmkdir -p /app/logs".into()],
            ..Default::default()
        }
    );

    case__vmspec__from_config_file!(
        test_vmspec_from_config_file_empty,
        ConfigFile::default(),
        Some(VmSpec::default())
    );

    case__vmspec__from_config_file!(
        test_vmspec_from_config_file_entrypoint_only,
        ConfigFile {
            config: Some(Config {
                cmd: None,
                entrypoint: Some(vec!["/app".into()]),
                env: None,
                working_dir: None,
                user: None,
            }),
        },
        Some(VmSpec {
            command: vec!["/app".into()],
            ..Default::default()
        })
    );

    case__vmspec__from_config_file!(
        test_vmspec_from_config_file_entrypoint_env_user,
        ConfigFile {
            config: Some(Config {
                entrypoint: Some(vec!["/usr/bin/myapp".into()]),
                env: Some(vec!["NODE_ENV=production".into(), "PORT=8080".into()]),
                user: Some("1000".into()),
                ..Default::default()
            }),
        },
        Some(VmSpec {
            command: vec!["/usr/bin/myapp".into()],
            env: vec![
                NameValue {
                    name: "NODE_ENV".into(),
                    value: "production".into(),
                },
                NameValue {
                    name: "PORT".into(),
                    value: "8080".into(),
                },
            ],
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(0),
                ..Default::default()
            },
            ..Default::default()
        })
    );

    case__vmspec__from_config_file!(
        test_vmspec_from_config_file_entrypoint_env_user_group,
        ConfigFile {
            config: Some(Config {
                entrypoint: Some(vec!["/usr/bin/myapp".into()]),
                env: Some(vec!["NODE_ENV=production".into(), "PORT=8080".into()]),
                user: Some("1000:500".into()),
                ..Default::default()
            }),
        },
        Some(VmSpec {
            command: vec!["/usr/bin/myapp".into()],
            env: vec![
                NameValue {
                    name: "NODE_ENV".into(),
                    value: "production".into(),
                },
                NameValue {
                    name: "PORT".into(),
                    value: "8080".into(),
                },
            ],
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(500),
                ..Default::default()
            },
            ..Default::default()
        })
    );

    case__vmspec__from_config_file!(
        test_vmspec_from_config_file_full,
        ConfigFile {
            config: Some(Config {
                cmd: Some(vec!["--verbose".into(), "--port=8080".into()]),
                entrypoint: Some(vec!["/usr/bin/myapp".into()]),
                env: Some(vec![
                    "NODE_ENV=production".into(),
                    "PORT=8080".into(),
                    "DEBUG=".into(),
                ]),
                working_dir: Some("/app".into()),
                user: None,
            }),
        },
        Some(VmSpec {
            command: vec!["/usr/bin/myapp".into()],
            args: vec!["--verbose".into(), "--port=8080".into()],
            working_dir: "/app".into(),
            env: vec![
                NameValue {
                    name: "NODE_ENV".into(),
                    value: "production".into(),
                },
                NameValue {
                    name: "PORT".into(),
                    value: "8080".into(),
                },
                NameValue {
                    name: "DEBUG".into(),
                    value: "".into(),
                },
            ],
            ..Default::default()
        })
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_ebs_volume_default_mount,
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: Some(Mount {
                    destination: "/data".into(),
                    user_id: None,  // Should be filled with default
                    group_id: None, // Should be filled with default
                    mode: None,     // Should be filled with default
                    ..Default::default()
                }),
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: Some(Mount {
                    destination: "/data".into(),
                    user_id: Some(1000),       // Filled with default
                    group_id: Some(1000),      // Filled with default
                    mode: Some("0755".into()), // Filled with default
                    ..Default::default()
                }),
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_ebs_volume_override_mount,
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: Some(Mount {
                    destination: "/data".into(),
                    user_id: Some(2000),
                    group_id: Some(2000),
                    mode: Some("0750".into()),
                    ..Default::default()
                }),
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: Some(Mount {
                    destination: "/data".into(),
                    user_id: Some(2000),
                    group_id: Some(2000),
                    mode: Some("0750".into()),
                    ..Default::default()
                }),
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_ebs_volume_no_mount,
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: None,
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(1000),
                run_as_group_id: Some(1000),
                ..Default::default()
            },
            volumes: vec![Volume::Ebs(EbsVolumeSource {
                device: "/dev/nvme1n1".into(),
                mount: None,
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_s3_volume,
        VmSpec {
            security: Security {
                run_as_user_id: Some(500),
                run_as_group_id: Some(500),
                ..Default::default()
            },
            volumes: vec![Volume::S3(S3VolumeSource {
                bucket: "test-bucket".into(),
                key_prefix: "config/".into(),
                mount: Mount {
                    destination: "/config".into(),
                    user_id: None,
                    group_id: None,
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(500),
                run_as_group_id: Some(500),
                ..Default::default()
            },
            volumes: vec![Volume::S3(S3VolumeSource {
                bucket: "test-bucket".into(),
                key_prefix: "config/".into(),
                mount: Mount {
                    destination: "/config".into(),
                    user_id: Some(500),
                    group_id: Some(500),
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_secrets_manager_volume,
        VmSpec {
            security: Security {
                run_as_user_id: Some(1001),
                run_as_group_id: Some(1001),
                ..Default::default()
            },
            volumes: vec![Volume::SecretsManager(SecretsManagerVolumeSource {
                secret_id: "prod/secret".into(),
                mount: Mount {
                    destination: "/secrets".into(),
                    user_id: None,
                    group_id: None,
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(1001),
                run_as_group_id: Some(1001),
                ..Default::default()
            },
            volumes: vec![Volume::SecretsManager(SecretsManagerVolumeSource {
                secret_id: "prod/secret".into(),
                mount: Mount {
                    destination: "/secrets".into(),
                    user_id: Some(1001),
                    group_id: Some(1001),
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__vmspec__update_defaults!(
        test_vmspec_update_defaults_ssm_volume,
        VmSpec {
            security: Security {
                run_as_user_id: Some(1002),
                run_as_group_id: Some(1002),
                ..Default::default()
            },
            volumes: vec![Volume::Ssm(SsmVolumeSource {
                path: "/app/config".into(),
                mount: Mount {
                    destination: "/config".into(),
                    user_id: None,
                    group_id: None,
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        },
        VmSpec {
            security: Security {
                run_as_user_id: Some(1002),
                run_as_group_id: Some(1002),
                ..Default::default()
            },
            volumes: vec![Volume::Ssm(SsmVolumeSource {
                path: "/app/config".into(),
                mount: Mount {
                    destination: "/config".into(),
                    user_id: Some(1002),
                    group_id: Some(1002),
                    ..Default::default()
                },
                ..Default::default()
            })],
            ..Default::default()
        }
    );

    case__name_values__find!(
        test_name_values_find_empty,
        vec![],
        "anything",
        Option::<NameValue>::None
    );

    case__name_values__find!(
        test_name_values_find_existing,
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ],
        "VAR1",
        Some(NameValue {
            name: "VAR1".into(),
            value: "value1".into(),
        })
    );

    case__name_values__find!(
        test_name_values_find_not_found,
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ],
        "VAR3",
        Option::<NameValue>::None
    );

    case__name_values__to_env_strings!(test_name_values_to_env_strings_empty, vec![], vec![]);

    case__name_values__to_env_strings!(
        test_name_values_to_env_strings_nonempty,
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ],
        vec!["VAR1=value1".into(), "VAR2=value2".into()]
    );

    case__name_values__to_map!(test_name_values_to_map_empty, vec![], HashMap::new());

    case__name_values__to_map!(
        test_name_values_to_map_nonempty,
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ],
        HashMap::from([
            ("VAR1".into(), "value1".into()),
            ("VAR2".into(), "value2".into()),
        ])
    );

    case__name_values__merge!(test_name_values_merge_empty, vec![], vec![], vec![]);

    case__name_values__merge!(
        test_name_values_merge_nonoverlapping,
        vec![NameValue {
            name: "VAR1".into(),
            value: "value1".into(),
        },],
        vec![NameValue {
            name: "VAR2".into(),
            value: "value2".into(),
        },],
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ]
    );

    case__name_values__merge!(
        test_name_values_merge_overlapping,
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
        ],
        vec![
            NameValue {
                name: "VAR2".into(),
                value: "new_value2".into(),
            },
            NameValue {
                name: "VAR3".into(),
                value: "value3".into(),
            },
        ],
        vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "new_value2".into(),
            },
            NameValue {
                name: "VAR3".into(),
                value: "value3".into(),
            },
        ]
    );

    #[test]
    fn test_string_slice_to_name_values() {
        let string_slice = vec![
            "VAR1=value1".into(),
            "VAR2=value2".into(),
            "VAR3=value3=with=equals".into(),
            "VAR4=".into(),
            "VAR5".into(),
        ];
        let expected = vec![
            NameValue {
                name: "VAR1".into(),
                value: "value1".into(),
            },
            NameValue {
                name: "VAR2".into(),
                value: "value2".into(),
            },
            NameValue {
                name: "VAR3".into(),
                value: "value3=with=equals".into(),
            },
            NameValue {
                name: "VAR4".into(),
                value: "".into(),
            },
            NameValue {
                name: "VAR5".into(),
                value: "".into(),
            },
        ];
        assert_eq!(string_slice.to_name_values(), expected);
    }
}
