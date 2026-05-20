variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "CojoCloud-EKS-Cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks that can access the EKS public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this to your IP in production
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "CojoCloud-EKS-Cluster-VPC"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "DEV"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for Kubernetes storage"
  type        = string
  default     = "cojocloud-eks-cluster-s3-storage"
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana — store this in a tfvars file or CI secret, never hardcode"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Base domain name for DNS records (must exist as a Route53 hosted zone)"
  type        = string
  default     = "cojocloudsolutions.com"
}
