provider "aws" {
  region = var.aws_region
}
resource "random_pet" "DB_NAME" {
  prefix = "ssp-greetings"
  length = 2
}
/* Dynamo DB Table */
resource "aws_dynamodb_table" "ssp-greetings" {
  name      = random_pet.DB_NAME.id
  hash_key  = "pid"
  range_key = "createdAt"
  # billing_mode   = "PAY_PER_REQUEST"
  read_capacity  = 20
  write_capacity = 20
  attribute {
    name = "pid"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }
}
data "aws_lb" "load_balancer" {
  name = "default"
}
# s3 bucket where the images are uploaded
resource "random_pet" "upload_bucket_name" {
  prefix = "upload-bucket"
  length = 2
}
resource "aws_s3_bucket" "upload_bucket" {
  bucket        = random_pet.upload_bucket_name.id
  force_destroy = true
}
# Redirect all traffic from the ALB to the target group
data "aws_alb_listener" "front_end" {
  load_balancer_arn = data.aws_lb.load_balancer.arn
  port              = 443
}
resource "random_pet" "target_group_name" {
  prefix = "ssp"
  length = 2
}
resource "aws_alb_target_group" "app" {
  name                 = random_pet.target_group_name.id
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = module.network.aws_vpc.id
  target_type          = "instance"
  deregistration_delay = 30
  health_check {
    healthy_threshold   = "2"
    interval            = "5"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = var.health_check_path
    unhealthy_threshold = "2"
  }
}
resource "aws_lb_listener_rule" "host_based_weighted_routing" {
  listener_arn = data.aws_alb_listener.front_end.arn
  action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.app.arn
  }
  condition {
    host_header {
      values = [for sn in var.service_names : "${sn}.*"]
    }
  }
}
data "template_file" "userdata_script" {
  template = file("userdata.tpl")
  vars = {
    git_url    = var.git_url
    sha        = var.sha
    bucketName = aws_s3_bucket.upload_bucket.id
    DB_NAME    = aws_dynamodb_table.ssp-greetings.id
    branch     = var.branch
  }
}
resource "random_pet" "instances_name" {
  prefix = "ssp"
  length = 2
}
/* Auto Scaling & Launch Configuration */
module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "6.0.0"
  name = random_pet.instances_name.id
  # Launch configuration creation
  launch_template_name      = var.lc_name
  image_id                  = var.iamge_id
  instance_type             = "t2.micro"
  vpc_zone_identifier       = module.network.aws_subnet_ids.app.ids
  security_groups           = [module.network.aws_security_groups.app.id]
  user_data                 = base64encode(data.template_file.userdata_script.rendered)
  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 20
        volume_type           = "gp2"
      }
      }, {
      device_name = "/dev/sda1"
      no_device   = 1
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 30
        volume_type           = "gp2"
      }
    }
  ]
  instance_market_options = {
    market_type = "spot"
  }
  # Auto scaling group creation
  # vpc_zone_identifier       = module.network.aws_subnet_ids.app.ids
  health_check_type         = "EC2"
  min_size                  = 1
  max_size                  = 1
  iam_instance_profile_arn = aws_iam_instance_profile.ssp_profile.arn
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_grace_period = 500
  target_group_arns         = [aws_alb_target_group.app.arn]
  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }
}
resource "aws_iam_instance_profile" "ssp_profile" {
  name = random_pet.instances_name.id
  role = aws_iam_role.ssp-db.name
}
resource "aws_iam_role" "ssp-db" {
  name               = random_pet.instances_name.id
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}
resource "aws_iam_policy" "db_ssp" {
  name = random_pet.instances_name.id
  description = "policy to give dybamodb permissions to ec2"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "VisualEditor0",
        "Effect" : "Allow",
        "Action" : [
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "dynamodb:UpdateTable",
          "iam:GetRole",
          "iam:PassRole",
          "ec2:RunInstances",
          "ec2:CreateTags"
        ],
        "Resource" : "*"
      },
      {
        "Action" : [
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:CreateGrant",
          "kms:ReEncrypt*"
        ],
        "Resource" : "*",
        "Effect" : "Allow"
      },
      {
        "Action" : "kms:Decrypt",
        "Resource" : "*",
        "Effect" : "Allow"
      },
      {
        "Action" : "s3:GetEncryptionConfiguration",
        "Resource" : [
          "${aws_s3_bucket.upload_bucket.arn}",
          "${aws_s3_bucket.upload_bucket.arn}/*"
        ],
        "Effect" : "Allow"
      },
      {
        "Action" : [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ],
        "Resource" : "*",
        "Effect" : "Allow"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "cloudwatch:PutMetricData",
          "ec2:DescribeVolumes",
          "ec2:DescribeTags",
          "ec2:GetEbsEncryptionByDefault",
				  "ec2:EnableEbsEncryptionByDefault",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:CreateLogStream",
          "logs:CreateLogGroup"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ssm:GetParameter"
        ],
        "Resource" : "arn:aws:ssm:*:*:parameter/AmazonCloudWatch-*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ds:CreateComputer",
          "ds:DescribeDirectories"
        ],
        "Resource" : "*"
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "test-attach" {
  role       = aws_iam_role.ssp-db.name
  policy_arn = aws_iam_policy.db_ssp.arn
}