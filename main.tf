provider "aws" {
  region = "eu-north-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  owners = ["099720109477"] # Canonical
}

#Define IAM instance profile data block to get the ARN of the IAM role for the EC2 instance

data "aws_iam_instance_profile" "ECSInstanceProfile" {
  name = "Session_management_role"
}

resource "aws_instance" "xibo-server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.public-1.id
  vpc_security_group_ids = [aws_security_group.all-out-no-in.id]
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  iam_instance_profile = data.aws_iam_instance_profile.ECSInstanceProfile.name

  tags = {
    Name = "xibo"
  }
  user_data = <<-EOF
#!/bin/bash
set -e
apt update -y && apt upgrade -y
apt install ca-certificates curl -y
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
tee /etc/apt/sources.list.d/docker.sources <<DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER
apt update -y
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
usermod -aG docker ubuntu
mkdir -p /opt/xibo
cd /opt/xibo
wget https://xibosignage.com/api/downloads/cms
tar --strip-components=1 -xf cms
rm cms
cp config.env.template config.env
DB_PASSWORD=$(openssl rand -base64 16)
sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$DB_PASSWORD|" config.env
sed -i '/^CMS_SMTP_/s/^/#/' config.env
sed -i 's|^CMS_SERVER_NAME=.*|CMS_SERVER_NAME=xibo.salo-ua.com|' config.env
docker compose up -d
EOF
}

resource "aws_vpc" "xibo-vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "xibo"
  }
}

resource "aws_subnet" "public-1" {
  vpc_id     = aws_vpc.xibo-vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = "eu-north-1a"

  tags = {
    Name = "public-subnet-1"
  }
}

resource "aws_subnet" "public-2" {
  vpc_id     = aws_vpc.xibo-vpc.id
  cidr_block = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone = "eu-north-1b"

  tags = {
    Name = "public-subnet-2"
  }
}

resource "aws_internet_gateway" "xibo-gateway" {
  vpc_id = aws_vpc.xibo-vpc.id

  tags = {
    Name = "xibo-gateway"
  }
}

resource "aws_route_table" "xibo-route-table" {
  vpc_id = aws_vpc.xibo-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.xibo-gateway.id
  }
}

resource "aws_route_table_association" "xibo-route-table-association" {
  subnet_id      = aws_subnet.public-1.id
  route_table_id = aws_route_table.xibo-route-table.id
}

resource "aws_route_table_association" "xibo-route-table-association-2" {
  subnet_id      = aws_subnet.public-2.id
  route_table_id = aws_route_table.xibo-route-table.id
}

  resource "aws_security_group" "all-out-no-in" {
  name        = "all-out-no-in"
  description = "Allow no inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.xibo-vpc.id

  tags = {
    Name = "all-out-no-in"
  }
}

resource "aws_security_group" "ALB_https" {
  name        = "ALB_https"
  description = "Allow HTTPS traffic for ALB"
  vpc_id      = aws_vpc.xibo-vpc.id
}

resource "aws_vpc_security_group_ingress_rule" "allow_https" {
  security_group_id = aws_security_group.ALB_https.id
  cidr_ipv4         = aws_vpc.xibo-vpc.cidr_block
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "allow_tcp" {
  security_group_id = aws_security_group.all-out-no-in.id
  referenced_security_group_id = aws_security_group.ALB_https.id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "allow_xmr" {
  security_group_id = aws_security_group.all-out-no-in.id
  cidr_ipv4         = aws_vpc.xibo-vpc.cidr_block
  from_port         = 9505
  ip_protocol       = "tcp"
  to_port           = 9505
}

resource "aws_vpc_security_group_egress_rule" "allow_all_out" {
  security_group_id = aws_security_group.all-out-no-in.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_vpc_security_group_egress_rule" "allow_all_out_alb" {
  security_group_id = aws_security_group.ALB_https.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_lb" "xibo-alb" {
  name               = "xibo-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ALB_https.id]
  subnets            = [aws_subnet.public-1.id, aws_subnet.public-2.id]

  tags = {
    Name = "xibo-alb"
  }
}

resource "aws_lb_target_group" "xibo-alb-tg" {
  name        = "xibo-alb-tg"
  port        = 80
  protocol    = "HTTP"
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  vpc_id      = aws_vpc.xibo-vpc.id
}

resource "aws_lb_target_group_attachment" "xibo-alb-tg-attachment" {
  target_group_arn = aws_lb_target_group.xibo-alb-tg.arn
  target_id        = aws_instance.xibo-server.id
  port             = 80
}

data "aws_acm_certificate" "issued" {
  domain   = "xibo.salo-ua.com"
  statuses = ["ISSUED"]
}

resource "aws_lb_listener" "xibo-alb-listener" {
  load_balancer_arn = aws_lb.xibo-alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = data.aws_acm_certificate.issued.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.xibo-alb-tg.arn
  }
}

#Windows EC2 instance to host the Player App

data "aws_ami" "windows" {
  most_recent = true

  filter {
    name = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  owners = ["801119661308"] # Windows
}

#aws key pair for the Windows instance

resource "aws_key_pair" "windows-key" {
  key_name   = "windows-key"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC/3kIMwJK3DmARu5aIquhAND9SNwaAp9h4CbX0k6EVXM4XoM+7bmLaFBktQd/hG8/C5FgG81s/e5wqGQ24b5H4ljJq2Wxz3NwdTKoARWj85si+uiWEAejGwdJ2ZTrS4nSgQt0og/5tA/BAm4rCY65xny6IsuuPFEYGph0uvvDpyfgkIhn5JNKlIbRqvOYWTeJlASe5523ZAl5SktUzsyMiYPE9XKe4KQG1FIyBL5e+JCY3P1FoWpYSpiGDYVcL07Zjmkbcn1CU29GDUUhQYekqd8NTrA6R2739KvOh2iHigkSVHArrWkno6RYsiwzqZAodzFkKN0ZS5VgC47PTm4Id windows-key-pair"
}

resource "aws_instance" "windows-server" {
  ami           = data.aws_ami.windows.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.public-1.id
  vpc_security_group_ids = [aws_security_group.all-out-no-in.id]
  key_name = aws_key_pair.windows-key.key_name
  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }
  iam_instance_profile = data.aws_iam_instance_profile.ECSInstanceProfile.name

  tags = {
    Name = "windows-server"
  }
}

#Cloudflare provider & resource configuration

provider "cloudflare" {
  #API token will be read from the environment variable CLOUDFLARE_API_TOKEN
}

variable "zone_id" {
  description = "The Cloudflare zone ID for the domain"
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "The Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "The domain name for the Cloudflare zone"
  type        = string
  sensitive   = true
}

resource "cloudflare_dns_record" "xibo-alb-record" {
  zone_id = var.zone_id
  name    = "xibo"
  content   = aws_lb.xibo-alb.dns_name
  type    = "CNAME"
  ttl     = 60
  proxied = false
  comment = "CNAME record for xibo.salo-ua.com pointing to the ALB"
}

