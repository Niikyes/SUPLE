########################################
# 1️⃣ Provider, VPC, Subnets y Rutas
########################################
provider "aws" {
  region = "us-east-1"
}

locals {
  services = ["svc1","svc2","svc3","svc4","svc5"]
}

resource "aws_vpc" "pr3_vpc" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "PR3-VPC" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.pr3_vpc.id
  cidr_block              = "10.0.10.0/24"        
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "PR3-Public-A" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.pr3_vpc.id
  cidr_block              = "10.0.11.0/24"        
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "PR3-Public-B" }
}


resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.pr3_vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.pr3_vpc.id
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

########################################
# 2️⃣ Key Pair
########################################
resource "tls_private_key" "pr3" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "pr3_key" {
  key_name   = "pr3-key"
  public_key = tls_private_key.pr3.public_key_openssh
}

resource "local_file" "pr3_pem" {
  content  = tls_private_key.pr3.private_key_pem
  filename = "${path.module}/pr3-key.pem"
}

########################################
# 3️⃣ Security Groups
########################################
# SG para los ALBs (HTTP público)
resource "aws_security_group" "alb_sg" {
  name        = "pr3-alb-sg"
  description = "Allow HTTP from Internet"
  vpc_id      = aws_vpc.pr3_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ALB-SG" }
}

# SG para las EC2 (solo SSH abierto)
resource "aws_security_group" "ec2_sg" {
  for_each    = toset(local.services)
  name        = "${each.key}-sg"
  description = "Allow SSH only"
  vpc_id      = aws_vpc.pr3_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = each.key }
}

# Regla para HTTP desde el ALB a las EC2
resource "aws_security_group_rule" "allow_http_from_alb" {
  for_each = toset(local.services)

  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2_sg[each.key].id
  source_security_group_id = aws_security_group.alb_sg.id
}

########################################
# 4️⃣ Target Groups
########################################
resource "aws_lb_target_group" "tg" {
  for_each = toset(local.services)

  name     = "${each.key}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.pr3_vpc.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

########################################
# 5️⃣ Launch Templates & Auto Scaling
########################################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_launch_template" "lt" {
  for_each = toset(local.services)

  name_prefix            = "${each.key}-lt-"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.pr3_key.key_name
  vpc_security_group_ids = [aws_security_group.ec2_sg[each.key].id]

  user_data = base64encode(<<-EOF
#!/bin/bash
apt update -y
apt install -y docker.io
systemctl enable docker
systemctl start docker
docker pull yourdocker/${each.key}:latest
docker run -d --name app -p 80:80 yourdocker/${each.key}:latest
EOF
  )
}

resource "aws_autoscaling_group" "asg" {
  for_each = toset(local.services)

  name_prefix        = "${each.key}-asg-"
  launch_template {
    id      = aws_launch_template.lt[each.key].id
    version = "$Latest"
  }

  min_size         = 2
  max_size         = 2
  desired_capacity = 2

  vpc_zone_identifier = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
  ]

  target_group_arns = [
    aws_lb_target_group.tg[each.key].arn
  ]

  tag {
    key                 = "Name"
    value               = each.key
    propagate_at_launch = true
  }
}

########################################
# 6️⃣ Un Load Balancer por Servicio
########################################
resource "aws_lb" "lb" {
  for_each = toset(local.services)

  name               = "${each.key}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
  ]
}

resource "aws_lb_listener" "listener" {
  for_each          = toset(local.services)
  load_balancer_arn = aws_lb.lb[each.key].arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[each.key].arn
  }
}

########################################
# 🔟 Outputs
########################################
output "alb_dns" {
  description = "DNS de cada Load Balancer por servicio"
  value       = { for svc, lb in aws_lb.lb : svc => lb.dns_name }
}

