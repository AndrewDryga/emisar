addresses {
  https = "0.0.0.0"
}

ports {
  https = 8501
}

tls {
  https {
    ca_file         = "/consul/config/packtest-tls/ca.pem"
    cert_file       = "/consul/config/packtest-tls/server.pem"
    key_file        = "/consul/config/packtest-tls/server-key.pem"
    verify_incoming = true
  }
}
