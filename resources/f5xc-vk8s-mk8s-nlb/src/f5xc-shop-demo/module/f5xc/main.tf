terraform {
  required_providers {
    volterra = {
      source = "volterraedge/volterra"
      version = "0.11.16"
    }
  }
}

resource "volterra_namespace" "app_ns" {
  name = var.base

  provisioner "local-exec" {
    command = "./misc/f5xc_resource_ready.py --type ns --name ${self.name} --timeout 30"
    environment = {
      VES_API_URL = var.api_url
      VES_P12     = format("creds/%s", var.api_p12_file)
    }
  }
}

resource "volterra_namespace" "utility_ns" {
  name = format("%s-utility", var.base)

  provisioner "local-exec" {
    command = "./misc/f5xc_resource_ready.py --type ns --name ${self.name} --timeout 30"
    environment = {
      VES_API_URL = var.api_url
      VES_P12     = format("creds/%s", var.api_p12_file)
    }
  }
}

resource "volterra_virtual_site" "spoke" {
  name      = format("%s-spoke-vs", volterra_namespace.app_ns.name)
  namespace = volterra_namespace.app_ns.name

  site_selector {
    expressions = var.spoke_site_selector
  }
  site_type = "REGIONAL_EDGE"
}

resource "volterra_virtual_site" "hub" {
  name      = format("%s-hub-vs", volterra_namespace.app_ns.name)
  namespace = volterra_namespace.app_ns.name

  site_selector {
    expressions = var.hub_site_selector
  }
  site_type = "REGIONAL_EDGE"
}


resource "volterra_virtual_site" "utility" {
  name      = format("%s-vs", volterra_namespace.utility_ns.name)
  namespace = volterra_namespace.utility_ns.name

  site_selector {
    expressions = var.utility_site_selector
  }
  site_type = "REGIONAL_EDGE"
}

resource "volterra_virtual_k8s" "app_vk8s" {
  name      = format("%s-vk8s", volterra_namespace.app_ns.name)
  namespace = volterra_namespace.app_ns.name

  vsite_refs {
    name      = volterra_virtual_site.hub.name
    namespace = volterra_namespace.app_ns.name
  }
  vsite_refs {
    name      = volterra_virtual_site.spoke.name
    namespace = volterra_namespace.app_ns.name
  }

  provisioner "local-exec" {
    command = "./misc/f5xc_resource_ready.py --type vk8s --name ${self.name} --ns ${self.namespace} --timeout 300"
    environment = {
      VES_API_URL = var.api_url
      VES_P12     = format("creds/%s", var.api_p12_file)
    }
  }
}

resource "volterra_virtual_k8s" "utility_vk8s" {
  name      = format("%s-vk8s", volterra_namespace.utility_ns.name)
  namespace = volterra_namespace.utility_ns.name

  vsite_refs {
    name      = volterra_virtual_site.utility.name
    namespace = volterra_namespace.utility_ns.name
  }

  provisioner "local-exec" {
    command = "./misc/f5xc_resource_ready.py --type vk8s --name ${self.name} --ns ${self.namespace} --timeout 300"
    environment = {
      VES_API_URL = var.api_url
      VES_P12     = format("creds/%s", var.api_p12_file)
    }
  }
}

resource "volterra_api_credential" "app_vk8s_cred" {
  name      = format("%s-app-cred", var.base)
  api_credential_type = "KUBE_CONFIG"
  virtual_k8s_namespace = volterra_namespace.app_ns.name
  virtual_k8s_name = volterra_virtual_k8s.app_vk8s.name
  expiry_days = var.cred_expiry_days
}

resource "volterra_api_credential" "utility_vk8s_cred" {
  name      = format("%s-utl-cred", var.base)
  api_credential_type = "KUBE_CONFIG"
  virtual_k8s_namespace = volterra_namespace.utility_ns.name
  virtual_k8s_name = volterra_virtual_k8s.utility_vk8s.name
  expiry_days = var.cred_expiry_days
}

resource "volterra_app_type" "at" {
  // This naming simplifies the 'mesh' cards
  name      = var.base
  namespace = "shared"
  features {
    type = "BUSINESS_LOGIC_MARKUP"
  }
  features {
    type = "USER_BEHAVIOR_ANALYSIS"
  }
  features {
    type = "PER_REQ_ANOMALY_DETECTION"
  }
  features {
    type = "TIMESERIES_ANOMALY_DETECTION"
  }
  business_logic_markup_setting {
    enable = true
  }
}

