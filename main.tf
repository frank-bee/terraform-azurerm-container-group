data "azurerm_resource_group" "this" {
  count = module.this.enabled && var.location == null ? 1 : 0

  name = var.resource_group_name
}

data "azurerm_key_vault_secret" "container_secret" {
  for_each = merge([for container_name, container in var.containers :
    {
      for k, v in container.secure_environment_variables_from_key_vault : "${container_name}/${k}" => {
        key_vault_id = v.key_vault_id
        name         = v.name
      }
    }
  ]...)

  key_vault_id = each.value.key_vault_id
  name         = each.value.name
}

data "azurerm_key_vault_secret" "volume_secret" {
  for_each = local.secrets_from_volumes

  key_vault_id = each.value.key_vault_id
  name         = each.value.name
}

resource "azurerm_container_group" "this" {
  count = module.this.enabled ? 1 : 0

  name                = local.name_from_descriptor
  location            = local.location
  resource_group_name = local.resource_group_name
  os_type             = "Linux"
  ip_address_type     = length(var.subnet_ids) == 0 ? "Public" : "Private"
  dns_name_label      = length(var.subnet_ids) == 0 ? (var.dns_name_label != null ? var.dns_name_label : local.name_from_descriptor) : null
  subnet_ids          = length(var.subnet_ids) == 0 ? null : var.subnet_ids

  restart_policy = var.restart_policy

  dynamic "dns_config" {
    for_each = toset(length(var.dns_name_servers) > 0 ? [var.dns_name_servers] : [])
    content {
      nameservers = dns_config.value
    }
  }

  dynamic "exposed_port" {
    for_each = var.exposed_ports
    content {
      port     = exposed_port.value.port
      protocol = exposed_port.value.protocol
    }
  }

  dynamic "container" {
    for_each = var.containers
    content {
      name   = container.key
      image  = container.value.image
      cpu    = container.value.cpu
      memory = container.value.memory

      dynamic "ports" {
        for_each = container.value.ports
        content {
          port     = ports.value.port
          protocol = ports.value.protocol
        }
      }

      dynamic "volume" {
        for_each = container.value.volumes
        content {
          mount_path = volume.value.mount_path
          name       = volume.key
          read_only  = volume.value.read_only
          empty_dir  = volume.value.empty_dir
          secret = merge(volume.value.secret, { for k, v in volume.value.secret_from_key_vault :
            k => base64encode(
              data.azurerm_key_vault_secret.volume_secret["${container.key}/${volume.key}/${v.name}"].value
            )
          })
          storage_account_name = volume.value.storage_account_name
          storage_account_key  = volume.value.storage_account_key
          share_name           = volume.value.share_name

          dynamic "git_repo" {
            for_each = volume.value.git_repo != null ? [volume.value.git_repo] : []
            content {
              url       = git_repo.value.url
              directory = git_repo.value.directory
              revision  = git_repo.value.revision
            }
          }
        }
      }

      environment_variables = container.value.environment_variables
      secure_environment_variables = merge(
        {
          for variable_name, variable in container.value.secure_environment_variables_from_key_vault : variable_name =>
          data.azurerm_key_vault_secret.container_secret[format("%s/%s", container.key, variable_name)].value
        },
        container.value.secure_environment_variables
      )
      commands = container.value.commands
    }
  }

  dynamic "identity" {
    for_each = var.identity.enabled != null ? [local.identity] : []
    content {
      type         = identity.value.type
      identity_ids = identity.value.identity_ids
    }
  }

  dynamic "image_registry_credential" {
    for_each = var.image_registry_credential
    content {
      password = image_registry_credential.value.password
      server   = image_registry_credential.value.server
      username = image_registry_credential.value.username
    }
  }

  dynamic "diagnostics" {
    for_each = var.container_diagnostics_log_analytics != null ? [var.container_diagnostics_log_analytics] : []
    content {
      log_analytics {
        workspace_id  = diagnostics.value.workspace_id
        workspace_key = diagnostics.value.workspace_key
      }
    }
  }

  tags = module.this.tags
}

/*
module "diagnostic_settings" {
  count = module.this.enabled && var.diagnostic_settings.enabled ? 1 : 0

  source  = "claranet/diagnostic-settings/azurerm"
  version = "8.0.0"

  resource_id           = one(azurerm_container_group.this[*].id)
  logs_destinations_ids = var.diagnostic_settings.logs_destinations_ids
}
*/

resource "azurerm_user_assigned_identity" "this" {
  count = module.this.enabled && var.identity.user_assigned_identity.enabled ? 1 : 0

  name                = local.msi_name_from_descriptor
  location            = local.location
  resource_group_name = local.resource_group_name
}

resource "azurerm_role_assignment" "container_group_identity" {
  count = module.this.enabled && var.identity.enabled ? length(var.identity.role_assignments) : 0

  principal_id         = local.container_group_identity_principal_id
  scope                = var.identity.role_assignments[count.index].scope
  role_definition_name = var.identity.role_assignments[count.index].role_definition_name
}
