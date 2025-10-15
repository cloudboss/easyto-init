use std::{collections::HashMap, io::Read, sync::Arc};

use anyhow::{anyhow, Result};
use log::debug;
use minaws::{
    imds::{Credentials, Imds},
    ssm::{self, GetParametersByPathInput, Parameter},
};

use crate::writable::Writable;

pub struct SsmClient {
    api: Arc<ssm::Api>,
}

impl SsmClient {
    pub fn new(credentials: Credentials, region: &str) -> Self {
        let api = ssm::Api::new(region, credentials);
        Self { api: api.into() }
    }

    pub fn from_imds(imds: &Imds, region: &str) -> Result<Self> {
        let credentials = imds.get_credentials()?;
        let api = ssm::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn get_parameter_list(&self, ssm_path: &str) -> Result<Vec<SsmParameterValue>> {
        self.get_parameters(ssm_path).map(|parameters| {
            parameters
                .into_iter()
                .map(|p| {
                    let mut name = p.name.clone().unwrap();
                    name = name[ssm_path.len()..].to_string();
                    SsmParameterValue {
                        name,
                        value: p.value.clone().unwrap(),
                    }
                })
                .collect()
        })
    }

    pub fn get_parameter_map(&self, ssm_path: &str) -> Result<HashMap<String, String>> {
        let parameter = self.get_parameter(ssm_path)?;
        let value = parameter
            .value
            .ok_or_else(|| anyhow!("value of parameter at path {} not found", ssm_path))?;
        let map: HashMap<String, String> = serde_json::from_str(&value)?;
        Ok(map)
    }

    pub fn get_parameter_value(&self, ssm_path: &str) -> Result<Vec<u8>> {
        let parameter = self.get_parameter(ssm_path)?;
        let value = parameter
            .value
            .ok_or_else(|| anyhow!("value of parameter at path {} not found", ssm_path))?;
        Ok(value.into_bytes())
    }

    fn get_parameters(&self, ssm_path: &str) -> Result<Vec<Parameter>> {
        let mut parameters = Vec::new();
        if ssm_path.starts_with("/") {
            parameters = self.get_parameters_by_path(ssm_path)?;
        }
        if parameters.is_empty() {
            let parameter = self.get_parameter(ssm_path)?;
            parameters.push(parameter);
        }
        Ok(parameters)
    }

    fn get_parameters_by_path(&self, ssm_path: &str) -> Result<Vec<Parameter>> {
        let mut parameters = Vec::new();
        let mut next_token: Option<String> = None;
        loop {
            let mut input = GetParametersByPathInput::default()
                .path(ssm_path)
                .recursive(true)
                .with_decryption(true);
            if let Some(ref token) = next_token {
                input = input.next_token(token);
            }
            let out = self
                .api
                .get_parameters_by_path(input)
                .map_err(|e| anyhow!("unable to get SSM parameters at path {}: {}", ssm_path, e))?;
            let p = out
                .parameters
                .ok_or(anyhow!("no SSM parameters in result"))?;
            parameters.extend(p);
            if out.next_token.is_none() {
                break;
            }
            next_token = out.next_token;
        }
        Ok(parameters)
    }

    fn get_parameter(&self, ssm_path: &str) -> Result<Parameter> {
        let out = self.api.get_parameter(
            ssm::GetParameterInput::default()
                .name(ssm_path)
                .with_decryption(true),
        )?;
        let parameter = out
            .parameter
            .ok_or_else(|| anyhow!("parameter not found"))?;
        Ok(parameter)
    }
}

#[derive(Debug, Default)]
pub struct SsmParameterValue {
    pub name: String,
    pub value: String,
}

impl Read for SsmParameterValue {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let bread = self.value.as_bytes().read(buf)?;
        self.value = self.value[bread..].to_string();
        debug!("read {} bytes from SsmParameterValue", bread);
        Ok(bread)
    }
}

impl Writable for SsmParameterValue {
    fn is_secret(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        &self.name
    }
}
