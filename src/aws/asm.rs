use std::{collections::HashMap, io::Read};

use anyhow::{Result, anyhow};
use aws_sdk_secretsmanager::operation::get_secret_value::GetSecretValueOutput;
use tokio::runtime::Handle;

use crate::writable::Writable;

#[derive(Debug, Clone)]
pub struct AsmClient {
    rt: Handle,
    client: AsmClientAsync,
}

impl AsmClient {
    pub fn new(rt: Handle, client: aws_sdk_secretsmanager::Client) -> Self {
        let client_async = AsmClientAsync::new(client);
        Self {
            rt,
            client: client_async,
        }
    }

    pub fn get_secret_list(&self, secret_id: &str) -> Result<Vec<AsmSecretValue>> {
        self.rt.block_on(self.client.get_secret_list(secret_id))
    }

    pub fn get_secret_map(&self, secret_id: &str) -> Result<HashMap<String, String>> {
        self.rt.block_on(self.client.get_secret_map(secret_id))
    }

    pub fn get_secret_value(&self, secret_id: &str) -> Result<Vec<u8>> {
        self.rt.block_on(self.client.get_secret_value(secret_id))
    }
}

#[derive(Debug, Clone)]
pub struct AsmClientAsync {
    client: aws_sdk_secretsmanager::Client,
}

impl AsmClientAsync {
    pub fn new(client: aws_sdk_secretsmanager::Client) -> Self {
        Self { client }
    }

    pub async fn get_secret_list(&self, secret_id: &str) -> Result<Vec<AsmSecretValue>> {
        let secret = self.get_secret(secret_id).await?;
        if let Some(secret_string) = secret.secret_string {
            return Ok(vec![AsmSecretValue {
                string: Some(secret_string),
                ..Default::default()
            }]);
        }
        if let Some(secret_binary) = secret.secret_binary {
            return Ok(vec![AsmSecretValue {
                binary: Some(secret_binary.into_inner()),
                ..Default::default()
            }]);
        }
        Err(anyhow!("secret with ID {} has no value", secret_id))
    }

    pub async fn get_secret_map(&self, secret_id: &str) -> Result<HashMap<String, String>> {
        let secret = self.get_secret_value(secret_id).await?;
        let map: HashMap<String, String> = serde_json::from_slice(&secret)?;
        Ok(map)
    }

    pub async fn get_secret_value(&self, secret_id: &str) -> Result<Vec<u8>> {
        let secret = self.get_secret(secret_id).await?;
        if let Some(secret_string) = secret.secret_string {
            return Ok(secret_string.into_bytes());
        }
        if let Some(secret_binary) = secret.secret_binary {
            let bytes = secret_binary.into_inner();
            return Ok(bytes);
        }
        Err(anyhow!("secret with ID {} has no value", secret_id))
    }

    pub async fn get_secret(&self, secret_id: &str) -> Result<GetSecretValueOutput> {
        let value = self
            .client
            .get_secret_value()
            .secret_id(secret_id)
            .send()
            .await
            .map_err(|e| {
                anyhow!(
                    "failed to get secret {} from Secrets Manager: {}",
                    secret_id,
                    e.into_service_error()
                )
            })?;
        Ok(value)
    }
}

#[derive(Debug, Default)]
pub struct AsmSecretValue {
    pub binary: Option<Vec<u8>>,
    pub string: Option<String>,
}

impl Read for AsmSecretValue {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if let Some(binary) = &mut self.binary {
            let bread = binary.as_slice().read(buf)?;
            *binary = binary[bread..].to_vec();
            Ok(bread)
        } else if let Some(string) = &mut self.string {
            let bread = string.as_bytes().read(buf)?;
            *string = string[bread..].to_string();
            Ok(bread)
        } else {
            Ok(0)
        }
    }
}

impl Writable for AsmSecretValue {
    fn is_secret(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        ""
    }
}
