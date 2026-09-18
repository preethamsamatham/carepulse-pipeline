terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "carepulse-tfstate-preetham-2026"
    key            = "carepulse/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "carepulse-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
}
resource "aws_s3_bucket" "carepulse_raw" {
  bucket = "carepulse-raw-preetham-2026"

  tags = {
    Project = "CarePulse"
    Purpose = "Synthea raw data landing zone"
  }
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "carepulse-tfstate-preetham-2026"

  tags = {
    Project = "CarePulse"
    Purpose = "Terraform remote state storage"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "carepulse-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project = "CarePulse"
    Purpose = "Terraform state locking"
  }
}

resource "aws_iam_role" "validate_lambda_role" {
  name = "carepulse-validate-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "validate_lambda_policy" {
  name = "carepulse-validate-lambda-policy"
  role = aws_iam_role.validate_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:CopyObject", "s3:DeleteObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.carepulse_raw.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "validate" {
  function_name = "carepulse-validate"
  role          = aws_iam_role.validate_lambda_role.arn
  handler       = "validate.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128

  filename         = "../lambda-validate/validate.zip"
  source_code_hash = filebase64sha256("../lambda-validate/validate.zip")
}


resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.validate.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.carepulse_raw.arn
}

resource "aws_s3_bucket_notification" "raw_bucket_trigger" {
  bucket = aws_s3_bucket.carepulse_raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.validate.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_iam_role" "glue_role" {
  name = "carepulse-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue_policy" {
  name = "carepulse-glue-policy"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject","s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.carepulse_raw.arn,
          "${aws_s3_bucket.carepulse_raw.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_glue_job" "transform_encounters" {
  name         = "carepulse-transform-table"
  role_arn     = aws_iam_role.glue_role.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://carepulse-raw-preetham-2026/scripts/transform_table.py"
    python_version  = "3"
  }

  worker_type       = "G.1X"
  number_of_workers = 2

  default_arguments = {
    "--job-bookmark-option" = "job-bookmark-disable"
  }

  max_retries = 0
  timeout     = 10
}