provider "aws" {
  region = var.region
}

data "aws_vpc" "existing" {
  id = "vpc-0fe15104f4f4258bb"
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

data "aws_subnet" "public_filtered" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  az_to_subnet_map      = merge([for s in data.aws_subnet.public_filtered : { (s.availability_zone) = s.id }]...)
  unique_public_subnets = values(local.az_to_subnet_map)
  cluster_name          = "pse_task-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "bastion" {
  source   = "./bastion"
  vpc_id   = data.aws_vpc.existing.id
  subnets  = data.aws_subnets.public.ids
  key_name = "PSE_TASKY"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = data.aws_vpc.existing.id
  subnet_ids = data.aws_subnets.private.ids

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name           = "node-group-1"
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }

    two = {
      name           = "node-group-2"
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
    }
  }
}

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

resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group"
  description = "Allow inbound HTTP and HTTPS traffic"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
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

  tags = { Name = "alb-security-group" }
}

resource "aws_lb" "eks_alb" {
  name               = "eks-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = local.unique_public_subnets
  enable_deletion_protection = false

  tags = { Name = "eks-alb" }
}

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

  tags = { Name = "eks-target-group" }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.eks_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks_target_group.arn
  }
}

data "aws_instances" "eks_node_group_one" {
  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["node-group-1"]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

resource "aws_lb_target_group_attachment" "eks_nodes" {
  count            = length(data.aws_instances.eks_node_group_one.ids)
  target_group_arn = aws_lb_target_group.eks_target_group.arn
  target_id        = data.aws_instances.eks_node_group_one.ids[count.index]
  port             = 80
}
