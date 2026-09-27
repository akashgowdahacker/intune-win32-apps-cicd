# Intune application packaging CI/CD

This repository is a catalog-driven foundation for GitHub Actions now and Azure
DevOps later. The PowerShell scripts do not depend on GitHub, so the same
commands can run in an Azure DevOps PowerShell task.

## Catalog and update policy

Edit [apps/applications.json](apps/applications.json). Each application has a
stable `id`, deployed `currentVersion`, optional `previousVersion`, and a
vendor source. The example uses a GitHub release adapter. For `chromeenterprise.google` or
another vendor, use `source.type: "direct-url"` with a stable vendor download
URL and a `versionRegex` containing a named `version` group, for example
`"ChromeSetup_(?<version>[0-9.]+).msi"`. Do not scrape a web page in the
workflow unless the vendor provides a stable API or download URL.
GitHub release lookups use the Actions `GITHUB_TOKEN` in CI to avoid
unauthenticated API rate limits.

The schedule runs twice daily. It only changes the catalog when the manual
dispatch input `update_catalog` is enabled. Manual runs expose independent
checkboxes for `update_catalog`, `package`, and `deploy`. Packaging also runs
automatically when `deploy` is selected because a fresh workflow runner needs
an artifact. This avoids silently deploying a vendor release from a scheduled
check. Protect the `intune-production` environment with required reviewers.

The n/n-1 retention policy is represented by `currentVersion` and
`previousVersion`; package artifacts are retained for 14 days. If releases are
also created, keep only the two version tags with a separate cleanup job.

## Installer commands and detection

For MSI packages, `Get-InstallerMetadata.ps1` reads the MSI Property table:

* `ProductVersion` becomes the package version.
* `ProductCode` becomes the MSI detection rule.
* Install and uninstall commands are generated as
  `msiexec /i <file> /qn /norestart` and
  `msiexec /x <ProductCode> /qn /norestart`.
The packaging job persists these detected values back into
`apps/applications.json` and commits the catalog update, so the catalog remains
the source of truth for the later Intune deployment step.
* MSI packages use `upgradeBehavior: "in-place"` by default. The deployment
  adapter must update the existing Intune Win32 app instead of creating a new
  app or uninstalling the old one. When the vendor MSI is authored as a major
  upgrade, Windows Installer upgrades the existing installation during
  `msiexec /i`; this depends on the vendor's MSI upgrade table and cannot be
  forced safely by Intune.

For EXE packages, there is no reliable universal uninstall command or
detection rule. The installer must be tested in a Windows VM and the catalog
must specify its silent install/uninstall switches plus a registry, file, or
product-code detection rule. A version shown in Explorer is not sufficient
proof that the vendor's silent install works.

## Intune upload-only test

The deployment job uses the `IntuneWin32App` PowerShell module to upload a
catalog application as an Intune Win32 app. It does not create assignments.
For this initial test it refuses to overwrite an app with the same exact name,
so it cannot inadvertently change existing app content or assignments.

Add these **repository Actions secrets** before selecting `deploy`:

* `INTUNE_TENANT_ID`
* `INTUNE_CLIENT_ID`
* `INTUNE_CLIENT_SECRET`

The Entra app registration needs the Microsoft Graph **application**
permission `DeviceManagementApps.ReadWrite.All` with admin consent. Do not
paste credentials into workflow inputs, commit them, or put them in the app
catalog. Client-secret authentication is used here; GitHub OIDC can be adopted
later.

Select the application ID in the manual workflow. Group assignments are
configured per app in the catalog, for example:

```json
"assignments": [
  {
    "groupId": "00000000-0000-0000-0000-000000000000",
    "intent": "available",
    "notifications": "hideAll"
  }
]
```

Selecting `deploy` updates and packages the selected catalog entry. If its
exact-name Win32 app already exists, the deployment reuses it and does not
replace its package. It creates missing catalog assignments and updates
existing direct assignments' notification setting to match the catalog;
conflicting intents, exclusions, filters, or policy-set-managed assignments
are left untouched and cause a clear failure. Notification values are
`showAll`, `showReboot`, and `hideAll`. `available` makes the app available in
Company Portal to group members; it does not force installation.

Never commit installer binaries or credentials. Protect the
`intune-production` environment with required reviewers.

## Included applications

The catalog includes Notepad++, 7-Zip x64, and Google Chrome Enterprise x64.
7-Zip is discovered from its GitHub release assets. Chrome uses Google's
stable Enterprise MSI URL and reads its version and MSI product code from the
downloaded installer because the URL does not contain a version.
