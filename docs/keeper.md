# Keeper calendar sync

Install on the CoreX server after deploying this repository revision:

```sh
corex manage add keeper
```

The service uses `https://keeper.YOUR_DOMAIN`, behind the existing Traefik TLS
route. If your Cloudflare Tunnel uses individual hostnames rather than a wildcard,
add that hostname to the tunnel, pointing to the existing Traefik ingress.
Complete the initial Keeper account setup before sharing the address.

CoreX pins the published `ghcr.io/ridafkih/keeper-standalone:2.18.7` image. It
bundles the web app, API, background workers, PostgreSQL, Redis and MCP. CoreX
limits it to one CPU and 1536 MiB, with two sync workers and small database pools.
These are initial resource limits, not measured memory requirements for your
calendar count. Keep the service running: a closed browser does not mean there
is no calendar work to do.

## Connect calendars

1. In Nextcloud's security settings, create an app password for Keeper. Use the
   CalDAV address shown by Nextcloud Calendar in Keeper's CalDAV connection.
2. Google and Microsoft connections require OAuth applications registered in
   your own provider accounts. Put the client IDs and secrets in
   `/mnt/corex-data/docker-configs/keeper/providers.env`, using the upstream
   `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `MICROSOFT_CLIENT_ID` and
   `MICROSOFT_CLIENT_SECRET` names. Keep this file mode 0600. Restart Keeper
   with `corex manage repair keeper` after editing it.
3. Follow Keeper's current OAuth guide for scopes and redirect URLs. Connect
   the personal and work accounts in the Keeper UI. A work account may require
   your employer's administrator to approve the OAuth app.
4. Start with one source and one destination calendar. Verify a test event,
   change and deletion before adding more sync mappings. Choose explicitly
   which event details should be copied into the work calendar.

Polling works without provider webhooks. For provider push notifications, add
`WEBHOOK_PUBLIC_URL=https://keeper.YOUR_DOMAIN` to `providers.env` only after
Google and Microsoft can reach that public HTTPS address. No application
credentials need to be pasted into a chat or committed to Git.

## Backup and restore

Keep `docker-configs/keeper/.secrets.env` with every Keeper database backup; the
encryption key is required to decrypt stored calendar credentials. CoreX also
backs up `providers.env` and creates `.db-dumps/keeper.sql.gz` through PostgreSQL
for a consistent logical backup. It deliberately excludes the live
`service-data/keeper-db` files from restic because copying files while PostgreSQL
writes them can produce a torn database. CoreX refuses to generate replacement
secrets when an existing database directory is present. Refresh installed backup
scripts through `corex manage maintenance setup`.

For a logical restore, stop Keeper, restore its original secrets, initialize an
empty database with the pinned image, then restore the dump into that database
following PostgreSQL's restore procedure. Do not overwrite running database files.

Sources: [Keeper self-hosting guide](https://github.com/ridafkih/keeper.sh#self-hosted),
[published image](https://github.com/ridafkih/keeper.sh/pkgs/container/keeper-standalone).
