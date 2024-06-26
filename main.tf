terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.53.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC Instanciada en las disponibilidades us-east-1a, 1b, 1c
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ev3-vpc"
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
  name        = "alb_sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Allow SSH-test"
    from_port   = 22
    to_port     = 22
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
    Name        = "alb_sg"
    Environment = "ev-3"
  }
}

# Security group para EC2
resource "aws_security_group" "ec2_sg" {
  name        = "ec2_sg"
  description = "Allow HTTP, HTTPS, SSH, and NFS traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP from ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [ aws_security_group.alb_sg.id ]
  }
  ingress {
    description = "Allow HTTPS from ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [ aws_security_group.alb_sg.id ]
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
    Name        = "ec2_sg"
    Environment = "ev-3"
  }
}

# Security group para EFS
resource "aws_security_group" "efs_sg" {
  name        = "efs_sg"
  description = "Allow NFS traffic from EC2 instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    security_groups = [ aws_security_group.ec2_sg.id ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "efs_sg"
    Environment = "prd"
  }
}

# Creacion del EFS
resource "aws_efs_file_system" "efs" {
  creation_token = "ev3-efs"
}

resource "aws_efs_mount_target" "efs_mount" {
  count             = 3
  file_system_id    = aws_efs_file_system.efs.id
  subnet_id         = element(module.vpc.private_subnets, count.index)
  security_groups   = [aws_security_group.efs_sg.id]
}

# Creacion del Bucket index.php
resource "random_id" "bucket" {
  byte_length = 8
}

resource "aws_s3_bucket" "ev3bucket" {
  bucket = "ev3bucket-${random_id.bucket.hex}"

  tags = {
    Name = "ev3bucket"
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
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": [
        "${aws_s3_bucket.ev3bucket.arn}/*"
      ]
    }]
  })
  depends_on = [ time_sleep.wait_10_seconds ]
}

# Bucket index.php y error.html objects
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.ev3bucket.id
  key          = "index.php"
  source       = "index.php"
  depends_on = [ aws_s3_bucket_policy.ev3bucket ]
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
# EC2 EFS file upload
resource "aws_instance" "ec2_admin" {
  ami                    = "ami-08a0d1e16fc3f61ea"
  instance_type          = "t2.micro"
  key_name               = "vockey"
  subnet_id              = element(module.vpc.private_subnets, 0)
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  depends_on             = [aws_efs_mount_target.efs_mount]

  user_data              = <<-EOF
    #!/bin/bash
    sleep 60
    yum install -y amazon-efs-utils
    mkdir -p /var/www/html/
    echo ${aws_efs_file_system.efs.id}:/ /var/www/html efs _netdev,tls 0 0 >> /etc/fstab
    sudo mount -a
    sleep 30
    wget -O /var/www/html/index.php ${aws_s3_bucket.ev3bucket.bucket}/index.php
  EOF

  tags = {
    Name = "ec2_admin"
  }
}

# Instancias EC2
resource "aws_instance" "ec2-webserver" {
  ami                    = "ami-08a0d1e16fc3f61ea"
  instance_type          = "t2.micro"
  key_name               = "vockey"
  subnet_id              = element(module.vpc.private_subnets, count.index)
  vpc_security_group_ids = [ aws_security_group.ec2_sg.id ]
  # security_groups        = [aws_security_group.ec2_sg.id] #If you are creating Instances in a VPC, use vpc_security_group_ids instead. 
  count                  = 3
  availability_zone      = element(module.vpc.azs, count.index)
  depends_on             = [ aws_efs_mount_target.efs_mount ]
  user_data              = <<-EOF
    #!/bin/bash
    sleep 60
    yum install -y httpd php amazon-efs-utils
    mkdir -p /var/www/html/
    sudo mount -t efs -o tls ${aws_efs_file_system.efs.id}:/ /var/www/html/
    sleep 30
    systemctl start httpd
    systemctl enable httpd
  EOF
  tags = {
    Name = "ec2-webserver ${count.index + 1}"
  }
}

resource "aws_lb_target_group" "alb-tg" {
  name     = "alb-tg"
  target_type = "instance"
  protocol = "HTTP"
  port     = 80
  ip_address_type = "ipv4"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_lb_target_group_attachment" "alb-tg-attachment" {
  count           = 3
  target_group_arn = aws_lb_target_group.alb-tg.arn
  target_id       = aws_instance.ec2-webserver[count.index].id
  port            = 80
}

resource "aws_lb" "ev3_lb" {
  name                   = "ev3-alb"
  internal               = false
  load_balancer_type     = "application"
  security_groups        = [ aws_security_group.alb_sg.id ]
  subnets                = module.vpc.public_subnets
  enable_deletion_protection = false

  tags = {
    Environment = "ev3"
  }
}

resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.ev3_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb-tg.arn
  }
}

output "Bucket_url" {
  value       = aws_s3_bucket_website_configuration.ev3bucket.website_endpoint
  description = "The URL of the index.php file & static website: "
}

output "load_balancer_dns_url" { 
  value = aws_lb.ev3_lb.dns_name 
  description = "The DNS name of the load balancer: " 
}
output "efs_dns_url" { 
  value = aws_efs_file_system.efs.id
  description = "The DNS name of the EFS: " 
}