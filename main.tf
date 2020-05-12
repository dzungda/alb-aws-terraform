provider "aws" {
  region  = var.region
  profile = var.profile
}
data "aws_vpc" "default" {
  tags = {
    Owner       = "user"
    Environment = "dev"
  }
}
resource "random_pet" "this" {
  length = 2
}
data "aws_subnet_ids" "public_subnet" {
  vpc_id = data.aws_vpc.default.id
  tags = {
    Name = "pubsb-terraform-test"
  }
}
data "aws_subnet_ids" "private_subnet" {
  vpc_id = data.aws_vpc.default.id
  tags = {
    Name = "prisb-terraform-test"
  }
}
data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.default.id
  name   = "default"
}
locals {
  domain_name = "vticloud.xyz"
}
data "aws_route53_zone" "this" {
  name = local.domain_name
}

/*
module "acm" {
  source  = "../../modules/terraform-aws-acm"
  version = "~> 2.0"

  domain_name = local.domain_name # trimsuffix(data.aws_route53_zone.this.name, ".") # Terraform >= 0.12.17
  zone_id     = data.aws_route53_zone.this.id
}
*/
data "aws_acm_certificate" "default" {
    domain      = "vticloud.xyz"
}

#########################
# S3 bucket for ELB logs
#########################
/*
data "aws_elb_service_account" "main" {}

data "aws_iam_policy_document" "logs" {
  statement {
    actions = [
      "s3:PutObject",
    ]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }

    resources = [
      "arn:aws:s3:::elb-logs-${random_pet.this.id}/*",
    ]
  }
}
resource "aws_s3_bucket" "logs" {
  bucket        = "elb-logs-terraform-${random_pet.this.id}"
  acl           = "private"
  policy        = data.aws_iam_policy_document.logs.json
  force_destroy = true
}
*/
##################################################################
# AWS Cognito User Pool
##################################################################
resource "aws_cognito_user_pool" "this" {
  name = "user-pool-${random_pet.this.id}"
}

resource "aws_cognito_user_pool_client" "this" {
  name                                 = "user-pool-client-${random_pet.this.id}"
  user_pool_id                         = aws_cognito_user_pool.this.id
  generate_secret                      = true
  allowed_oauth_flows                  = ["code", "implicit"]
  callback_urls                        = ["https://${local.domain_name}/callback"]
  allowed_oauth_scopes                 = ["email", "openid"]
  allowed_oauth_flows_user_pool_client = true
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = random_pet.this.id
  user_pool_id = aws_cognito_user_pool.this.id
}
##################################################################
# Application Load Balancer
##################################################################
module "alb" {
  source = "../../modules/terraform-aws-alb"

  name = "complete-alb-${random_pet.this.id}"

  load_balancer_type = "application"

  vpc_id          = data.aws_vpc.default.id
  security_groups = [data.aws_security_group.default.id]
  subnets         = var.subnets_id_list #data.aws_subnet_ids.all.ids

  # See notes in README (ref: https://github.com/terraform-providers/terraform-provider-aws/issues/7987)
/*
  access_logs = {
    bucket = aws_s3_bucket.logs.id
  }
 */ 
  http_tcp_listeners = [
    # Forward action is default, either when defined or undefined
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
      # action_type        = "forward"
    },
    {
      port        = 81
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    },
    {
      port        = 82
      protocol    = "HTTP"
      action_type = "fixed-response"
      fixed_response = {
        content_type = "text/plain"
        message_body = "Fixed message"
        status_code  = "200"
      }
    },
  ]

  https_listeners = [
    {
      port               = 443
      protocol           = "HTTPS"
      certificate_arn    = data.aws_acm_certificate.default.arn
      target_group_index = 1
    },
    # Authentication actions only allowed with HTTPS
    {
      port               = 444
      protocol           = "HTTPS"
      action_type        = "authenticate-cognito"
      target_group_index = 1
      certificate_arn    = data.aws_acm_certificate.default.arn
      authenticate_cognito = {
        authentication_request_extra_params = {
          display = "page"
          prompt  = "login"
        }
        on_unauthenticated_request = "authenticate"
        session_cookie_name        = "session-${random_pet.this.id}"
        session_timeout            = 3600
        user_pool_arn              = aws_cognito_user_pool.this.arn
        user_pool_client_id        = aws_cognito_user_pool_client.this.id
        user_pool_domain           = aws_cognito_user_pool_domain.this.domain
      }
    },
    {
      port               = 445
      protocol           = "HTTPS"
      action_type        = "authenticate-oidc"
      target_group_index = 1
      certificate_arn    = data.aws_acm_certificate.default.arn
      authenticate_oidc = {
        authentication_request_extra_params = {
          display = "page"
          prompt  = "login"
        }
        authorization_endpoint = "https://${local.domain_name}/auth"
        client_id              = "client_id"
        client_secret          = "client_secret"
        issuer                 = "https://${local.domain_name}"
        token_endpoint         = "https://${local.domain_name}/token"
        user_info_endpoint     = "https://${local.domain_name}/user_info"
      }
    },
  ]

  target_groups = [
    {
      name_prefix          = "h1"
      backend_protocol     = "HTTP"
      backend_port         = 80
      target_type          = "instance"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/healthz"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 6
        protocol            = "HTTP"
        matcher             = "200-399"
      }
    },
    {
      name_prefix                        = "l1-"
      target_type                        = "lambda"
      lambda_multi_value_headers_enabled = true
    },
  ]

  tags = {
    Project = "Test_ALB"
  }
}
