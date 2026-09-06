output "route_table_ids" {
  description = "Map of route_tables key to that route table's ID"
  value       = { for key, rt in aws_route_table.this : key => rt.id }
}
