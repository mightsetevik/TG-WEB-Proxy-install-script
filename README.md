# Telemt WEB Installer

`install-telemt-web.sh` installs Telemt WEB mode behind Caddy on Debian/Ubuntu with systemd.

The installer:

- downloads a pinned Telemt release and verifies its SHA-256 checksum;
- creates the unprivileged `telemt` service user;
- generates a new proxy secret and API token on the target VPS;
- creates a local static decoy site;
- obtains TLS through Caddy/Let's Encrypt;
- exposes only TCP `80/443` through UFW;
- keeps the Telemt WEB listener and API on loopback;
- applies systemd service hardening.

## Local Run

```bash
chmod +x install-telemt-web.sh
sudo ./install-telemt-web.sh \
  --domain proxy.example.com \
  --email admin@example.com
```

The domain must already resolve to the VPS before Caddy can obtain a certificate.
Credentials are written to a root-only file under `/root/telemt-web-credentials-<domain>.txt`.

## GitHub Run

After publishing the script to a reviewed repository:

```bash
curl -fsSLO https://raw.githubusercontent.com/OWNER/REPOSITORY/main/install-telemt-web.sh
less install-telemt-web.sh
sudo bash install-telemt-web.sh --domain proxy.example.com --email admin@example.com
```

Do not pipe an unreviewed remote script directly into `sudo bash`. Pinning a reviewed commit or release tag is preferable to using `main`.
