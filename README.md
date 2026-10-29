# AWS Lab Automation Scripts

PowerShell automation scripts for AWS Academy labs — covering VPC, EC2, EBS, RDS, EFS, Lambda, Elastic Beanstalk, IAM, ELB/ASG, CloudFormation, High Availability, and Café Scalable environments.

## Labs Covered

| Script | Lab |
|---|---|
| `lab.ps1` | Lab 1 – VPC & EC2 Foundations |
| `lab3.ps1` | Lab 3 – EC2 & Storage |
| `lab4.ps1` | Lab 4 – EBS Volumes |
| `lab5.ps1` | Lab 5 – Load Balancing & Auto Scaling |
| `lab6.ps1` | Lab 6 – Advanced Networking |
| `cfn_lab.ps1` | Guided Lab – Automating Infrastructure Deployment with AWS CloudFormation |
| `ha_lab.ps1` | Guided Lab – Creating a Highly Available Environment |
| `cafe_ha_lab.ps1` | Challenge Lab – Creating a Scalable and Highly Available Environment for the Café |
| `rds_lab.ps1` | Guided Lab – Creating an Amazon RDS Database |
| `migration_lab.ps1` | Challenge Lab – Migrating a Database to Amazon RDS |
| `efs_lab.ps1` | Lab – Amazon EFS |
| `lambda_lab.ps1` | Lab – AWS Lambda |
| `beanstalk_lab.ps1` | Lab – AWS Elastic Beanstalk |
| `iam_lab.ps1` | Lab – AWS IAM |
| `cafe_lab.ps1` | Lab – Café Application Deployment |
| `dynamic_cafe_lab.ps1` | Lab – Dynamic Café Application |
| `add_records.ps1` | Utility – Add DB Records |
| `verify_final.ps1` | Utility – Verify Final Architecture |

Cleanup scripts (`cleanup*.ps1`) tear down resources created by each lab.

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed
- [PowerShell 5.1+](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- AWS credentials set as **environment variables** (never hardcode them):

```powershell
$env:AWS_ACCESS_KEY_ID     = "your-access-key-id"
$env:AWS_SECRET_ACCESS_KEY = "your-secret-access-key"
$env:AWS_SESSION_TOKEN     = "your-session-token"   # if using temporary credentials
```

## Usage

Set your credentials, then run the desired lab script:

```powershell
# Example: run the CloudFormation lab
.\cfn_lab.ps1
```

To clean up resources after a lab:

```powershell
.\cleanup_cfn.ps1
```

## Security Note

> **Never commit AWS credentials to version control.**  
> All scripts use `$env:AWS_*` environment variables. Temporary credentials expire automatically.

## License

MIT
