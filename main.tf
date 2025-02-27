provider "aws" {
  region = var.region
}

# Get existing VPC
data "aws_vpc" "existing" {
  id = "vpc-0fe15104f4f4258bb"
}

# Get existing private subnets in the VPC (For EKS)
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

# Get existing public subnets in the VPC (For ALB)
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

locals {
  cluster_name = "pse_task-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  # Run EKS in private subnets
  cluster_endpoint_public_access  = false  # No public API access
  cluster_endpoint_private_access = true   # Private API access only

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = data.aws_vpc.existing.id
  subnet_ids = data.aws_subnets.private.ids  # Use private subnets for worker nodes

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }

    two = {
      name = "node-group-2"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

# Get EBS CSI IAM Policy
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# ---------------------------------
# Public AWS Application Load Balancer (ALB)
# ---------------------------------

# Security Group for ALB (Public Access)
resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group"
  description = "Allow inbound HTTP and HTTPS traffic"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description = "Allow HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-security-group"
  }
}

# Create a Public ALB in the public subnets
resource "aws_lb" "eks_alb" {
  name               = "eks-alb"
  internal           = false  # Public ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  # Ensure only up to three unique subnets are selected (one per AZ)
  subnets = [for idx, subnet in data.aws_subnets.public.ids : subnet if idx < 3]

  enable_deletion_protection = false

  tags = {
    Name = "eks-alb"
  }
}

# Create a Target Group for forwarding traffic to EKS nodes
resource "aws_lb_target_group" "eks_target_group" {
  name        = "eks-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing.id
  target_type = "instance"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "eks-target-group"
  }
}

# ALB Listener for HTTP traffic
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.eks_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks_target_group.arn
  }
}

# ---------------------------------------------------------------
# Lookup the EC2 instances for the node group "one" using tags
# ---------------------------------------------------------------
data "aws_instances" "eks_node_group_one" {
  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["node-group-1"]
  }

  # Ensure only instances in the desired VPC are returned
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

# Register EKS nodes from node group "one" in the Target Group
resource "aws_lb_target_group_attachment" "eks_nodes" {
  count            = length(data.aws_instances.eks_node_group_one.ids)
  target_group_arn = aws_lb_target_group.eks_target_group.arn
  target_id        = data.aws_instances.eks_node_group_one.ids[count.index]
  port             = 80
}


