output "weights_bucket_arn" {
  value = aws_s3_bucket.this["weights"].arn
}

output "results_bucket_arn" {
  value = aws_s3_bucket.this["results"].arn
}

output "weights_bucket" {
  value = aws_s3_bucket.this["weights"].id
}

output "results_bucket" {
  value = aws_s3_bucket.this["results"].id
}
