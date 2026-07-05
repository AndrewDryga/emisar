# tflint — the bundled Terraform ruleset at its recommended preset. No external
# plugins, so CI (and `tflint`) need no `tflint --init` network fetch or token.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
