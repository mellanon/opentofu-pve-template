# Windmill

- Windmill deployed via Docker Compose
- Image version 1.789.0
- Uses port 80 on host system

Note: Telemetry can be fully disabled from the instance settings using the "Disable telemetry" toggle.


# Windmill CLI for local development

Tried using Bun and Deno to "bunx" windmill-cli but had trouble with both, so going with node/npm for now.

Installed Node LTS with Fast Node Manager (FNM)

```sh
curl -fsSL https://fnm.vercel.app/install | bash
fnm install --lts
```
During the steps below it wants Bun installed, probably because it uses Bun as the default runtime internally.

```sh
curl -fsSL https://bun.com/install | bash
```

```sh
npm install -g windmill-cli@1.789.0
wmill workspace add metafactory-infra metafactory-infra http://YOURIPADDRESS
wmill init
wmill sync pull
```

