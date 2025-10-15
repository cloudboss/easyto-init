use std::{sync::Arc, time::Duration};

use anyhow::{anyhow, Result};
use crossbeam::utils::Backoff;
use log::debug;
use minaws::{
    ec2::{self, AttachVolumeInput, Filter},
    imds::{Credentials, Imds},
};

use crate::vmspec::EbsVolumeAttachment;

#[derive(Debug)]
pub struct Ec2Client {
    api: Arc<ec2::Api>,
}

impl Ec2Client {
    pub fn new(credentials: Credentials, region: &str) -> Self {
        let api = ec2::Api::new(region, credentials);
        Self { api: api.into() }
    }

    pub fn from_imds(imds: &Imds, region: &str) -> Result<Self> {
        let credentials = imds.get_credentials()?;
        let api = ec2::Api::new(region, credentials);
        Ok(Self { api: api.into() })
    }

    pub fn ensure_ebs_volume_attached(
        &self,
        attachment: &EbsVolumeAttachment,
        device: &str,
        availability_zone: &str,
        instance_id: &str,
    ) -> Result<()> {
        let volume_id = self.wait_for_ebs_volume(attachment, availability_zone)?;
        self.api
            .attach_volume(AttachVolumeInput {
                device: device.into(),
                instance_id: instance_id.into(),
                volume_id: volume_id.clone(),
            })
            .map_err(|e| anyhow!("unable to attach EBS volume: {}", e))?;
        Ok(())
    }

    fn wait_for_ebs_volume(
        &self,
        attachment: &EbsVolumeAttachment,
        availability_zone: &str,
    ) -> Result<String> {
        let mut filters: Vec<Filter> = vec![
            Filter {
                name: "status".into(),
                values: vec!["available".into()],
            },
            Filter {
                name: "availability-zone".into(),
                values: vec![availability_zone.into()],
            },
        ];
        for tag in &attachment.tags {
            if tag.value.is_none() {
                filters.push(Filter {
                    name: "tag-key".into(),
                    values: vec![tag.key.clone()],
                });
            } else {
                filters.push(Filter {
                    name: format!("tag:{}", tag.key.clone()),
                    values: vec![tag.value.clone().unwrap()],
                });
            }
        }
        let start = std::time::Instant::now();
        let timeout = Duration::from_secs(attachment.timeout.unwrap_or(300));
        let backoff = Backoff::new();
        loop {
            let result = self.api.describe_volumes(ec2::DescribeVolumesInput {
                filters: Some(filters.clone()),
                ..Default::default()
            });
            match result {
                Err(e) => debug!("error describing EBS volumes: {}", e),
                Ok(vol_out) => {
                    if let Some(ref volume_set) = vol_out.volumes {
                        if let Some(items) = &volume_set.items {
                            if let Some(volume) = items.first() {
                                if let Some(volume_id) = &volume.volume_id {
                                    debug!("found matching EBS volume: {:?}", volume);
                                    return Ok(volume_id.clone());
                                }
                            }
                        }
                    }
                    debug!("no EBS volume found matching filters: {:?}", filters);
                }
            }
            if start.elapsed() > timeout {
                return Err(anyhow!("timeout waiting for EBS volume to be available"));
            }
            debug!("waiting for EBS volume to be available");
            backoff.snooze();
        }
    }
}
