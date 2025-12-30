use anyhow::{Result, anyhow};
use aws_config::{BehaviorVersion, SdkConfig};
use once_cell::sync::OnceCell;
use tokio::runtime::Handle;

use crate::aws::{asm::AsmClient, ec2::Ec2Client, imds::ImdsClient, s3::S3Client, ssm::SsmClient};

#[derive(Debug)]
pub struct AwsCtx {
    rt: Handle,
    config: OnceCell<SdkConfig>,
    asm: OnceCell<AsmClient>,
    ec2: OnceCell<Ec2Client>,
    imds: OnceCell<ImdsClient>,
    s3: OnceCell<S3Client>,
    ssm: OnceCell<SsmClient>,
}

impl AwsCtx {
    pub fn new(rt: Handle) -> Result<Self> {
        Ok(Self {
            rt,
            config: OnceCell::new(),
            asm: OnceCell::new(),
            ec2: OnceCell::new(),
            imds: OnceCell::new(),
            s3: OnceCell::new(),
            ssm: OnceCell::new(),
        })
    }

    pub fn asm(&self) -> Result<&AsmClient> {
        let config = self.config()?;
        let client = aws_sdk_secretsmanager::Client::new(config);
        self.asm
            .get_or_try_init(|| Ok(AsmClient::new(self.rt.clone(), client)))
    }

    pub fn ec2(&self) -> Result<&Ec2Client> {
        let config = self.config()?;
        let client = aws_sdk_ec2::Client::new(config);
        self.ec2
            .get_or_try_init(|| Ok(Ec2Client::new(self.rt.clone(), client)))
    }

    pub fn imds(&self) -> Result<&ImdsClient> {
        let client = aws_config::imds::Client::builder().build();
        self.imds
            .get_or_try_init(|| Ok(ImdsClient::new(self.rt.clone(), client)))
    }

    pub fn s3(&self) -> Result<&S3Client> {
        let config = self.config()?;
        let client = aws_sdk_s3::Client::new(config);
        self.s3
            .get_or_try_init(|| Ok(S3Client::new(self.rt.clone(), client)))
    }

    pub fn ssm(&self) -> Result<&SsmClient> {
        let config = self.config()?;
        let client = aws_sdk_ssm::Client::new(config);
        self.ssm
            .get_or_try_init(|| Ok(SsmClient::new(self.rt.clone(), client)))
    }

    fn config(&self) -> Result<&SdkConfig> {
        self.config.get_or_try_init(|| {
            let config = self.rt.block_on(async {
                let config = aws_config::defaults(BehaviorVersion::v2025_08_07())
                    .load()
                    .await;

                let sts = aws_sdk_sts::Client::new(&config);
                sts.get_caller_identity().send().await.map_err(|e| {
                    anyhow!("user data config requires an IAM instance profile: {}", e)
                })?;

                Ok::<_, anyhow::Error>(config)
            })?;
            Ok(config)
        })
    }
}
