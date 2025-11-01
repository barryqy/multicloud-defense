#################################################################################################################################
# AWS Infrastructure - Application VMs and Networking
#################################################################################################################################

# Locals for application installation scripts
locals {
  application1_install = file("${path.module}/application1_install.sh")
  application2_install = file("${path.module}/application2_install.sh")
}

#################################################################################################################################
# Locals
#################################################################################################################################

locals {
  vpc_cidr1    = "10.${var.pod_number}.0.0/16"
  vpc_cidr2    = "10.${var.pod_number + 100}.0.0/16"
  subnet_cidr1 = "10.${var.pod_number}.100.0/24"
  subnet_cidr2 = "10.${var.pod_number + 100}.100.0/24"
  app1_nic     = ["10.${var.pod_number}.100.10"]
  app2_nic     = ["10.${var.pod_number + 100}.100.10"]
}

#################################################################################################################################
# Application VPC & Subnet
#################################################################################################################################

resource "aws_vpc" "app_vpc" {
  count                = 2
  cidr_block           = count.index == 0 ? local.vpc_cidr1 : local.vpc_cidr2
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-vpc"
  }
}

resource "aws_subnet" "app_subnet" {
  count             = 2
  vpc_id            = aws_vpc.app_vpc["${count.index}"].id
  cidr_block        = count.index == 0 ? local.subnet_cidr1 : local.subnet_cidr2
  availability_zone = "us-east-1a"
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-subnet"
  }
}

resource "aws_subnet" "mgmt_subnet" {
  vpc_id            = aws_vpc.app_vpc[0].id
  cidr_block        = "10.${var.pod_number}.200.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "pod${var.pod_number}-mgmt-subnet"
  }
}

#################################################################################################################################
# Keypair
#################################################################################################################################

resource "tls_private_key" "key_pair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.key_pair.private_key_openssh
  filename        = "pod${var.pod_number}-private-key"
  file_permission = "0700"
}

resource "local_file" "public_key" {
  content         = tls_private_key.key_pair.public_key_openssh
  filename        = "pod${var.pod_number}-public-key"
  file_permission = "0700"
}

resource "aws_key_pair" "sshkeypair" {
  key_name   = "pod${var.pod_number}-keypair"
  public_key = tls_private_key.key_pair.public_key_openssh
}

#################################################################################################################################
# EC2 Instance
#################################################################################################################################

resource "aws_instance" "AppMachines" {
  count         = 2
  ami           = "ami-053b0d53c279acc90"
  instance_type = "t2.micro"
  key_name      = "pod${var.pod_number}-keypair"
  user_data     = count.index == 0 ? local.application1_install : local.application2_install

  network_interface {
    network_interface_id = aws_network_interface.application_interface["${count.index}"].id
    device_index         = 0
  }

  # Ensure all networking is ready before provisioning
  depends_on = [
    aws_network_interface_sg_attachment.app-sg,
    aws_eip_association.app-eip-assocation,
    aws_internet_gateway.int_gw,
    aws_route.ext_default_route
  ]

  # Wait for instance to be ready and SSH available
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'Instance is ready for provisioning'"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "10m"
    }
  }

  provisioner "file" {
    source      = "./images/aws-app${count.index + 1}.png"
    destination = "/home/ubuntu/aws-app.png"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "10m"
    }
  }

  provisioner "file" {
    source      = "./html/index.html"
    destination = "/home/ubuntu/index.html"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "10m"
    }
  }

  provisioner "file" {
    source      = "./html/status${count.index + 1}"
    destination = "/home/ubuntu/status"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "10m"
    }
  }


  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}"
    role = count.index == 0 ? "pod${var.pod_number}-prod" : "pod${var.pod_number}-shared"
  }
}

resource "aws_network_interface" "application_interface" {
  count = 2

  subnet_id   = aws_subnet.app_subnet["${count.index}"].id
  private_ips = count.index == 0 ? local.app1_nic : local.app2_nic
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-nic"
  }
}

#################################################################################################################################
# Internet Gateway
#################################################################################################################################

