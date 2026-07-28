job "packtest-health" {
  datacenters = ["dc1"]
  type        = "service"

  group "api" {
    count = 2

    task "web" {
      driver = "docker"

      config {
        image   = "busybox:1.36"
        command = "/bin/sleep"
        args    = ["300"]
      }
    }
  }
}
