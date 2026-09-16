# Managed license activation (TypeWhisper 1.6.1 and later)

TypeWhisper can read a commercial license key from macOS preferences and activate
it in the signed-in user's app session. Administrators do not need to call Polar
or write to users' Keychains. This is not available in 1.6.0.

## Configuration profile

Use the [example profile](TypeWhisper-License.mobileconfig) in Iru or another MDM
that supports custom macOS configuration profiles. Replace the placeholder with
your commercial license key, XML-escaping any special characters. Upload the
profile as a custom profile and assign it to the intended Macs. Install the app,
then launch or restart TypeWhisper in each user's session with internet access.

| Preference | Type | Domain | Behavior |
| --- | --- | --- | --- |
| `ManagedLicenseKey` | String | `com.typewhisper.mac` | Automatically activates a commercial license and manages its app controls while nonempty. |

Whitespace around the key is ignored. Supporter keys are not accepted for this
setting. The development app uses `com.typewhisper.mac.dev` instead.

## Script alternative

The same preference may be written with `defaults` in the intended user's context:

```sh
/usr/bin/defaults write com.typewhisper.mac ManagedLicenseKey -string 'YOUR_LICENSE_KEY'
```

This is a provisioning preference, not an access-control boundary. A forced MDM
profile prevents users from editing the preference; an ordinary `defaults` value
does not. MDM agents commonly run scripts as root: writing root's preferences will
not configure the signed-in user's app. Use your MDM's user-session execution
mechanism, and defer until a user is signed in. Do not enable shell tracing or log
keys. Avoid putting real keys in interactive shell history or command-line logs.

## Activation lifecycle

- Configuration is read at startup. Restart TypeWhisper after changing or removing
  the profile. The License page also offers a retry action.
- The app stores the key and its Polar activation ID in that user's Keychain. It
  reuses the record across launches; it does not activate on every launch.
- Multiple users on the same Mac have separate Keychain records and activations.
- Existing licenses keep their normal offline validation behavior. An initial
  activation needs internet access; failures can be retried from Settings > License
  or on the next launch. No background retry loop is installed.
- Changing the key validates and stores the replacement before attempting to
  deactivate the old activation. A failed replacement leaves the old record intact.
  If old-activation cleanup fails, the administrator can remove it in Polar.
- Removing the setting restores manual license controls on the next launch. It does
  not revoke or delete an existing activation. Deactivate it manually or revoke it
  centrally through Polar; central changes are noticed on the normal validation
  schedule (up to seven days for an already-active license).
- A revoked license is not repeatedly reactivated. An activation deleted in Polar
  can be recreated if the configured key remains valid.
- Managed mode hides manual commercial activation and plan controls, suppresses
  license selection prompts, and displays status without displaying the key.
  Microphone permissions, model setup, and the general setup wizard are unchanged.

## Key confidentiality

This removes the need to distribute the key to employees manually. Configuration
profiles and local preferences are not secret stores, and sufficiently privileged
users may retrieve a deployed key. Do not claim that a shared key is inaccessible
on managed devices. Use MDM access controls and avoid logging profile contents.

## Pilot checklist

Before a fleet rollout, test the signed release on one managed Mac:

1. Install the profile and launch TypeWhisper in a standard user's session. Confirm
   Settings > License shows the managed state and successful activation.
2. Restart twice and confirm no additional Polar activations were created.
3. Repeat with another user, and test an initially offline launch followed by retry.
4. Test key replacement and profile removal according to the lifecycle above.
5. Confirm microphone consent and model provisioning for your intended setup.

Automated tests cover the activation lifecycle with mocked Polar responses and
isolated real Keychain entries. They do not prove profile delivery through Iru.
