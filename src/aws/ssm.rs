use std::{collections::HashMap, io::Read};

use anyhow::{Result, anyhow};
use aws_sdk_ssm::types::Parameter;
use log::debug;
use tokio::runtime::Handle;

use crate::writable::Writable;

#[derive(Debug)]
pub struct SsmClient {
    rt: Handle,
    client: SsmClientAsync,
}

impl SsmClient {
    pub fn new(rt: Handle, client: aws_sdk_ssm::Client) -> Self {
        let client_async = SsmClientAsync::new(client);
        Self {
            rt,
            client: client_async,
        }
    }

    pub fn get_parameter_list(&self, ssm_path: &str) -> Result<Vec<SsmParameterValue>> {
        self.rt.block_on(self.client.get_parameter_list(ssm_path))
    }

    pub fn get_parameter_map(&self, ssm_path: &str) -> Result<HashMap<String, String>> {
        self.rt.block_on(self.client.get_parameter_map(ssm_path))
    }

    pub fn get_parameter_value(&self, ssm_path: &str) -> Result<Vec<u8>> {
        self.rt.block_on(self.client.get_parameter_value(ssm_path))
    }
}

#[derive(Debug)]
pub struct SsmClientAsync {
    client: aws_sdk_ssm::Client,
}

impl SsmClientAsync {
    pub fn new(client: aws_sdk_ssm::Client) -> Self {
        Self { client }
    }

    pub async fn get_parameter_list(&self, ssm_path: &str) -> Result<Vec<SsmParameterValue>> {
        self.get_parameters(ssm_path).await.map(|parameters| {
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

    pub async fn get_parameter_map(&self, ssm_path: &str) -> Result<HashMap<String, String>> {
        let parameter = self.get_parameter(ssm_path).await?;
        let value = parameter
            .value
            .ok_or_else(|| anyhow!("value of SSM parameter at path {} not found", ssm_path))?;
        let map: HashMap<String, String> = serde_json::from_str(&value)?;
        Ok(map)
    }

    pub async fn get_parameter_value(&self, ssm_path: &str) -> Result<Vec<u8>> {
        let parameter = self.get_parameter(ssm_path).await?;
        let value = parameter
            .value
            .ok_or_else(|| anyhow!("value of SSM parameter at path {} not found", ssm_path))?;
        Ok(value.into_bytes())
    }

    async fn get_parameters(&self, ssm_path: &str) -> Result<Vec<Parameter>> {
        let mut parameters = Vec::new();
        if ssm_path.starts_with("/") {
            parameters = self.get_parameters_by_path(ssm_path).await?;
        }
        if parameters.is_empty() {
            let parameter = self.get_parameter(ssm_path).await?;
            parameters.push(parameter);
        }
        Ok(parameters)
    }

    async fn get_parameters_by_path(&self, ssm_path: &str) -> Result<Vec<Parameter>> {
        let mut parameters = Vec::new();
        let mut next_token: Option<String> = None;
        loop {
            let mut req = self
                .client
                .get_parameters_by_path()
                .path(ssm_path)
                .recursive(true)
                .with_decryption(true);
            if let Some(ref token) = next_token {
                req = req.next_token(token);
            }
            let out = req.send().await.map_err(|e| {
                anyhow!(
                    "unable to get SSM parameters at path {}: {}",
                    ssm_path,
                    e.into_service_error()
                )
            })?;
            let p = out
                .parameters
                .ok_or(anyhow!("no SSM parameters in path {}", ssm_path))?;
            parameters.extend(p);
            if out.next_token.is_none() {
                break;
            }
            next_token = out.next_token;
        }
        Ok(parameters)
    }

    async fn get_parameter(&self, ssm_path: &str) -> Result<Parameter> {
        let out = self
            .client
            .get_parameter()
            .name(ssm_path)
            .with_decryption(true)
            .send()
            .await
            .map_err(|e| {
                anyhow!(
                    "failed to get SSM parameter {}: {}",
                    ssm_path,
                    e.into_service_error()
                )
            })?;
        let parameter = out
            .parameter
            .ok_or_else(|| anyhow!("parameter {} not found in SSM", ssm_path))?;
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
