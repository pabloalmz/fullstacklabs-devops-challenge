provider "aws" {
  region = var.region
}

# Configura o controle de posse do bucket para ativar as ACLs.
# Isso é necessário para que o CloudFront possa escrever os logs.
resource "aws_s3_bucket_ownership_controls" "logs_ownership" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "ObjectWriter"
  }
}

# Cria um bucket S3 para os logs do CloudFront.
resource "aws_s3_bucket" "logs" {
  bucket        = "${var.bucket_name}-logs"
  force_destroy = true
}

# Adiciona uma ACL específica ao bucket de logs.
# O 'depends_on' garante que o controle de posse seja aplicado primeiro.
resource "aws_s3_bucket_acl" "logs_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.logs_ownership]
  bucket     = aws_s3_bucket.logs.id
  acl        = "log-delivery-write"
}

# Cria o bucket S3 que hospedará o site estático.
resource "aws_s3_bucket" "static_site" {
  bucket        = "${var.bucket_name}-site"
  force_destroy = true
}

# Adiciona a configuração de website estático ao bucket S3.
resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.static_site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Configura o 'Block Public Access' para o bucket do site.
resource "aws_s3_bucket_public_access_block" "block" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Cria um Origin Access Identity (OAI) para o CloudFront.
# Isso garante que apenas o CloudFront possa acessar o conteúdo do S3.
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI for ${var.bucket_name}"
}

# Aplica uma política ao bucket S3 para permitir o acesso somente pelo CloudFront OAI.
resource "aws_s3_bucket_policy" "s3_policy_for_oai" {
  bucket = aws_s3_bucket.static_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.oai.iam_arn
        }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.static_site.arn}/*"
      }
    ]
  })
}

# Cria a distribuição do CloudFront.
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    # Usamos o 'bucket_regional_domain_name' para a origem S3
    domain_name = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id   = "s3-origin"

    # Configura o S3 Origin Access Identity (OAI) para restringir o acesso
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = var.cloudfront_comment
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Configura o bucket de logs para o CloudFront
  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    prefix          = "logs/"
  }
}