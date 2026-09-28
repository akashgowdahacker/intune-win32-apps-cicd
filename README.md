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
existing direct assignments' notification setting to match the catalog. Since
the tenant Graph service rejects PATCH of assignment settings, changing that
setting deletes and recreates only the matching direct, unfiltered group
assignment, preserving its target, intent, and other settings; the script tries
to restore the original assignment if recreation fails.
conflicting intents, exclusions, filters, or policy-set-managed assignments
are left untouched and cause a clear failure. Notification values are
`showAll`, `showReboot`, and `hideAll`. `available` makes the app available in
Company Portal to group members; it does not force installation.

Never commit installer binaries or credentials. Protect the
`intune-production` environment with required reviewers.

## Application status

The catalog contains seven currently packageable applications: Notepad++,
7-Zip x86 and x64, Google Chrome Enterprise x64, Microsoft Purview Information
Protection 3.2.92.0, PuTTY 0.85 x64, and WinSCP 6.5.7. The other requested
applications are recorded with
`status: "pending-validation"` and official vendor reference or supplied
reference links where available. A
`source.referenceUrl` is informational only; it is not used as an installer
download URL. Some supplied links are third-party downloads and are flagged in
the corresponding `pendingReason`. Staged applications are deliberately
excluded from catalog updates and cannot be packaged or deployed until their
vendor installer URL, silent commands, architecture, and detection rule have
been verified. Apps requiring licensed, legacy, or organization-specific
installers also need their package source confirmed before activation.

The workflow's application selector lists only packageable applications. To
activate a staged entry, verify its installer and deployment behavior, then
add its supported source/package metadata and remove the pending status.
For a manual run, select `all-validated` to check, package, or deploy every
catalog entry that is not pending validation. The deployment job applies only
assignments explicitly configured on each app; apps with no assignments are
uploaded without being assigned to a group.
Before upload, the packaging job runs each catalog install command on its
disposable Windows runner, confirms the configured MSI/file detection rule,
uninstalls the app, and confirms removal. A failed install, detection, or
uninstall blocks the deployment job. If the runner image already contains the
app, the test skips it rather than modifying that pre-existing installation.
This is a smoke test on GitHub's Windows image, not a substitute for validating
behavior on managed endpoint models.

The separate **Catalog validation** workflow runs on changes to the catalog,
scripts, or workflows. It checks catalog fields and unique IDs, confirms the
Intune selector matches packageable entries, parses all PowerShell scripts, and
smoke-tests that pending apps are rejected before download or deployment.
It does not download installers, package apps, or require Intune credentials.

Notepad++ and both 7-Zip architectures are discovered from GitHub release
assets. Chrome uses Google's stable Enterprise MSI URL and reads its version
and MSI product code from the downloaded installer because the URL does not
contain a version. WinSCP's official page supplies a time-limited CDN download
link; the packager resolves it at package time and verifies the vendor-published
SHA-256 and code-signing certificate before smoke testing the installer.
The Purview client wrapper sets Microsoft's documented
`AllowMajorVersionUpgrade` registry value before silent MSI installation so
non-interactive upgrades from the legacy AIP client can proceed. Microsoft
documents that this upgrade removes the legacy AIP Office add-in; validate that
change with a pilot group before assigning the app broadly.
