use std::time::Duration;

use anyhow::{Result, anyhow};
use aws_sdk_ec2::types::Filter;
use crossbeam::utils::Backoff;
use log::debug;
use tokio::runtime::Handle;

use crate::vmspec::EbsVolumeAttachment;

#[derive(Debug)]
pub struct Ec2Client {
    rt: Handle,
    client: Ec2ClientAsync,
}

impl Ec2Client {
    pub fn new(rt: Handle, client: aws_sdk_ec2::Client) -> Self {
        let client_async = Ec2ClientAsync::new(client);
        Self {
            rt,
            client: client_async,
        }
    }

    pub fn ensure_ebs_volume_attached(
        &self,
        attachment: &EbsVolumeAttachment,
        device: &str,
        availability_zone: &str,
        instance_id: &str,
    ) -> Result<()> {
        self.rt.block_on(self.client.ensure_ebs_volume_attached(
            attachment,
            device,
            availability_zone,
            instance_id,
        ))
    }
}

#[derive(Debug)]
pub struct Ec2ClientAsync {
    client: aws_sdk_ec2::Client,
}

impl Ec2ClientAsync {
    pub fn new(client: aws_sdk_ec2::Client) -> Self {
        Self { client }
    }

    pub async fn ensure_ebs_volume_attached(
        &self,
        attachment: &EbsVolumeAttachment,
        device: &str,
        availability_zone: &str,
        instance_id: &str,
    ) -> Result<()> {
        if self
            .ebs_volume_attached(attachment, device, instance_id)
            .await?
        {
            return Ok(());
        }
        let volume_id = self
            .wait_for_ebs_volume(attachment, availability_zone)
            .await?;
        self.client
            .attach_volume()
            .device(device)
            .instance_id(instance_id)
            .volume_id(volume_id)
            .send()
            .await
            .map_err(|e| anyhow!("unable to attach EBS volume: {}", e.into_service_error()))?;
        Ok(())
    }

    async fn ebs_volume_attached(
        &self,
        attachment: &EbsVolumeAttachment,
        device: &str,
        instance_id: &str,
    ) -> Result<bool> {
        let mut desc_vol = self
            .client
            .describe_volumes()
            .filters(
                Filter::builder()
                    .name("attachment.instance-id")
                    .values(instance_id)
                    .build(),
            )
            .filters(
                Filter::builder()
                    .name("attachment.device")
                    .values(device)
                    .build(),
            );
        for tag in &attachment.tags {
            let filters = if let Some(ref value) = tag.value {
                Filter::builder()
                    .name(format!("tag:{}", tag.key))
                    .values(value)
                    .build()
            } else {
                Filter::builder()
                    .name("tag-key")
                    .values(tag.key.clone())
                    .build()
            };
            desc_vol = desc_vol.filters(filters);
        }
        match desc_vol.clone().send().await {
            Ok(vol_out) => {
                if let Some(ref vols) = vol_out.volumes {
                    return Ok(!vols.is_empty());
                }
            }
            Err(e) => {
                return Err(anyhow!(
                    "error describing EBS volumes: {}",
                    e.into_service_error()
                ));
            }
        }
        Ok(false)
    }

    async fn wait_for_ebs_volume(
        &self,
        attachment: &EbsVolumeAttachment,
        availability_zone: &str,
    ) -> Result<String> {
        let mut desc_vol = self
            .client
            .describe_volumes()
            .filters(Filter::builder().name("status").values("available").build())
            .filters(
                Filter::builder()
                    .name("availability-zone")
                    .values(availability_zone)
                    .build(),
            );
        for tag in &attachment.tags {
            let filters = if let Some(ref value) = tag.value {
                Filter::builder()
                    .name(format!("tag:{}", tag.key))
                    .values(value)
                    .build()
            } else {
                Filter::builder()
                    .name("tag-key")
                    .values(tag.key.clone())
                    .build()
            };
            desc_vol = desc_vol.filters(filters);
        }
        let start = std::time::Instant::now();
        let timeout = Duration::from_secs(attachment.timeout.unwrap_or(300));
        let backoff = Backoff::new();
        loop {
            let result = desc_vol.clone().send().await;
            match result {
                Err(e) => debug!("error describing EBS volumes: {}", e.into_service_error()),
                Ok(vol_out) => {
                    if let Some(ref vols) = vol_out.volumes
                        && let Some(volume) = vols.first()
                            && let Some(volume_id) = &volume.volume_id {
                                debug!("found matching EBS volume: {:?}", volume);
                                return Ok(volume_id.clone());
                            }
                    debug!("no EBS volume found matching filters");
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
