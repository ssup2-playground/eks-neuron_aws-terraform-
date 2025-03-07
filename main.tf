# Provider
provider "aws" {
  region = local.region
}

provider "aws" {
  alias  = "ecr"
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  # to avoid issue : https://github.com/hashicorp/terraform-provider-helm/issues/630#issuecomment-996682323
  repository_config_path = "${path.module}/.helm/repositories.yaml" 
  repository_cache       = "${path.module}/.helm"

  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

## Data
data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}

## VPC
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = format("%s-vpc", local.name)

  cidr             = local.vpc_cidr
  azs              = local.azs
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + 4)]

  enable_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  manage_default_network_acl    = true
  manage_default_route_table    = true
  manage_default_security_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1 # for AWS Load Balancer Controller
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1                            # for AWS Load Balancer Controller
    "karpenter.sh/discovery"          = format("%s-eks", local.name) # for Karpenter
  }
}

## EKS 
module "eks" {
  source = "terraform-aws-modules/eks/aws"

  cluster_name = format("%s-eks", local.name)
  cluster_version = "1.28"

  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnets
  cluster_endpoint_public_access  = true

  enable_cluster_creator_admin_permissions = true

  ## Addons
  cluster_addons = {
    coredns = {
      addon_version = "v1.10.1-eksbuild.5"
      configuration_values = file("${path.module}/eks-addon-configs/coredns.json")
    }
    vpc-cni = {
      addon_version = "v1.14.1-eksbuild.1"
    }
    kube-proxy = {
      addon_version = "v1.28.1-eksbuild.1"
    }
  }

  eks_managed_node_groups = {
    core = {
      instance_types = ["m5.large"]

      min_size     = 2
      max_size     = 2
      desired_size = 2

      labels = {
        type = "core"
      }

      taints = {
        dedicated = {
          key    = "type"
          value  = "core"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  ## Node Security Group
  node_security_group_tags = {
    "karpenter.sh/discovery" = format("%s-eks", local.name) # for Karpenter
  }
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

   ingress_grafana = {
      description              = "From grafana NLB"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      type                     = "ingress"
      source_security_group_id = module.sg_grafana.security_group_id
    }
  }
}

## EKS / Karpenter
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name           = module.eks.cluster_name

  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  chart      = "karpenter"
  version    = "1.0.0"

  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  values = [
    templatefile("${path.module}/helm-values/karpenter.yaml",
      {
        eks_cluster_name          = module.eks.cluster_name
        eks_cluster_endpoint      = module.eks.cluster_endpoint
        karpenter_service_account = module.karpenter.service_account
        karpenter_iam_role        = module.karpenter.iam_role_arn
        karpenter_queue_name      = module.karpenter.queue_name
      }
    )
  ]

  depends_on = [
    module.eks
  ]
}

resource "kubectl_manifest" "karpenter_addon" {
  for_each = toset(
    split("---",
      templatefile("${path.module}/manifests/karpenter-addon.yaml",
        {
          eks_cluster_name = module.eks.cluster_name
          ec2_role_name    = module.karpenter.node_iam_role_name
        }
      )
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_default" {
  for_each = toset(
    split("---",
      templatefile("${path.module}/manifests/karpenter-default.yaml",
        {
          eks_cluster_name = module.eks.cluster_name
          ec2_role_name    = module.karpenter.node_iam_role_name
        }
      )
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_inf1" {
  for_each = toset(
    split("---",
      templatefile("${path.module}/manifests/karpenter-inf1.yaml",
        {
          eks_cluster_name = module.eks.cluster_name
          ec2_role_name    = module.karpenter.node_iam_role_name
        }
      )
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "neuron_plugin" {
  for_each = toset(
    split("---",
      file("${path.module}/manifests/neuron-plugin.yaml")
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "neuron_scheduler" {
  for_each = toset(
    split("---",
      file("${path.module}/manifests/neuron-scheduler.yaml")
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "neuron_monitor" {
  for_each = toset(
    split("---",
      file("${path.module}/manifests/neuron-monitor.yaml")
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "neuron_problem_detector" {
  for_each = toset(
    split("---",
      file("${path.module}/manifests/neuron-problem-detector.yaml")
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

## EKS / Load Balancer Controller
module "irsa_load_balancer_controller" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = format("%s-irsa-aws-load-balancer-controller", local.name)
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  version    = "v1.6.2"

  values = [
    templatefile("${path.module}/helm-values/aws-load-balancer-controller.yaml",
      {
        vpc_id                     = module.vpc.vpc_id
        eks_cluster_name           = module.eks.cluster_name
        controller_service_account = "aws-load-balancer-controller"
        controller_iam_role        = module.irsa_load_balancer_controller.iam_role_arn
      }
    )
  ]

  depends_on = [
    module.karpenter,
    helm_release.karpenter,
    module.irsa_load_balancer_controller
  ]
}

## EKS / Prometheus
resource "helm_release" "prometheus" {
  namespace        = "observability"
  create_namespace = true

  name       = "prometheus"
  chart      = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  version    = "25.27.0"

  values = [
    file("${path.module}/helm-values/prometheus.yaml")
  ]

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

## EKS / Grafana
module "sg_grafana" {
  source = "terraform-aws-modules/security-group/aws"

  name   = format("%s-grafana-sg", local.name)
  vpc_id = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "127.0.0.1/32"
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port       = 0
      to_port         = 0
      protocol        = "-1"
      cidr_blocks     = "0.0.0.0/0"
    }
  ]
}

resource "helm_release" "grafana" {
  namespace        = "observability"
  create_namespace = true

  name       = "grafana"
  chart      = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  version    = "v7.0.8"

  values = [
    templatefile("${path.module}/helm-values/grafana.yaml", {
      svc_sg = module.sg_grafana.security_group_id
    })
  ]
}

## EKS / Inf1 Serving App
resource "kubectl_manifest" "inf1_serving" {
  for_each = toset(
    split("---",
      file("${path.module}/manifests/serving-inf1-deploy.yaml")
    )
  )
  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}
