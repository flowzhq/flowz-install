# flowz-install

Bootstrap installers for the [Flowz](https://codeflowz.ai) CLI.

Flowz is distributed privately to design partners. These scripts are public
because an installer has to be fetchable before you have anything installed —
they contain no secrets, and they will not download anything without the access
token you were issued.

## Install

**macOS / Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/flowzhq/flowz-install/main/install.sh \
  | FLOWZ_TOKEN=<your token> sh
```

**Windows (PowerShell)**

```powershell
$env:FLOWZ_TOKEN = "<your token>"
irm https://raw.githubusercontent.com/flowzhq/flowz-install/main/install.ps1 | iex
```

This installs `flowz` to `~/.flowz/bin` and stores your token so that
`flowz upgrade` works from then on. No `sudo` required.

### Options

| Variable | Effect |
|---|---|
| `FLOWZ_TOKEN` | **required** — the access token you were issued |
| `FLOWZ_VERSION` | install an exact version (e.g. `v1.2.3`) instead of the latest |
| `FLOWZ_INSTALL_DIR` | install somewhere other than `~/.flowz/bin` |

## Updating

Once installed, the CLI updates itself:

```sh
flowz upgrade
```

## Don't have a token?

Flowz is in a private design-partner programme. Get in touch at
[codeflowz.ai](https://codeflowz.ai).

---

These files are generated — the source of truth lives in the `flowz-app`
repository at `tools/scanner-cli/scripts/`, and each release syncs them here.
Please open issues against Flowz rather than editing them here.