resource "aws_internet_gateway" "int_gw" {
  count  = 2
  vpc_id = aws_vpc.app_vpc["${count.index}"].id
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-igw"
  }
}


# #################################################################################################################################
# #Elastic IP
# #################################################################################################################################

resource "aws_eip" "app-EIP" {
  count  = 2
  domain = "vpc"
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-eip"
  }
}

resource "aws_eip_association" "app-eip-assocation" {
  count                = 2
  network_interface_id = aws_network_interface.application_interface["${count.index}"].id
  allocation_id        = aws_eip.app-EIP[count.index].id
  
  # Ensure IGW is attached before associating EIP
  depends_on = [
    aws_internet_gateway.int_gw
  ]
}

# #################################################################################################################################
# #Security Group
# #################################################################################################################################

resource "aws_security_group" "allow_all" {
  count  = 2
  name   = "pod${var.pod_number}-app${count.index + 1}-sg"
  vpc_id = aws_vpc.app_vpc["${count.index}"].id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0", "68.154.48.186/32", "10.0.0.0/8", "192.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-sg"
  }
}

resource "aws_network_interface_sg_attachment" "app-sg" {
  count                = 2
  security_group_id    = aws_security_group.allow_all["${count.index}"].id
  network_interface_id = aws_network_interface.application_interface[count.index].id
}

##################################################################################################################################
# Routing Tables and Routes
##################################################################################################################################

resource "aws_route_table" "app-route" {
  count  = 2
  vpc_id = aws_vpc.app_vpc["${count.index}"].id
  tags = {
    Name = "pod${var.pod_number}-app${count.index + 1}-rt"
  }
}

resource "aws_route" "ext_default_route" {
  count                  = 2
  route_table_id         = aws_route_table.app-route["${count.index}"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.int_gw["${count.index}"].id
}

resource "aws_route" "jumpbox1_route" {
  count                  = 2
  route_table_id         = aws_route_table.app-route["${count.index}"].id
  destination_cidr_block = "68.154.48.186/32"
  gateway_id             = aws_internet_gateway.int_gw["${count.index}"].id
}

resource "aws_route" "jumpbox2_route" {
  count                  = 2
  route_table_id         = aws_route_table.app-route["${count.index}"].id
  destination_cidr_block = "35.84.104.14/32"
  gateway_id             = aws_internet_gateway.int_gw["${count.index}"].id
}

resource "aws_route_table_association" "app_association" {
  count          = 2
  subnet_id      = aws_subnet.app_subnet["${count.index}"].id
  route_table_id = aws_route_table.app-route["${count.index}"].id
}

##################################################################################################################################
# Outputs
##################################################################################################################################

output "app1-public-eip" {
  value       = aws_eip.app-EIP[0].public_ip
  description = "Public IP address of Application 1"
}

output "app2-public-eip" {
  value       = aws_eip.app-EIP[1].public_ip
  description = "Public IP address of Application 2"
}

output "app1-private-ip" {
  value       = "10.${var.pod_number}.100.10"
  description = "Private IP address of Application 1"
}

output "app2-private-ip" {
  value       = "10.${var.pod_number + 100}.100.10"
  description = "Private IP address of Application 2"
}

output "Command_to_use_for_ssh_into_app1_vm" {
  value       = "ssh -i pod${var.pod_number}-private-key ubuntu@${aws_eip.app-EIP[0].public_ip}"
  description = "SSH command to connect to Application 1 VM"
}

output "Command_to_use_for_ssh_into_app2_vm" {
  value       = "ssh -i pod${var.pod_number}-private-key ubuntu@${aws_eip.app-EIP[1].public_ip}"
  description = "SSH command to connect to Application 2 VM"
}

output "http_command_app1" {
  value       = "http://${aws_eip.app-EIP[0].public_ip}"
  description = "HTTP URL for Application 1"
}

output "http_command_app2" {
  value       = "http://${aws_eip.app-EIP[1].public_ip}"
  description = "HTTP URL for Application 2"
}