resource "volterra_app_setting" "as" {
  name        = var.base
  namespace   = volterra_namespace.app_ns.name

  app_type_settings {
    app_type_ref {
      name      = volterra_app_type.at.name
      namespace = volterra_app_type.at.namespace
    }
    business_logic_markup_setting {
      enable = true
    }
    timeseries_analyses_setting {
      metric_selectors {
        metric         = ["REQUEST_RATE", "ERROR_RATE", "LATENCY", "THROUGHPUT"]
        metrics_source = "NODES"
      }
    }
    user_behavior_analysis_setting {
      enable_learning = true
      enable_detection {
        cooling_off_period = 20
        include_forbidden_activity {
          forbidden_requests_threshold = 10
        }
        exclude_failed_login_activity = true
        include_waf_activity = true
      }
    }
  }
}

resource "volterra_healthcheck" "frontend" {
  name                   = format("%s-frontend", var.base)
  namespace              = volterra_namespace.app_ns.name

  http_health_check {
    headers = {
      "Cookie" = "shop_session-id=x-liveness-probe"
    }
    use_origin_server_name = true
    path                   = "/_healthz"
  }
  healthy_threshold   = 2
  interval            = 5
  timeout             = 1
  unhealthy_threshold = 5
}

resource "volterra_origin_pool" "frontend" {
  name                   = format("%s-frontend", var.base)
  namespace              = volterra_namespace.app_ns.name
  description            = format("Origin pool pointing to frontend k8s service running in main-vsite")
  loadbalancer_algorithm = "LB_OVERRIDE"
  endpoint_selection     = "LOCAL_PREFERRED"
  origin_servers {
    k8s_service {
      inside_network  = false
      outside_network = false
      vk8s_networks   = true
      service_name    = format("frontend.%s", volterra_namespace.app_ns.name)
      site_locator {
        virtual_site {
          name      = volterra_virtual_site.spoke.name
          namespace = volterra_namespace.app_ns.name
        }
      }
    }
  }
  healthcheck {
    name = volterra_healthcheck.frontend.name
    namespace = volterra_healthcheck.frontend.namespace
  }
  port               = 80
  no_tls             = true
}

resource "volterra_origin_pool" "redis" {
  name                   = format("%s-redis", var.base)
  namespace              = volterra_namespace.app_ns.name
  description            = format("Origin pool pointing to redis k8s service running in utility-vsite")
  loadbalancer_algorithm = "LB_OVERRIDE"
  endpoint_selection     = "LOCAL_PREFERRED"
  origin_servers {
    k8s_service {
      inside_network  = false
      outside_network = false
      vk8s_networks   = true
      service_name    = format("redis-cart.%s", volterra_namespace.app_ns.name)
      site_locator {
        virtual_site {
          name      = volterra_virtual_site.hub.name
          namespace = volterra_namespace.app_ns.name
        }
      }
    }
  }
  port               = 6379
  no_tls             = true
}

resource "volterra_origin_pool" "adservice" {
  name                   = format("%s-ad", var.base)
  namespace              = volterra_namespace.app_ns.name
  description            = format("Origin pool pointing to adservice k8s service running in utility-vsite")
  loadbalancer_algorithm = "LB_OVERRIDE"
  endpoint_selection     = "LOCAL_PREFERRED"
  origin_servers {
    k8s_service {
      inside_network  = false
      outside_network = false
      vk8s_networks   = true
      service_name    = format("adservice.%s", volterra_namespace.app_ns.name)
      site_locator {
        virtual_site {
          name      = volterra_virtual_site.hub.name
          namespace = volterra_namespace.app_ns.name
        }
      }
    }
  }
  port               = 9555
  no_tls             = true
}

resource "volterra_user_identification" "ui" {
  name        = format("%s-user-id", var.base)
  description = format("User Idenfication for %s", var.base)
  namespace   = volterra_namespace.app_ns.name

  rules {
    cookie_name = "shop_session-id"
  }
}

resource "volterra_app_firewall" "af" {
  name        = format("%s-app-firewall", var.base)
  description = format("App Firewall in blocking mode for %s", var.base)
  namespace   = volterra_namespace.app_ns.name

  allow_all_response_codes = true
  default_anonymization = true
  use_default_blocking_page = true
  default_bot_setting = true
  default_detection_settings = true
  blocking = true
}

