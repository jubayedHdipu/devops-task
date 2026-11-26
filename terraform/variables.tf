variable "aws_region" {
  description = "AWS region where infrastructure resources will be provisioned"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project identifier used for resource naming and tagging"
  type        = string
  default     = "devops-task"
}

variable "environment" {
  description = "Deployment environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets across two Availability Zones"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets across two Availability Zones"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for running the containerized web service"
  type        = string
  default     = "t3.micro"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH (port 22) into the EC2 instance (use your public IP /32)"
  type        = string
  default     = "10.0.0.0/8"
}

variable "key_pair_name" {
  description = "Optional existing EC2 Key Pair name for SSH access (null disables key pair attachment)"
  type        = string
  default     = null
}

variable "app_port" {
  description = "Container port exposed by the Go web service"
  type        = number
  default     = 8080
}

variable "enable_nat_gateway" {
  description = "Provision a NAT Gateway so private subnets have outbound internet access"
  type        = bool
  default     = true
}