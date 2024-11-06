use std::{collections::HashMap, io::Read, sync::Arc};

use anyhow::{anyhow, Result};
use minaws::{
    imds::{Credentials, Imds},
    secretsmanager::{self, GetSecretValueInput, GetSecretValueOutput},
};

use crate::writable::Writable;

#[derive(Debug, Clone)]
pub struct AsmClient {
    api: Arc<secretsmanager::Api>,
}

impl AsmClient {
    pub fn new(credentials: Credentials, region: &str) -> Result<Self> {
        let api = secretsmanager::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn from_imds(imds: &Imds, region: &str) -> Result<Self> {
        let credentials = imds.get_credentials()?;
        let api = secretsmanager::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn get_secret_list(&self, secret_id: &str) -> Result<Vec<AsmSecretValue>> {
        let secret = self.get_secret(secret_id)?;
        if let Some(secret_string) = secret.secret_string {
            return Ok(vec![AsmSecretValue {
                secret_id: secret_id.to_string(),
                string: Some(secret_string),
                ..Default::default()
            }]);
        }
        if let Some(secret_binary) = secret.secret_binary {
            return Ok(vec![AsmSecretValue {
                secret_id: secret_id.to_string(),
                binary: Some(secret_binary),
                ..Default::default()
            }]);
        }
        Err(anyhow!("secret with ID {} has no value", secret_id))
    }

    pub fn get_secret_map(&self, secret_id: &str) -> Result<HashMap<String, String>> {
        let secret = self.get_secret_value(secret_id)?;
        let map: HashMap<String, String> = serde_json::from_slice(&secret)?;
        Ok(map)
    }

    pub fn get_secret_value(&self, secret_id: &str) -> Result<Vec<u8>> {
        let secret = self.get_secret(secret_id)?;
        if let Some(secret_string) = secret.secret_string {
            return Ok(secret_string.into_bytes());
        }
        if let Some(secret_binary) = secret.secret_binary {
            let bytes = secret_binary.to_vec();
            return Ok(bytes);
        }
        Err(anyhow!("secret with ID {} has no value", secret_id))
    }

    pub fn get_secret(&self, secret_id: &str) -> Result<GetSecretValueOutput> {
        let value = self
            .api
            .get_secret_value(GetSecretValueInput::default().secret_id(secret_id))?;
        Ok(value)
    }
}

#[derive(Debug, Default)]
pub struct AsmSecretValue {
    pub secret_id: String,
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
        &self.secret_id
    }
}
