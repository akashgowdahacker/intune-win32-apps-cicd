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

## Intune deployment adapter

The `deploy` job intentionally stops before Graph upload. Connect it to the
approved Graph implementation used by your tenant (for example, the referenced
`Deploy-IntuneApp.ps1` pattern), passing the generated `.intunewin`, commands,
detection rule, requirements, and version from the catalog. Required
application permission is normally `DeviceManagementApps.ReadWrite.All`.
Prefer GitHub OIDC with a federated Entra credential over a client secret.

The adapter should:

1. Find an existing Win32 app by a stable identifier such as `id`.
2. Skip upload when the deployed version equals `currentVersion`.
3. Upload the package and update metadata/detection/requirements.
4. Preserve the existing app identity and assignments; do not uninstall it or
   create a second app for an in-place upgrade.
5. Remove versions older than n-1 only after a successful deployment.

Never commit installer binaries or credentials. Keep the production
environment approval enabled before wiring the final deploy step.

## Included applications

The catalog includes Notepad++, 7-Zip x64, and Google Chrome Enterprise x64.
7-Zip is discovered from its GitHub release assets. Chrome uses Google's
stable Enterprise MSI URL and reads its version and MSI product code from the
downloaded installer because the URL does not contain a version.
