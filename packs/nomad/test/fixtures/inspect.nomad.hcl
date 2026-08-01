job "packtest-inspect" {
  datacenters = ["dc1"]
  type        = "batch"

  group "fixture" {
    task "wait" {
      driver = "raw_exec"

      config {
        command = "/bin/sleep"
        args    = ["300"]
      }

      env {
        # Mirrors NOMAD_PACKTEST_CANARY in test/cases.yaml — the harness scans
        # every surface for this value; job_inspect must only ever return it
        # redacted.
        PACKTEST_DB_PASSWORD = "packtest-canary-nomad-e57d31"
      }
    }
  }
}
