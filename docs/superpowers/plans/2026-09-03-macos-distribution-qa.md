# macOS distribution QA

## Prerequisites only the account holder can do

1. **Enable the macOS platform on the App Store Connect record** (app id `6766994527`, `com.KeyNumber.Folino`).
   The Mac app shares the iOS record by design — that is what makes Ⅶ's purchase universal — but the macOS
   platform has to be added to it before any `.pkg` will upload.
2. **A Mac Installer Distribution certificate.** A Mac App Store `.pkg` is signed with a different certificate
   from the app-signing one. Whether `-allowProvisioningUpdates` mints it automatically is UNVERIFIED; the first
   `fastlane mac archive_and_upload` is what settles it. If it fails, create it in the Developer portal.
