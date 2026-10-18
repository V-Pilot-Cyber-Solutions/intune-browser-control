# DigiTrans Intune Browser Control

Private GitHub repository starter for building and publishing the existing DigiTrans Chrome/Edge Platform Script.

## Before production
1. Copy every currently approved clean DEV-7.0 entry into the matching config file. The sample common list is intentionally incomplete.
2. Never paste HTML anchors from Teams/Copilot into the config files.
3. Create an Entra app with Microsoft Graph application permission `DeviceManagementScripts.ReadWrite.All` and grant admin consent.
4. Add a federated credential for GitHub environment `intune-production`.
5. Create GitHub environment variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `INTUNE_SCRIPT_ID`.
6. Protect `main`, require pull requests and a production environment reviewer.
7. Keep the existing Intune script object and assignment. The workflow updates that object.

## Add a URL
- Create a change branch.
- Add one exact host per line to `config/common-allowlist.txt`.
- Update CHANGELOG.md with the change reference and approval.
- Open a pull request, review and merge.
- Approve the `intune-production` deployment.

## Local test
```powershell
./tools/Build-BrowserControl.ps1 -Version DEV-7.1
./tools/Validate-BrowserControl.ps1
```
