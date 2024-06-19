terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.53.0" # Ajusta la versión según tus necesidades
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC Instanciada en las disponibilidades us-east-1a, 1b, 1c
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}

# Security group para ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "alb-sg"
    Environment = "prd"
  }
}

# Security group para EC2
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"
  description = "Allow HTTP, HTTPS, SSH, and NFS traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP from ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "Allow HTTPS from ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Se recomienda restringir esto a la IP del administrador
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ec2-sg"
    Environment = "prd"
  }
}

# Regla de ingreso para permitir NFS desde EC2 a EFS
resource "aws_security_group_rule" "efs_sg_ingress" {
  type              = "ingress"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  security_group_id = aws_security_group.efs_sg.id
  source_security_group_id = aws_security_group.ec2_sg.id
  description       = "Allow NFS from EC2 instances"
}

# Regla de ingreso para permitir NFS desde EFS a EC2
resource "aws_security_group_rule" "ec2_sg_ingress" {
  type              = "ingress"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  security_group_id = aws_security_group.ec2_sg.id
  source_security_group_id = aws_security_group.efs_sg.id
  description       = "Allow NFS from EFS"
}

# Security group para EFS
resource "aws_security_group" "efs_sg" {
  name        = "efs-sg"
  description = "Allow NFS traffic from EC2 instances"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "efs-sg"
    Environment = "prd"
  }
}

# Creacion del EFS
resource "aws_efs_file_system" "efs" {
  creation_token = "ejemplo-efs"
}

resource "aws_efs_mount_target" "efs_mount" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = element(module.vpc.public_subnets, 0)
  security_groups = [aws_security_group.efs_sg.id]
}

# Bucket index.php
resource "random_id" "bucket" {
  byte_length = 8
}

resource "aws_s3_bucket" "ev3bucket" {
  bucket = "ev3bucket-${random_id.bucket.hex}"

  tags = {
    Name = "ev3bucket-${random_id.bucket.hex}"
  }
}

resource "aws_s3_bucket_public_access_block" "ev3bucket" {
  bucket = aws_s3_bucket.ev3bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "time_sleep" "wait_10_seconds" {
  depends_on      = [aws_s3_bucket.ev3bucket]
  create_duration = "10s"
}

resource "aws_s3_bucket_policy" "ev3bucket" {
  bucket     = aws_s3_bucket.ev3bucket.id
  policy     = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "PublicRead",
        Effect = "Allow",
        Principal = "*",
        Action = ["s3:GetObject"],
        Resource = [aws_s3_bucket.ev3bucket.arn],
      },
    ],
  })
  depends_on = [time_sleep.wait_10_seconds]
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.ev3bucket.id
  key          = "index.php"
  source       = "index.php"
  content_type = "text/html"
}

resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.ev3bucket.id
  key          = "error.html"
  source       = "error.html"
  content_type = "text/html"
}

resource "aws_s3_bucket_website_configuration" "ev3bucket" {
  bucket = aws_s3_bucket.ev3bucket.id

  index_document {
    suffix = "index.php"
  }
  error_document {
    key = "error.html"
  }

}

# Instancias EC2
resource "aws_instance" "ec2-webserver" {
  ami                    = "ami-08a0d1e16fc3f61ea"
  instance_type          = "t2.micro"
  key_name               = "vockey"
  subnet_id              = element(module.vpc.private_subnets, count.index)
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  count                  = 3
  availability_zone      = element(module.vpc.azs, count.index)
  depends_on             = [aws_efs_mount_target.efs_mount]
  user_data              = <<-EOF
    #!/bin/bash
    yum install -y amazon-efs-utils
    mkdir /mnt/efs
    mount -t efs -o tls ${aws_efs_file_system.efs.id}:/ /mnt/efs
    aws s3 cp s3://${aws_s3_bucket.ev3bucket.website_endpoint}/index.php /var/www/html/index.php #
  EOF 
  tags = {
    Name = "ec2-webserver ${count.index + 1}"
  }
  #The attribute "website_endpoint" is deprecated. Refer to the provider documentation for details.
}

output "url" {
  value       = aws_s3_bucket_website_configuration.ev3bucket.website_endpoint
  description = "The URL of the website"
}
