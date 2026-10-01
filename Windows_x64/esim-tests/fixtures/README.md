# Synthetic fixtures

`single-qr.png` contains `LPA:1$example.com$synthetic-test`.
`multiple-qr.png` contains two different synthetic LPA codes.
`non-esim-qr.png` contains non-eSIM text. These are local decoder fixtures,
not usable subscriptions. `untrusted-test-ca.der` is a synthetic self-signed
certificate that is outside the production root allowlist. Its private key
was discarded; it is never added to application trust.
