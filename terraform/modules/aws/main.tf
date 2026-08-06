data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Second layer of origin lockdown: the prefix list above is CloudFront's IP range, but that
# range is shared across every CloudFront distribution on AWS, not just this one. This secret
# is injected as a custom origin header by CloudFront and checked by an ALB listener rule
# below, so a request that merely originates from *a* CloudFront IP isn't enough -- it has to
# have come through *this* distribution specifically.
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

# --- Networking ---

resource "aws_vpc" "quest" {
  cidr_block           = "10.70.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "quest-vpc" })
}

resource "aws_internet_gateway" "quest" {
  vpc_id = aws_vpc.quest.id
  tags   = var.tags
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.quest.id
  cidr_block              = cidrsubnet(aws_vpc.quest.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "quest-public-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.quest.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.quest.id
  }

  tags = var.tags
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb" {
  name        = "quest-alb"
  description = "Allow inbound HTTP from CloudFront"
  vpc_id      = aws_vpc.quest.id
  tags        = var.tags

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "service" {
  name        = "quest-service"
  description = "Allow inbound app traffic from the ALB only"
  vpc_id      = aws_vpc.quest.id
  tags        = var.tags

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Load balancer ---

resource "aws_lb" "quest" {
  name               = "quest-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = var.tags
}

resource "aws_lb_target_group" "quest" {
  name        = "quest-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.quest.id
  target_type = "ip"
  tags        = var.tags

  health_check {
    path = "/"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.quest.arn
  port              = 80
  protocol          = "HTTP"

  # Default-deny: only requests carrying the CloudFront-injected secret header (matched by
  # the rule below) get forwarded. Anything else -- including direct requests to the ALB's
  # own DNS name, which the prefix-list-restricted security group above doesn't stop on its
  # own -- gets a flat 403.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Forbidden"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.quest.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

# --- Logging ---

resource "aws_cloudwatch_log_group" "quest" {
  name              = "/ecs/quest"
  retention_in_days = 30
  tags              = var.tags
}

# --- Secret ---

resource "aws_secretsmanager_secret" "secret_word" {
  name = "quest/secret_word"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "secret_word" {
  secret_id     = aws_secretsmanager_secret.secret_word.id
  secret_string = var.secret_word
}

# --- ECS ---

resource "aws_ecs_cluster" "quest" {
  name = "quest-cluster"
  tags = var.tags
}

resource "aws_iam_role" "execution" {
  name = "quest-ecs-execution"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "quest-ecs-execution-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.secret_word.arn]
    }]
  })
}

resource "aws_ecs_task_definition" "quest" {
  family                   = "quest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  tags                     = var.tags

  container_definitions = jsonencode([
    {
      name      = "quest"
      image     = var.image
      essential = true
      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.quest.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "quest"
        }
      }
      secrets = [
        {
          name      = "SECRET_WORD"
          valueFrom = aws_secretsmanager_secret.secret_word.arn
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "quest" {
  name            = "quest"
  cluster         = aws_ecs_cluster.quest.id
  task_definition = aws_ecs_task_definition.quest.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  tags            = var.tags

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.quest.arn
    container_name   = "quest"
    container_port   = var.app_port
  }

  depends_on = [aws_lb_listener.http]
}

# --- CloudFront (TLS + managed cert on the default *.cloudfront.net domain) ---

resource "aws_cloudfront_distribution" "quest" {
  enabled = true
  tags    = var.tags

  origin {
    domain_name = aws_lb.quest.dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # ALB sets X-Forwarded-Proto from its own listener protocol (HTTP here), which would
    # overwrite this. Injecting it as an origin custom header is CloudFront's workaround —
    # verify against the live ALB that this survives (see docs/plan.md risk note).
    custom_header {
      name  = "X-Forwarded-Proto"
      value = "https"
    }

    # Checked by the aws_lb_listener_rule above -- proves the request came through this
    # specific CloudFront distribution, not just any client inside CloudFront's IP range.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
