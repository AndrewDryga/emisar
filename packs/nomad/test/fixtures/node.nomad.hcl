job "packtest-node" {
  datacenters = ["dc1"]
  group "probe" {
    task "node" {
      driver = "raw_exec"
      config {
        command = "/bin/sleep"
        args = ["600"]
      }
      env {
        NODE_EXTRA_CA_CERTS = "/fixture/tls/ca.pem"
        NODE_OPTIONS = "--require=/fixture/node-preload.cjs"
        NODE_DEBUG = "http,https,tls"
        NODE_V8_COVERAGE = "/tmp/packtest-node-coverage"
      }
      resources {
        cpu = 100
        memory = 128
      }
    }
    task "untrusted" {
      driver = "raw_exec"
      config {
        command = "/bin/sleep"
        args = ["600"]
      }
      env {
        NODE_TLS_REJECT_UNAUTHORIZED = "0"
      }
      resources {
        cpu = 100
        memory = 128
      }
    }
  }
}
