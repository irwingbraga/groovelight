# Data safety answers (Play Console)

Draft, 2026-10-18. Must match [`privacy-policy.md`](privacy-policy.md).

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | Not applicable (no data collected). Traffic stays on the local network between the device and the user's own Mac; protocol v2 adds TLS |
| Do you provide a way for users to request that their data be deleted? | Not applicable (no data collected). Uninstalling removes everything the app keeps; "Forget" removes the pairing |

Why "no collection" holds: Google's definition counts data sent off the device to the developer or third parties.
The app sends data only to the user's own Mac, under the user's control, which is not the developer's server.
Revisit this if the app ever contacts anything other than the paired Mac (for example online lyrics).
