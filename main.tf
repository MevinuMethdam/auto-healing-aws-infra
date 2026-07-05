terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "auto_healing_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name    = "AutoHealing-VPC"
    Project = "Chaos-Engineering-SRE"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.auto_healing_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = { Name = "AutoHealing-Public-Subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.auto_healing_vpc.id
  tags = { Name = "AutoHealing-IGW" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.auto_healing_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "AutoHealing-Public-RT" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "server_sg" {
  name   = "auto-healing-sg"
  vpc_id = aws_vpc.auto_healing_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # මෙය Drift පරීක්ෂාව සඳහා එකතු කළ රූල් එකයි
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2_monitoring_role" {
  name = "AutoHealing-EC2-Role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_policy" {
  role       = aws_iam_role.ec2_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "AutoHealing-EC2-Profile"
  role = aws_iam_role.ec2_monitoring_role.name
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_launch_template" "app_template" {
  name_prefix   = "auto-healing-template"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.server_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update -y
              wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
              dpkg -i -E ./amazon-cloudwatch-agent.deb
              apt-get install stress -y
              EOF
  )
}

resource "aws_autoscaling_group" "app_asg" {
  vpc_zone_identifier = [aws_subnet.public_subnet.id]
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1

  launch_template {
    id      = aws_launch_template.app_template.id
    version = "$Latest"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "heal.py"
  output_path = "heal.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "AutoHealing-Lambda-Role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_policy" "lambda_ssm_policy" {
  name        = "LambdaSSMCommandPolicy"
  description = "Allow Lambda to send commands via SSM only"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "ssm:SendCommand"
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ssm_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "auto_healer" {
  filename      = "heal.zip"
  function_name = "AutoHealer-Lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "heal.lambda_handler"
  runtime       = "python3.9"
  environment {
    variables = { INSTANCE_ID = "asg-monitoring-server" }
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name                = "AutoHealing-Anomaly-Alarm"
  comparison_operator       = "LessThanLowerOrGreaterThanUpperThreshold"
  evaluation_periods        = "2"
  threshold_metric_id       = "ad1"

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "CPU Utilization (Anomaly Detection)"
    return_data = "true"
  }

  metric_query {
    id          = "m1"
    return_data = "true"
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = "60"
      stat        = "Average"
      dimensions  = { AutoScalingGroupName = aws_autoscaling_group.app_asg.name }
    }
  }
}

resource "aws_cloudwatch_event_rule" "alarm_rule" {
  name = "Trigger-Auto-Healer"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail      = { alarmName = ["AutoHealing-Anomaly-Alarm"], state = { value = ["ALARM"] } }
  })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.alarm_rule.name
  arn  = aws_lambda_function.auto_healer.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_healer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_rule.arn
}