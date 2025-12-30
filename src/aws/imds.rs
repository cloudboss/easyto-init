use anyhow::{Result, anyhow};
use aws_config::imds::client::{
    SensitiveString,
    error::{ErrorResponse, ImdsError},
};
use crossbeam::utils::Backoff;
use std::time::{Duration, Instant};
use tokio::runtime::Handle;

#[derive(Clone, Debug)]
pub struct ImdsClient {
    rt: Handle,
    client: ImdsClientAsync,
}

impl ImdsClient {
    pub fn new(rt: Handle, client: aws_config::imds::Client) -> Self {
        let client_async = ImdsClientAsync::new(client);
        Self {
            rt,
            client: client_async,
        }
    }

    pub fn client_async(&self) -> &ImdsClientAsync {
        &self.client
    }

    pub fn get_user_data(&self) -> Result<Option<String>> {
        self.rt.block_on(self.client.get_user_data())
    }

    pub fn get_ssh_key(&self) -> Result<Option<SensitiveString>> {
        self.rt.block_on(self.client.get_ssh_key())
    }

    pub fn get_metadata(&self, path: &str) -> Result<SensitiveString> {
        self.rt.block_on(self.client.get_metadata(path))
    }
}

#[derive(Clone, Debug)]
pub struct ImdsClientAsync {
    client: aws_config::imds::Client,
}

impl ImdsClientAsync {
    pub fn new(client: aws_config::imds::Client) -> Self {
        Self { client }
    }

    pub async fn get_user_data(&self) -> Result<Option<String>> {
        match self.client.get("/latest/user-data").await {
            Ok(resp) => Ok(Some(resp.into())),
            Err(ImdsError::ErrorResponse(e)) if self.is_not_found(&e) => Ok(None),
            Err(e) => Err(anyhow!("failed to get user data: {}", e)),
        }
    }

    pub async fn get_ssh_key(&self) -> Result<Option<SensitiveString>> {
        match self
            .client
            .get("/latest/meta-data/public-keys/0/openssh-key")
            .await
        {
            Ok(resp) => Ok(Some(resp)),
            Err(ImdsError::ErrorResponse(e)) if self.is_not_found(&e) => Ok(None),
            Err(e) => Err(anyhow!("failed to get ssh public key: {}", e)),
        }
    }

    pub async fn get_metadata(&self, path: &str) -> Result<SensitiveString> {
        let full_path = format!("/latest/meta-data/{}", path);
        self.client
            .get(&full_path)
            .await
            .map_err(|e| anyhow!("failed to get {} from IMDS: {}", &full_path, e))
    }

    pub async fn wait_for(&self, timeout: Duration) -> Result<()> {
        let start = Instant::now();
        let backoff = Backoff::new();
        let path = "/latest/meta-data/instance-id";
        loop {
            match self.client.get(path).await {
                Ok(_) => return Ok(()),
                Err(e) => {
                    if start.elapsed() >= timeout {
                        return Err(anyhow!("failed to wait for IMDS: {}", e));
                    }
                    backoff.snooze();
                }
            }
        }
    }

    fn is_not_found(&self, error: &ErrorResponse) -> bool {
        error.response().status().as_u16() == 404
    }
}