resource "volterra_http_loadbalancer" "frontend" {
  name                            = format("%s-fe", var.base)
  namespace                       = volterra_namespace.app_ns.name
  description                     = format("HTTPS loadbalancer object for %s origin server", var.base)
  domains                         = [var.app_fqdn]
  advertise_on_public_default_vip = true
  labels                          = { "ves.io/app_type" : volterra_app_type.at.name }
  round_robin                     = true
  default_route_pools {
    pool {
      name      = volterra_origin_pool.frontend.name
      namespace = volterra_namespace.app_ns.name
    }
  }
  https_auto_cert {
    add_hsts              = false
    http_redirect         = true
    no_mtls               = true
    enable_path_normalize = true
  }
  multi_lb_app = true
  app_firewall {
    name      = volterra_app_firewall.af.name
    namespace = volterra_namespace.app_ns.name
  }
  dynamic "bot_defense" {
    for_each = var.enable_bot_defense ? [1] : []
    content {
      policy {
        disable_js_insert       = false
        js_insert_all_pages {
          javascript_location  = "After <head> tag"
        }
        protected_app_endpoints {
          any_domain = true
          path {
            prefix = "/cart"
          }
          protocol = "https"
          web  = true
          http_methods = ["METHOD_POST"]
          metadata {
            name = format("%s-bot-defense", var.base)
          }
          mitigation {
            block {
              body = "string:///PHA+VGhpcyBpcyBhIGJvdCBkZWZlbnNlIGJsb2NrIHBhZ2UuPC9wPg==" 
              #<p>This is a bot defense block page.</p>"
              status = "BadRequest"
            }
          }
        }
      }
      timeout = 1000
      regional_endpoint = var.bot_defense_region
    }
  }
  dynamic "client_side_defense" {
    for_each = var.enable_client_side_defense ? [1] : []
    content {
      policy {
        js_insert_all_pages = true
      }
    }
  }
  user_identification {
    name      = volterra_user_identification.ui.name
    namespace = volterra_namespace.app_ns.name
  }
  more_option {
    custom_errors = {
      408 : format("string:///%s", filebase64("${path.module}/../../misc/error.html")),
      503 : format("string:///%s", filebase64("${path.module}/../../misc/error.html"))      
    }
    idle_timeout = 5000
  }
  disable_rate_limit              = true
  service_policies_from_namespace = true
  no_challenge                    = true
  add_location                    = true
}

resource "volterra_tcp_loadbalancer" "redis" {
  name                            = format("%s-redis", var.base)
  namespace                       = volterra_namespace.app_ns.name
  description                     = format("TCP loadbalancer object for %s redis service", var.base)
  domains                         = ["redis-cart.internal"]
  dns_volterra_managed            = false
  listen_port                     = 6379
  labels                          = { 
    "ves.io/app_type" : volterra_app_type.at.name,
    "ves.io/app_name" : var.base
    }
  origin_pools_weights {
    pool {
      name      = volterra_origin_pool.redis.name
      namespace = volterra_namespace.app_ns.name
    }
  }
  advertise_custom {
    advertise_where {
      vk8s_service {
        virtual_site {
          name      = volterra_virtual_site.spoke.name
          namespace = volterra_namespace.app_ns.name
        }
      }
    port = 6379
    }
  }
  retract_cluster = true
  hash_policy_choice_round_robin = true
}

resource "volterra_tcp_loadbalancer" "adservice" {
  name                            = format("%s-adservice", var.base)
  namespace                       = volterra_namespace.app_ns.name
  description                     = format("TCP loadbalancer object for %s adservice grpc service", var.base)
  domains                         = ["adservice.internal"]
  dns_volterra_managed            = false
  listen_port                     = 9555
  labels                          = { 
    "ves.io/app_type" : volterra_app_type.at.name,
    "ves.io/app_name" : var.base
    }
  origin_pools_weights {
    pool {
      name      = volterra_origin_pool.adservice.name
      namespace = volterra_namespace.app_ns.name
    }
  }
  advertise_custom {
    advertise_where {
      vk8s_service {
        virtual_site {
          name      = volterra_virtual_site.spoke.name
          namespace = volterra_namespace.app_ns.name
        }
      }
    port = 9555
    }
  }
  retract_cluster = true
  hash_policy_choice_round_robin = true
}
