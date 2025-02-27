variable "vpc_id" {}
variable "subnets" {}
variable "key_name" {}

data "aws_ssm_parameter" "latest_amazon_linux_2" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

locals {
  bastion_subnet = element(var.subnets, 0)
}

resource "aws_security_group" "bastion_sg" {
  name   = "bastion-security-group"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "PSE_Bastion_SG" }
}

resource "aws_iam_role" "bastion_role" {
  name = "PSE_Bastion_Role"

  assume_role_policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
  EOF
}

resource "aws_iam_role_policy_attachment" "bastion_policy_attach" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "PSE_Bastion_Instance_Profile"
  role = aws_iam_role.bastion_role.name
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.latest_amazon_linux_2.value
  instance_type          = "t3.micro"
  subnet_id              = "subnet-09392938f13f8e95c"
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.bastion_profile.name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y aws-cli jq
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
  EOF

  tags = { Name = "PSE_Bastion" }
}
