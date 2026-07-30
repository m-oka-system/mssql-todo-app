output "mssql_database_id" {
  value = azapi_resource.this.id
}

output "mssql_database_name" {
  value = azapi_resource.this.name
}

output "use_free_limit" {
  value = azapi_resource.this.output.properties.useFreeLimit
}
