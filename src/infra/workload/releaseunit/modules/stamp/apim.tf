resource "azurerm_api_management" "stamp" {

  depends_on = [
    # APIM requires that an NSG is attached to the subnet
    azurerm_subnet_network_security_group_association.apim_nsg
  ]

  name                = "${local.prefix}-${local.location_short}-apim"
  location            = azurerm_resource_group.stamp.location
  resource_group_name = azurerm_resource_group.stamp.name
  publisher_name      = "Microsoft"
  publisher_email     = var.contact_email

  virtual_network_type = "External"

  public_ip_address_id = azurerm_public_ip.apim.id

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  sku_name = var.apim_sku

  # Availability Zones are only supported in Premium tier. For Premium at least 2 units (= 2 AZs) should be deployed, if 3 or more, we can use all three AZs
  zones = local.apim_tier == "Premium" ? (local.apim_units < 3 ? ["1", "2"] : ["1", "2", "3"]) : null

  protocols {
    enable_http2 = true
  }
}

resource "azurerm_api_management_logger" "stamp" {
  name                = "apimlogger"
  api_management_name = azurerm_api_management.stamp.name
  resource_group_name = azurerm_resource_group.stamp.name

  application_insights {
    instrumentation_key = data.azurerm_application_insights.stamp.instrumentation_key
  }
}

resource "azurerm_api_management_api" "catalogservice" {
  name                = "catalogservice-api"
  resource_group_name = azurerm_resource_group.stamp.name
  api_management_name = azurerm_api_management.stamp.name
  revision            = "1"
  display_name        = "AlwaysOn CatalogService API"
  path                = ""
  protocols           = ["https"]
  service_url         = "https://${local.aks_ingress_fqdn}/"

  subscription_required = false

  import {
    content_format = "openapi"
    content_value  = file("./apim/catalogservice-api-swagger.json")
  }
}

resource "azurerm_api_management_api_diagnostic" "catalogservice" {
  resource_group_name      = azurerm_resource_group.stamp.name
  api_management_name      = azurerm_api_management.stamp.name
  api_name                 = azurerm_api_management_api.catalogservice.name
  api_management_logger_id = azurerm_api_management_logger.stamp.id
  identifier               = "applicationinsights"
}

resource "azurerm_api_management_api" "healthservice" {
  depends_on          = [azurerm_api_management_api.catalogservice]
  name                = "healthservice-api"
  resource_group_name = azurerm_resource_group.stamp.name
  api_management_name = azurerm_api_management.stamp.name
  revision            = "1"
  display_name        = "AlwaysOn HealthService API"
  path                = "healthservice"
  protocols           = ["https"]
  service_url         = "https://${local.aks_ingress_fqdn}/"

  subscription_required = false

  import {
    content_format = "openapi"
    content_value  = file("./apim/healthservice-api-swagger.json")
  }
}

resource "azurerm_api_management_api_diagnostic" "healthservice" {
  resource_group_name      = azurerm_resource_group.stamp.name
  api_management_name      = azurerm_api_management.stamp.name
  api_name                 = azurerm_api_management_api.healthservice.name
  api_management_logger_id = azurerm_api_management_logger.stamp.id
  identifier               = "applicationinsights"
}

# Store the front door id header as a named value which get referenced in the xml policy
resource "azurerm_api_management_named_value" "front_door_id_header" {
  name                = "azure-frontdoor-id-header"
  resource_group_name = azurerm_resource_group.stamp.name
  api_management_name = azurerm_api_management.stamp.name
  display_name        = "azure-frontdoor-id-header"
  value               = var.frontdoor_id_header
}

# Base bolicy which gets applied to all APIs. Contains the frontdoor id check
resource "azurerm_api_management_policy" "all_apis_policy" {
  depends_on = [
    # The named value is referenced in the policy, so it needs to exist first
    azurerm_api_management_named_value.front_door_id_header
  ]
  api_management_id = azurerm_api_management.stamp.id
  xml_content       = file("./apim/apim-api-policy.xml")
}

####################################### DIAGNOSTIC SETTINGS #######################################

# Use this data source to fetch all available log and metrics categories. We then enable all of them
data "azurerm_monitor_diagnostic_categories" "apim" {
  resource_id = azurerm_api_management.stamp.id
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "apimladiagnostics"
  target_resource_id         = azurerm_api_management.stamp.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.stamp.id

  dynamic "log" {
    iterator = entry
    for_each = data.azurerm_monitor_diagnostic_categories.apim.logs

    content {
      category = entry.value
      enabled  = true

      retention_policy {
        enabled = true
        days    = 30
      }
    }
  }

  dynamic "metric" {
    iterator = entry
    for_each = data.azurerm_monitor_diagnostic_categories.apim.metrics

    content {
      category = entry.value
      enabled  = true

      retention_policy {
        enabled = true
        days    = 30
      }
    }
  }
}
