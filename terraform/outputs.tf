output "vpc_id" {
  description = "ID of the provisioned VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "security_group_id" {
  description = "ID of the application host security group"
  value       = aws_security_group.app_host.id
}

output "ecr_repository_url" {
  description = "URL of the Amazon ECR repository"
  value       = aws_ecr_repository.app.repository_url
}

output "ec2_instance_id" {
  description = "ID of the provisioned EC2 application host"
  value       = aws_instance.app_host.id
}

output "ec2_public_ip" {
  description = "Public IP address of the EC2 application host"
  value       = aws_instance.app_host.public_ip
}

output "app_health_url" {
  description = "Health check URL of the deployed web service"
  value       = "http://${aws_instance.app_host.public_ip}:${var.app_port}/health"
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch Log Group receiving application container logs"
  value       = aws_cloudwatch_log_group.app.name
}