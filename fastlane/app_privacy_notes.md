# App Privacy Notes

Recommended App Store Connect answer: `No, we do not collect data from this app`

Rationale:

- No account system
- No analytics or telemetry
- No advertising or tracking
- No third-party SDKs in the v1 binary
- No developer-accessible backend that stores user data
- SoundFont downloads are simple HTTPS file fetches and are not retained by the developer
- CloudKit usage is limited to the user's Private Database; per product docs, the developer cannot access that data

Source basis:

- `docs/product/privacy-and-accessibility.md`

If the product changes later, revisit App Privacy in these cases:

- Add crash reporting beyond Apple's built-in channels
- Add analytics or attribution
- Add account creation or sign-in
- Add any developer-accessible sync backend
- Add in-app support forms or feedback submission

Conservative fallback if you decide CloudKit Private Database should still be disclosed:

- Declare only data used for app functionality
- Start with `OTHER_USER_CONTENT` and/or `OTHER_DATA`
- Mark as `DATA_NOT_LINKED_TO_YOU`
- Do not mark as tracking
