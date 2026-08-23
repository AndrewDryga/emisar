defmodule Emisar.Fixtures.Certificates do
  @moduledoc """
  Real X.509 certificates for signed-dispatch fixtures.

  The portal reads exactly one fact out of a dispatch certificate — when it
  stops being valid — so an approval is never held past the point where its
  dispatch could still be accepted. Minting a genuine certificate here means
  that read is exercised against real DER rather than a stub the production
  parser would never see.
  """
  require Record

  Record.defrecord(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  # ecdsa-with-SHA256 / id-ecPublicKey / prime256v1.
  @ecdsa_with_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @ec_public_key {1, 2, 840, 10045, 2, 1}
  @prime256v1 {1, 2, 840, 10045, 3, 1, 7}
  @common_name {2, 5, 4, 3}

  @doc """
  Mints a self-signed certificate expiring at `not_after` and returns it as the
  standard-base64 DER a `cert_chain` entry carries.
  """
  def leaf_chain_entry(%DateTime{} = not_after) do
    not_after |> mint_leaf() |> Base.encode64()
  end

  @doc "Mints a self-signed certificate expiring at `not_after`, as raw DER."
  def mint_leaf(%DateTime{} = not_after) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    {:ECPrivateKey, _version, _private, _params, public, _attrs} = key
    name = {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {:utf8String, "fixture"}}]]}

    tbs =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: 42,
        signature: signature_algorithm(algorithm: @ecdsa_with_sha256, parameters: :asn1_NOVALUE),
        issuer: name,
        validity:
          validity(
            notBefore: utc_time(DateTime.add(DateTime.utc_now(), -3_600, :second)),
            notAfter: utc_time(not_after)
          ),
        subject: name,
        subjectPublicKeyInfo:
          subject_public_key_info(
            algorithm:
              public_key_algorithm(
                algorithm: @ec_public_key,
                parameters: {:namedCurve, @prime256v1}
              ),
            subjectPublicKey: {:ECPoint, public}
          ),
        extensions: :asn1_NOVALUE
      )

    :public_key.pkix_sign(tbs, key)
  end

  defp utc_time(%DateTime{} = datetime) do
    {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}
  end
end
