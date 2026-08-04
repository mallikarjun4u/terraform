terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# 1. SSM Parameter for Latest Amazon Linux 2023 AMI
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# 2. Provider & Variables Configuration
provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "ap-south-2"
}

variable "vpc_name" {
  default = "vpc-3"
}

variable "instance_type" {
  default = "t3.micro"
}

variable "environment" {
  default = "dev"
}

# 3. VPC Module
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 5.8.0"

  name = var.vpc_name
  cidr = "10.0.0.0/16"

  azs = [
    "ap-south-2a",
    "ap-south-2b"
  ]

  public_subnets = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]

  enable_nat_gateway = false

  tags = {
    Environment = var.environment
  }
}

# 4. ALB Security Group Module
module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "alb-security-group"
  description = "Allow HTTP traffic from everywhere"
  vpc_id      = module.vpc.vpc_id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules        = ["all-all"]
}

# 5. EC2 / ASG Security Group Module & Native Ingress Rule
module "ec2_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "ec2-security-group"
  description = "Allow HTTP traffic from ALB only"
  vpc_id      = module.vpc.vpc_id

  egress_rules = ["all-all"]
}

resource "aws_security_group_rule" "ec2_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = module.alb_sg.security_group_id
  security_group_id        = module.ec2_sg.security_group_id
}

# 6. Application Load Balancer (ALB) Module
# 6. Application Load Balancer (ALB) Module
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = ">= 9.11.0"

  name               = "web-alb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]

  target_groups = {
    app = {
      backend_protocol  = "HTTP"
      backend_port      = 80
      target_type       = "instance"
      create_attachment = false  # <-- ఈ లాజిక్ ఎర్రర్‌ని ఫిక్స్ చేస్తుంది (ASG ఆటోమేటిక్‌గా అటాచ్ చేస్తుంది)

      health_check = {
        enabled             = true
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 5
        interval            = 30
      }
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "app"
      }
    }
  }
}

# 7. Launch Template
resource "aws_launch_template" "web" {
  name_prefix   = "web-template-"
  image_id      = data.aws_ssm_parameter.amazon_linux.value
  instance_type = var.instance_type

  network_interfaces {
    associate_public_ip_address = true # <--- ఇది ప్రతీ EC2 కి Public IP ని ఇస్తుంది
    security_groups             = [module.ec2_sg.security_group_id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello World from $(hostname -f)</h1>" > /var/www/html/index.html
              EOF
  )
}
# 8. Auto Scaling Group Module
module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = ">= 8.1.0"

  name = "web-asg"

  min_size         = 2
  max_size         = 4
  desired_capacity = 3

  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "ELB"

  create_launch_template  = false
  launch_template_id      = aws_launch_template.web.id
  launch_template_version = "$Latest"

  traffic_source_attachments = {
    ex-alb = {
      traffic_source_identifier = module.alb.target_groups["app"].arn
      traffic_source_type       = "elbv2"
    }
  }

  tags = {
    Environment = var.environment
  }
}

# 9. Outputs
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "asg_name" {
  value = module.asg.autoscaling_group_name
}

output "public_subnets" {
  value = module.vpc.public_subnets
}
