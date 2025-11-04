#################################################################################################################################
# AWS Infrastructure - Application VMs and Networking
#################################################################################################################################

# Data source to get the latest Ubuntu 22.04 LTS AMI (patched, no CVEs)
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

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

#################################################################################################################################
# Management VPC for Jumpbox (separate from app VPCs)
#################################################################################################################################

resource "aws_vpc" "mgmt_vpc" {
  # Management VPC CIDR: 172.16.{pod}.0/24 (avoids conflict with 10.x.x.x used by apps)
  # Max pod number: 60, so 172.16.60.0/24 is the highest
  cidr_block           = "172.16.${var.pod_number}.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"
  tags = {
    Name = "pod${var.pod_number}-mgmt-vpc"
  }
}

resource "aws_subnet" "mgmt_subnet" {
  vpc_id            = aws_vpc.mgmt_vpc.id
  cidr_block        = "172.16.${var.pod_number}.0/28"  # /28 gives 16 IPs (enough for jumpbox)
  availability_zone = "us-east-1a"
  tags = {
    Name = "pod${var.pod_number}-mgmt-subnet"
  }
}

resource "aws_internet_gateway" "mgmt_igw" {
  vpc_id = aws_vpc.mgmt_vpc.id
  tags = {
    Name = "pod${var.pod_number}-mgmt-igw"
  }
}

resource "aws_route_table" "mgmt_rt" {
  vpc_id = aws_vpc.mgmt_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mgmt_igw.id
  }
  tags = {
    Name = "pod${var.pod_number}-mgmt-rt"
  }
}

# Route for Management VPC to reach App VPCs via TGW
# This route is only created after TGW attachments exist (from 5-attach-tgw.sh)
resource "aws_route" "mgmt_to_tgw" {
  count                  = fileexists("${path.module}/tgw-attachments.tf") ? 1 : 0
  route_table_id         = aws_route_table.mgmt_rt.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = data.aws_ec2_transit_gateway.tgw.id
  
  # Note: No depends_on needed - the fileexists() check ensures TGW attachments exist
  # The route is only created when tgw-attachments.tf exists (after 5-attach-tgw.sh)
}

resource "aws_route_table_association" "mgmt_rt_assoc" {
  subnet_id      = aws_subnet.mgmt_subnet.id
  route_table_id = aws_route_table.mgmt_rt.id
}

resource "aws_security_group" "jumpbox_sg" {
  name        = "pod${var.pod_number}-jumpbox-sg"
  description = "Security group for jumpbox"
  vpc_id      = aws_vpc.mgmt_vpc.id

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

  tags = {
    Name = "pod${var.pod_number}-jumpbox-sg"
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
  ami           = data.aws_ami.ubuntu_2204.id
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
    aws_internet_gateway.int_gw
  ]

  # IMPORTANT: Provisioners may fail when TGW routing is enabled (traffic goes through MCD)
  # Using on_failure = continue ensures instances are created even if SSH provisioning fails
  # Files can be deployed manually via user_data or through jumpbox after TGW attachment
  
  # Wait for instance to be ready and SSH available
  provisioner "remote-exec" {
    on_failure = continue
    
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
      timeout     = "5m"
    }
  }

  provisioner "file" {
    on_failure = continue
    
    source      = "./images/aws-app${count.index + 1}.png"
    destination = "/home/ubuntu/aws-app.png"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "5m"
    }
  }

  provisioner "file" {
    on_failure = continue
    
    source      = "./html/index.html"
    destination = "/home/ubuntu/index.html"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "5m"
    }
  }

  provisioner "file" {
    on_failure = continue
    
    source      = "./html/status${count.index + 1}"
    destination = "/home/ubuntu/status"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = aws_eip.app-EIP["${count.index}"].public_ip
      timeout     = "5m"
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
# Jumpbox Instance
#################################################################################################################################

resource "aws_instance" "jumpbox" {
  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.mgmt_subnet.id
  vpc_security_group_ids      = [aws_security_group.jumpbox_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.sshkeypair.key_name

  # Ensure keypair and networking are ready
  depends_on = [
    aws_internet_gateway.mgmt_igw,
    aws_route_table_association.mgmt_rt_assoc,
    local_file.private_key
  ]

  # IMPORTANT: Provisioners may fail in container environments
  # Using on_failure = continue ensures jumpbox is created even if file copy fails
  # SSH key can be copied manually if needed
  
  provisioner "file" {
    on_failure = continue
    
    source      = "pod${var.pod_number}-private-key"
    destination = "/home/ubuntu/.ssh/id_rsa"
    
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = self.public_ip
      timeout     = "5m"
    }
  }

  provisioner "remote-exec" {
    on_failure = continue
    
    inline = [
      "chmod 600 /home/ubuntu/.ssh/id_rsa",
      "echo '${local.app1_nic[0]} app1' | sudo tee -a /etc/hosts",
      "echo '${local.app2_nic[0]} app2' | sudo tee -a /etc/hosts"
    ]
    
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.key_pair.private_key_openssh
      host        = self.public_ip
      timeout     = "5m"
    }
  }

  tags = {
    Name = "pod${var.pod_number}-jumpbox"
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

# Default routes are now defined in routes-config.tf
# This allows attach-tgw.sh to toggle between IGW and TGW routing

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

output "jumpbox_public_ip" {
  value       = aws_instance.jumpbox.public_ip
  description = "Public IP address of Jumpbox"
}

output "Command_to_use_for_ssh_into_jumpbox" {
  value       = "ssh -i pod${var.pod_number}-private-key ubuntu@${aws_instance.jumpbox.public_ip}"
  description = "SSH command to connect to Jumpbox"
}

# Instance IDs (for readiness checks)
output "app1-instance-id" {
  value       = aws_instance.AppMachines[0].id
  description = "Instance ID of Application 1"
}

output "app2-instance-id" {
  value       = aws_instance.AppMachines[1].id
  description = "Instance ID of Application 2"
}

output "jumpbox_instance_id" {
  value       = aws_instance.jumpbox.id
  description = "Instance ID of Jumpbox"
}
