job "packtest-stop" {
  datacenters = ["dc1"]
  type        = "batch"

  group "fixture" {
    task "wait" {
      driver = "raw_exec"

      config {
        command = "/bin/sleep"
        args    = ["300"]
      }
    }
  }
}
