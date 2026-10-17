# Offline spike: state/plan encryption, apply stream, removed blocks.
# Uses only the built-in terraform_data resource so no credentials are needed.

resource "terraform_data" "foundation_marker" {
  input = "Managed by Jamf Deployer · foundation@0.0.1"
}

resource "terraform_data" "rosetta_marker" {
  input = "Managed by Jamf Deployer · rosetta@0.0.1"
}

# "Stop managing": keep_me leaves the tenant record without being destroyed.
removed {
  from = terraform_data.keep_me

  lifecycle {
    destroy = false
  }
}
