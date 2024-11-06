use std::{
    collections::HashMap,
    io::{self, Read},
    sync::Arc,
};

use anyhow::{anyhow, Result};
use log::debug;
use minaws::{
    imds::{Credentials, Imds},
    s3::{self, GetObjectInput, GetObjectOutput, Object},
};

use crate::writable::Writable;

pub struct S3Client {
    api: Arc<s3::Api>,
}

impl S3Client {
    pub fn new(credentials: Credentials, region: &str) -> Result<Self> {
        let api = s3::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn from_imds(imds: &Imds, region: &str) -> Result<Self> {
        let credentials = imds.get_credentials()?;
        let api = s3::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn get_object_list(&self, bucket: &str, key_prefix: &str) -> Result<Vec<S3Object>> {
        let objects = self.list_objects(bucket, key_prefix)?;
        Ok(self.to_list(objects.as_slice(), bucket, key_prefix))
    }

    pub fn get_object_map(&self, bucket: &str, key: &str) -> Result<HashMap<String, String>> {
        let object = self.get_object(bucket, key)?;
        let map: HashMap<String, String> = serde_json::from_reader(object.body)?;
        Ok(map)
    }

    pub fn get_object_bytes(&self, bucket: &str, key: &str) -> Result<Vec<u8>> {
        let mut object = self.get_object(bucket, key)?;
        let mut buf = Vec::new();
        let _ = object.body.read(&mut buf)?;
        Ok(buf)
    }

    fn get_object(&self, bucket: &str, key: &str) -> Result<GetObjectOutput> {
        self.api
            .get_object(s3::GetObjectInput::default().bucket(bucket).key(key))
            .map_err(|e| {
                let s3_url = format!("s3://{}/{}", bucket, key);
                anyhow!("unable to get object at {}: {}", s3_url, e)
            })
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
                    api: self.api.clone(),
                    bucket: bucket.into(),
                    key: key.into(),
                    object: None,
                    path_suffix,
                };
                list.push(s3_object);
            }
        }
        list
    }

    fn list_objects(&self, bucket: &str, key_prefix: &str) -> Result<Vec<Object>> {
        let mut objects = Vec::new();
        let mut continuation_token: Option<String> = None;
        loop {
            let mut input = s3::ListObjectsV2Input::default()
                .bucket(bucket)
                .prefix(key_prefix);
            if let Some(token) = continuation_token {
                input = input.continuation_token(&token);
            }
            let s3_url = format!("s3://{}/{}", bucket, key_prefix);
            let out = self
                .api
                .list_objects_v2(input)
                .map_err(|e| anyhow!("unable to list objects at {}: {}", s3_url, e))?;
            let contents = out
                .contents
                .ok_or_else(|| anyhow!("no objects found at {}", s3_url))?;
            objects.extend(contents);
            if let Some(false) = out.is_truncated {
                break;
            }
            continuation_token = out.continuation_token;
        }
        Ok(objects)
    }
}

#[derive(Debug)]
pub struct S3Object {
    api: Arc<s3::Api>,
    bucket: String,
    key: String,
    object: Option<GetObjectOutput>,
    path_suffix: String,
}

impl S3Object {
    fn download(&mut self) -> Result<()> {
        if self.object.is_none() {
            debug!("downloading s3://{}/{}", self.bucket, self.key);
            let object = self.api.get_object(
                GetObjectInput::default()
                    .bucket(&self.bucket)
                    .key(&self.key),
            )?;
            self.object = Some(object);
        }
        Ok(())
    }
}

impl Read for S3Object {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.download().map_err(|e| {
            let s3_url = format!("s3://{}/{}", self.bucket, self.key);
            io::Error::new(
                io::ErrorKind::Other,
                format!("unable to download S3 object {}: {}", s3_url, e),
            )
        })?;
        debug!("reading from S3 object s3://{}/{}", self.bucket, self.key);
        self.object.as_mut().unwrap().body.read(buf)
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
