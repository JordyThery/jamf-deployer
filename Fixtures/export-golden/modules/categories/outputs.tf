# Keyed by unprefixed name, so other blocks and presets can refer to
# "categories/Security" whatever prefix the tenant uses.
output "category_ids" {
  value = { for key, category in jamfplatform_pro_category.category : key => category.id }
}

output "category_names" {
  value = { for key, category in jamfplatform_pro_category.category : key => category.name }
}
