use std::{
    cmp::min,
    collections::HashMap,
    io::{self, Read},
};

use anyhow::{Result, anyhow};
use aws_sdk_s3::{operation::get_object::GetObjectOutput, types::Object};
use log::debug;
use tokio::runtime::Handle;

use crate::writable::Writable;

#[derive(Debug)]
pub struct S3Client {
    rt: Handle,
    client: S3ClientAsync,
}

impl S3Client {
    pub fn new(rt: Handle, client: aws_sdk_s3::Client) -> Self {
        let client_async = S3ClientAsync::new(rt.clone(), client);
        Self {
            rt,
            client: client_async,
        }
    }

    pub fn get_object_list(&self, bucket: &str, key_prefix: &str) -> Result<Vec<S3Object>> {
        self.rt
            .block_on(self.client.get_object_list(bucket, key_prefix))
    }

    pub fn get_object_map(&self, bucket: &str, key: &str) -> Result<HashMap<String, String>> {
        self.rt.block_on(self.client.get_object_map(bucket, key))
    }

    pub fn get_object_bytes(&self, bucket: &str, key: &str) -> Result<Vec<u8>> {
        self.rt.block_on(self.client.get_object_bytes(bucket, key))
    }
}

#[derive(Clone, Debug)]
pub struct S3ClientAsync {
    // Runtime handle intended as a temporary measure to pass to S3Object
    // instances so the materialize() method works.
    rt: Handle,
    client: aws_sdk_s3::Client,
}

impl S3ClientAsync {
    pub fn new(rt: Handle, client: aws_sdk_s3::Client) -> Self {
        Self { rt, client }
    }

    pub async fn get_object_list(&self, bucket: &str, key_prefix: &str) -> Result<Vec<S3Object>> {
        let objects = self.list_objects(bucket, key_prefix).await?;
        Ok(self.to_list(objects.as_slice(), bucket, key_prefix))
    }

    pub async fn get_object_map(&self, bucket: &str, key: &str) -> Result<HashMap<String, String>> {
        let object = self.get_object(bucket, key).await?;
        let bytes = object.body.collect().await?.into_bytes();
        let map: HashMap<String, String> = serde_json::from_slice(&bytes)?;
        Ok(map)
    }

    pub async fn get_object_bytes(&self, bucket: &str, key: &str) -> Result<Vec<u8>> {
        let object = self.get_object(bucket, key).await?;
        let bytes = object.body.collect().await?.into_bytes();
        Ok(bytes.to_vec())
    }

    async fn get_object(&self, bucket: &str, key: &str) -> Result<GetObjectOutput> {
        self.client
            .get_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| {
                let s3_url = format!("s3://{}/{}", bucket, key);
                anyhow!(
                    "unable to get S3 object at {}: {}",
                    s3_url,
                    e.into_service_error()
                )
            })
    }

    async fn list_objects(&self, bucket: &str, key_prefix: &str) -> Result<Vec<Object>> {
        let mut objects = Vec::new();
        let mut continuation_token: Option<String> = None;
        loop {
            let mut req = self
                .client
                .list_objects_v2()
                .bucket(bucket)
                .prefix(key_prefix);
            if let Some(token) = continuation_token {
                req = req.continuation_token(&token);
            }
            let s3_url = format!("s3://{}/{}", bucket, key_prefix);
            let out = req
                .send()
                .await
                .map_err(|e| anyhow!("unable to list S3 objects at {}: {}", s3_url, e))?;
            let contents = out
                .contents
                .ok_or_else(|| anyhow!("no S3 objects found at {}", s3_url))?;
            objects.extend(contents);
            if let Some(false) = out.is_truncated {
                break;
            }
            continuation_token = out.continuation_token;
        }
        Ok(objects)
    }

    fn to_list(&self, objects: &[Object], bucket: &str, key_prefix: &str) -> Vec<S3Object> {
        let mut list = Vec::new();
        for object in objects {
            if let Some(key) = &object.key {
                // Skip any objects that are "folders".
                if key.ends_with("/") {
                    continue;
                }

                if !key.starts_with(key_prefix) {
                    continue;
                }

                // If key and key_prefix are the same, this will result in an empty
                // string, which enables the destination to become the filename
                // instead of directory when calling the write() method on the returned
                // objects. This is a special case for retrieving a single object.
                let mut path_suffix = key.clone();
                path_suffix.drain(..key_prefix.len());
                debug!("path_suffix: {}", &path_suffix);

                let s3_object = S3Object {
                    client: self.clone(),
                    bucket: bucket.into(),
                    key: key.into(),
                    data: None,
                    pos: 0,
                    path_suffix,
                    rt: self.rt.clone(),
                };
                list.push(s3_object);
            }
        }
        list
    }
}

#[derive(Debug)]
pub struct S3Object {
    client: S3ClientAsync,
    bucket: String,
    key: String,
    data: Option<Vec<u8>>,
    pos: usize,
    path_suffix: String,
    rt: Handle,
}

impl S3Object {
    pub fn materialize(&mut self) -> Result<()> {
        if self.data.is_none() {
            debug!("downloading s3://{}/{}", self.bucket, self.key);
            let body = self.rt.block_on(async {
                let object = self.client.get_object(&self.bucket, &self.key).await?;
                let body = object.body.collect().await?.into_bytes().to_vec();
                Ok::<_, anyhow::Error>(body)
            })?;
            self.data = Some(body);
        }
        Ok(())
    }
}

impl Read for S3Object {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let empty: Vec<u8> = vec![];
        let data = self.data.as_ref().unwrap_or(&empty);

        if self.pos >= data.len() {
            return Ok(0);
        }

        let n = min(buf.len(), data.len() - self.pos);
        buf[..n].copy_from_slice(&data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

impl Writable for S3Object {
    fn is_secret(&self) -> bool {
        false
    }

    fn name(&self) -> &str {
        &self.path_suffix
    }
}
