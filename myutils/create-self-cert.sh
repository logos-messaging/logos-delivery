openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365   -keyout self-signed.key -out self-signed.crt   -subj "/CN=localhost"
