output "cloudfront_domain"    { value = aws_cloudfront_distribution.main.domain_name }
output "alb_dns_name"         { value = aws_lb.main.dns_name }
output "redis_endpoint"       { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "aurora_writer_endpoint"  { value = aws_rds_cluster.main.endpoint }
output "aurora_reader_endpoint"  { value = aws_rds_cluster.main.reader_endpoint }
output "dynamodb_table_name"  { value = aws_dynamodb_table.main.name }
output "sqs_queue_url"        { value = aws_sqs_queue.main.url }
output "static_bucket_name"   { value = aws_s3_bucket.static.bucket }