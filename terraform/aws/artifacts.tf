resource "aws_ecr_repository" "gateway" {
  name                 = var.gateway_image_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_s3_bucket" "models" {
  bucket = var.model_bucket_name
  tags   = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket = aws_s3_bucket.models.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_secretsmanager_secret" "gateway_api_key" {
  name = var.gateway_api_key_secret_name
  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [
      force_overwrite_replica_secret,
      recovery_window_in_days,
      tags,
    ]
  }
}
