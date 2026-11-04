plugin "raw_exec" {
  config {
    enabled = true
  }
}

# This client has no cloud identity, and no case reads cloud attributes. `-dev`
# gives these checks about 1 ms in total, so on a host whose metadata address
# answers that fast, a read that misses the budget stops the agent at startup.
client {
  options = {
    "fingerprint.denylist" = "env_aws,env_gce,env_azure,env_digitalocean"
  }
}
