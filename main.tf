provider "aws" {
  region = var.region
}

# VPC
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.stage}-vpc" }
}

# Single public subnet — Fargate task gets a public IP directly, no NAT needed
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = { Name = "${var.stage}-public-subnet" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.stage}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.stage}-public-rt" }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security group for Flowise — restrict ingress to your IP via var.allowed_cidr
resource "aws_security_group" "container_sg" {
  name        = "${var.stage}-container-sg"
  description = "Flowise access"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for EFS — only allow NFS from the container
resource "aws_security_group" "efs_sg" {
  name        = "${var.stage}-efs-sg"
  description = "NFS access for EFS"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.container_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EFS — persists Flowise data (flows, credentials, agents) across task restarts
resource "aws_efs_file_system" "this" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = { Name = "${var.stage}-efs" }
}

resource "aws_efs_mount_target" "efs_mt" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.efs_sg.id]
}

# IAM — task execution role for ECR image pull, CloudWatch logs, and EFS mount
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.stage}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_execution_policy" {
  name = "ecs-task-execution-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeFileSystems"
        ]
        Resource = aws_efs_file_system.this.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "flowise" {
  name              = "/ecs/${var.stage}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "this" {
  name = "${var.stage}-ecs-cluster"
}

resource "aws_ecs_task_definition" "flowise" {
  family                   = "${var.stage}-flowise-task"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"

  container_definitions = jsonencode([{
    name      = "flowise"
    image     = "flowiseai/flowise:latest"
    essential = true

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    environment = [
      { name = "PORT", value = "3000" }
    ]

    entryPoint = ["flowise", "start"]

    mountPoints = [{
      sourceVolume  = "efs-volume"
      containerPath = "/root/.flowise"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.stage}"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "flowise"
      }
    }
  }])

  volume {
    name = "efs-volume"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
    }
  }
}

resource "aws_ecs_service" "flowise" {
  name            = "${var.stage}-flowise-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.flowise.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.container_sg.id]
    assign_public_ip = true
  }

  depends_on = [aws_efs_mount_target.efs_mt]
}

output "get_flowise_ip" {
  description = "Run after deployment to get the Flowise URL"
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --region ${var.region} --output text --query 'taskArns[0]' | xargs -I{} aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --region ${var.region} --tasks {} --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --region ${var.region} --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}
