resource "jamfplatform_pro_computer_extension_attribute" "rosetta_installed" {
  provider = jamfplatform

  allow_multiple_values = false
  data_type             = "STRING"
  description           = "Checks whether Rosetta 2 is installed."
  enabled               = true
  input_type            = "SCRIPT"
  inventory_display     = "EXTENSION_ATTRIBUTES"
  name                  = "Rosetta installed"
  script                = "#!/bin/zsh\necho test"
}
