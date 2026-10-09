terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
provider "aws" { region = var.region }

locals {
  name   = var.project
  az     = ["${var.region}a", "${var.region}c"]
  tags   = { Project = local.name, ManagedBy = "terraform" }
}

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}
resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id; tags = local.tags }

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = local.az[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.name}-public-${count.index}" })
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = local.az[count.index]
  tags = merge(local.tags, { Name = "${local.name}-private-${count.index}" })
}

resource "aws_eip" "nat" { count = 1; domain = "vpc"; tags = local.tags }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = local.tags
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.igw.id }
  tags = local.tags
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.nat.id }
  tags = local.tags
}
resource "aws_route_table_association" "pub" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "priv" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags    = local.tags
}
resource "aws_security_group" "app" {
  name   = "${local.name}-app-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = var.app_port; to_port = var.app_port; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags    = local.tags
}
resource "aws_security_group" "data" {
  name   = "${local.name}-data-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 3306; to_port = 3306; protocol = "tcp"; security_groups = [aws_security_group.app.id] }
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; security_groups = [aws_security_group.app.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags    = local.tags
}

# ── S3 (Static) ───────────────────────────────────────
resource "aws_s3_bucket" "static" {
  bucket        = "${local.name}-static-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}
resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
data "aws_caller_identity" "current" {}

# ── WAF ───────────────────────────────────────────────
resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name}-waf"
  scope = "CLOUDFRONT"
  provider = aws.us_east_1
  default_action { allow {} }
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement { managed_rule_group_statement { name = "AWSManagedRulesCommonRuleSet"; vendor_name = "AWS" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "CommonRuleSet"; sampled_requests_enabled = true }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    action { block {} }
    statement { rate_based_statement { limit = 2000; aggregate_key_type = "IP" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "RateLimit"; sampled_requests_enabled = true }
  }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${local.name}-waf"; sampled_requests_enabled = true }
  tags = local.tags
}
provider "aws" { alias = "us_east_1"; region = "us-east-1" }

# ── CloudFront ────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  web_acl_id          = aws_wafv2_web_acl.main.arn
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb-api"
    custom_origin_config { http_port = 80; https_port = 443; origin_protocol_policy = "http-only"; origin_ssl_protocols = ["TLSv1.2"] }
  }
  default_cache_behavior {
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values { query_string = false; cookies { forward = "none" } }
    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values { query_string = true; headers = ["Authorization"]; cookies { forward = "none" } }
    min_ttl     = 0
    default_ttl = 5
    max_ttl     = 30
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }
  tags = local.tags
}

# ── ALB ───────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}
resource "aws_lb_target_group" "app" {
  name        = "${local.name}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health"; interval = 15; healthy_threshold = 2; unhealthy_threshold = 3 }
  tags = local.tags
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.app.arn }
}

# ── ECS Fargate ───────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
  setting { name = "containerInsights"; value = "enabled" }
  tags = local.tags
}
resource "aws_iam_role" "ecs_task" {
  name = "${local.name}-ecs-task-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "ecs_task" {
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({ Version = "2012-10-17"; Statement = [
    { Effect = "Allow"; Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]; Resource = aws_sqs_queue.main.arn },
    { Effect = "Allow"; Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]; Resource = aws_dynamodb_table.main.arn },
    { Effect = "Allow"; Action = ["secretsmanager:GetSecretValue"]; Resource = aws_secretsmanager_secret.db.arn }
  ]})
}
resource "aws_iam_role" "ecs_exec" {
  name = "${local.name}-ecs-exec-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  container_definitions = jsonencode([{
    name      = "app"
    image     = var.app_image
    portMappings = [{ containerPort = var.app_port; protocol = "tcp" }]
    environment = [
      { name = "REDIS_ENDPOINT", value = aws_elasticache_replication_group.redis.primary_endpoint_address },
      { name = "SQS_URL",        value = aws_sqs_queue.main.url },
      { name = "DYNAMO_TABLE",   value = aws_dynamodb_table.main.name }
    ]
    secrets = [{ name = "DB_SECRET", valueFrom = aws_secretsmanager_secret.db.arn }]
    logConfiguration = { logDriver = "awslogs"; options = { "awslogs-group" = "/ecs/${local.name}"; "awslogs-region" = var.region; "awslogs-stream-prefix" = "app" } }
  }])
  tags = local.tags
}
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
  tags              = local.tags
}
resource "aws_ecs_service" "app" {
  name            = "${local.name}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 3
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
  load_balancer { target_group_arn = aws_lb_target_group.app.arn; container_name = "app"; container_port = var.app_port }
  depends_on = [aws_lb_listener.http]
  tags = local.tags
}

# ── Auto Scaling (ECS) ────────────────────────────────
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 200
  min_capacity       = 3
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 60.0
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
  }
}
resource "aws_appautoscaling_policy" "sqs" {
  name               = "${local.name}-sqs-scaling"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 30
    metric_aggregation_type = "Maximum"
    step_adjustment { metric_interval_lower_bound = 0; metric_interval_upper_bound = 5000; scaling_adjustment = 10 }
    step_adjustment { metric_interval_lower_bound = 5000; scaling_adjustment = 50 }
  }
}
resource "aws_cloudwatch_metric_alarm" "sqs_depth" {
  alarm_name          = "${local.name}-sqs-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1000
  dimensions          = { QueueName = aws_sqs_queue.main.name }
  alarm_actions       = [aws_appautoscaling_policy.sqs.arn]
  tags                = local.tags
}

# ── SQS ───────────────────────────────────────────────
resource "aws_sqs_queue" "dlq"  { name = "${local.name}-dlq";  sqs_managed_sse_enabled = true; tags = local.tags }
resource "aws_sqs_queue" "main" {
  name                       = "${local.name}-queue"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn; maxReceiveCount = 5 })
  tags = local.tags
}

# ── ElastiCache Redis ─────────────────────────────────
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name}-redis-subnet"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${local.name}-redis"
  description                = "Redis cluster for ${local.name}"
  node_type                  = "cache.r7g.large"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.data.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  tags                       = local.tags
}

# ── Aurora MySQL ──────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_secretsmanager_secret" "db" { name = "${local.name}-db-secret"; tags = local.tags }
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "admin", password = var.db_password })
}
resource "aws_rds_cluster" "main" {
  cluster_identifier      = "${local.name}-aurora"
  engine                  = "aurora-mysql"
  engine_version          = "8.0.mysql_aurora.3.05.2"
  database_name           = local.name
  master_username         = "admin"
  master_password         = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.data.id]
  storage_encrypted       = true
  backup_retention_period = 7
  skip_final_snapshot     = true
  tags                    = local.tags
}
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name}-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.r7g.large"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
  tags               = local.tags
}
resource "aws_rds_cluster_instance" "reader" {
  count              = 2
  identifier         = "${local.name}-reader-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.r7g.large"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
  tags               = local.tags
}

# ── DynamoDB ──────────────────────────────────────────
resource "aws_dynamodb_table" "main" {
  name         = "${local.name}-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"
  attribute { name = "pk"; type = "S" }
  attribute { name = "sk"; type = "S" }
  ttl { attribute_name = "ttl"; enabled = true }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
  tags = local.tags
}