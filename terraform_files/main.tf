data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-subnet"
  }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "${var.project_name}-nat-gateway"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route" "public_internet_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# pem 파일 관련 작업
# 알고리즘 결정
resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
# 키등록
resource "aws_key_pair" "kp" {
  key_name   = var.key_name
  public_key = tls_private_key.pk.public_key_openssh
}
# 개인키 가져오기
resource "local_file" "project_key_pem" {
  filename        = "${path.module}/${var.key_name}.pem"
  content         = tls_private_key.pk.private_key_pem
  file_permission = "0600"
}

# -------------------------

# EC2
# -------------------------
resource "aws_instance" "bastion_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = aws_key_pair.kp.key_name
  associate_public_ip_address = true
  private_ip                  = "172.16.10.50" # 172.16.10.10 은 사용중.... 
  root_block_device {
    volume_size = 20  
    volume_type = "gp3"
  }

  vpc_security_group_ids = [
    aws_security_group.bastion_sg.id
  ]

  tags = {
    Name = "bastion-server"
    Role = "public-bastion"
  }
}

# 변수에 생성된 서버만큼 생성
resource "aws_instance" "private_servers" {
  for_each = var.private_servers

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  key_name                    = aws_key_pair.kp.key_name
  private_ip                  = each.value.private_ip
  associate_public_ip_address = false

  root_block_device {
    volume_size = 15  
    volume_type = "gp3"
  }

  vpc_security_group_ids = [
    aws_security_group.private_server_sg[each.key].id
  ]

  tags = {
    Name = each.key
    Role = "private-server"
  }
}


# =========================
# Ansible Inventory 생성
# =========================

# main.tf - local_file 리소스 수정
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.yml.tpl", {
    bastion_public_ip  = aws_instance.bastion_server.public_ip
    nginx_private_ip   = aws_instance.private_servers["nginx-fe-server"].private_ip
    fastapi_private_ip = aws_instance.private_servers["fastapi-be-server"].private_ip
    postgre_private_ip = aws_instance.private_servers["postgre-db-server"].private_ip
    key_path           = abspath(path.module)
    key_name           = var.key_name
  })
  filename = "../ansible_files/inventory.yml"
}

# main.tf 또는 별도 ansible.tf에 추가

resource "local_file" "ansible_cfg" {
  filename = "${path.module}/../ansible_files/ansible.cfg"
  content  = templatefile("${path.module}/ansible_cfg.tpl", {
    bastion_ip = aws_instance.bastion.public_ip
    gen_path = path.module
  })
}

# Terraform에서 ansible_files/group_vars/all.yml 생성

resource "local_file" "prometheus_vars" {

  filename = "${path.module}/../ansible_files/group_vars/bastion.yml"

  content = yamlencode({

    prometheus_targets = {
      node = [
        {
          targets = [

            "${aws_instance.bastion_server.public_ip}:9100",

            "${aws_instance.private_servers["nginx-fe-server"].private_ip}:9100",

            "${aws_instance.private_servers["fastapi-be-server"].private_ip}:9100",

            "${aws_instance.private_servers["postgre-db-server"].private_ip}:9100"
          ]

          labels = {
            env = "lab"
          }
        }
      ]
    }
  })
}

# cloud init 등 서버의 다양한 환경 초기화를 위해
# ansible 실행 전 60초 간 대기
resource "terraform_data" "wait_for_instance" {
  depends_on = [
    aws_instance.bastion_server,
    aws_instance.private_servers,
    local_file.ansible_inventory
  ]

  # triggers_replace -> 해당 인자에 변경사항이 생기면, resource를 다시 실행하라
  # concat(
  #   [aws_instance.bastion_server.id],
  #   [for instance in aws_instance.private_servers : instance.id]
  # ) 의 경우엔 4 인스턴스 중 하나라도 아이디가 변경되면 다시 시행하라
  triggers_replace = concat(
    [aws_instance.bastion_server.id],
    [for instance in aws_instance.private_servers : instance.id]
  )

  # windows 
  # provisioner "local-exec" {
  #   command     = "Start-Sleep -Seconds 60"
  #   interpreter = ["PowerShell", "-Command"]
  # }

  # linux
     provisioner "local-exec" {
     command = "sleep 60"
   }
}


# 우선 주석 처리 
resource "terraform_data" "ansible_run" {
  # 모든 AWS 리소스가 다 생성된 후에 ansible_run 실행하도록 바꾸기
  depends_on = [

    # inventory 생성 완료
    local_file.ansible_inventory,

    # prometheus 변수 생성 완료
    local_file.prometheus_vars,

    # EC2 생성 완료 + SSH 대기 완료
    terraform_data.wait_for_instance,

    # NAT 및 private 인터넷 경로 준비 완료
    aws_nat_gateway.nat,
    aws_route.private_nat_route,

    # public route도 명시적으로 보장
    aws_route.public_internet_route
  ]

  triggers_replace = concat(
    [aws_instance.bastion_server.id],
    [for instance in aws_instance.private_servers : instance.id]
  )

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible_files"
    # scp -o StrictHostKeyChecking=no -i ../terraform_files/${var.key_name}.pem ../terraform_files/${var.key_name}.pem ubuntu@${aws_instance.bastion_server.public_ip}:~/.ssh
    # Bastion 서버에 pem 키 파일 복사
    # (Bastion -> Private SSH 접속을 위해 필요)
    # 개행 기호를 넣으면 깨질 수 있으므로 한 줄로 작성

    # ssh -o StrictHostKeyChecking=no -i ../terraform_files/${var.key_name}.pem ubuntu@${aws_instance.bastion_server.public_ip} "chmod 400 ~/.ssh/${var.key_name}.pem"
    # Bastion 서버 내부의 pem 권한 설정
    # SSH는 권한이 너무 열려 있으면 key 사용을 거부함
    command       = <<EOT
  
      ansible-galaxy install -r requirements.yml -p ~/.ansible/roles
      ansible-galaxy collection install prometheus.prometheus
      ansible-galaxy collection install grafana.grafana
      ansible-playbook -f 1 site.yml
    EOT
  }
}