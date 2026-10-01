# Lid Sleep

A tiny native macOS menu-bar app for choosing whether your Mac stays awake
when you close its lid. Custom vector icons, no Dock icon, no third-party
dependencies, and no password prompts after one-time setup.

| Awake | Sleep |
| :---: | :---: |
| <img src="docs/awake.png" width="88" alt="Laptop with sun"> | <img src="docs/sleep.png" width="88" alt="Laptop with crescent moon"> |
| Keep the Mac awake | Allow normal macOS sleep |

The icon follows the menu bar's light/dark tint. Hover for status, or open the
menu to change modes. Menu checkmarks and a VoiceOver label report the current
setting. Dots mean a change is in progress; a question mark means the setting
could not be read.

> **Important:** Awake mode disables **all system sleep**, not just lid sleep,
> on both battery and charger. It drains battery. Never put an awake Mac in a
> bag. Quitting the app does **not** restore sleep.

## Build and install

Requires macOS 13 or newer and Apple's command-line tools (`xcode-select --install`).

```sh
git clone https://github.com/Yeyito777/lid-sleep.git
cd lid-sleep
./build.sh

# Quit an existing copy before updating.
mkdir -p "$HOME/Applications"
ditto "build/Lid Sleep.app" "$HOME/Applications/Lid Sleep.app"
open -g "$HOME/Applications/Lid Sleep.app"
```

The build creates a local, ad-hoc-signed app; it is not notarized.

Choose **Enable password-free toggles…** in the menu and approve the standard
macOS administrator dialog once. Setup does not change the current sleep
setting. Subsequent toggles never request a password.

To start at login, add `Lid Sleep.app` in **System Settings → General → Login
Items**. An existing LaunchAgent installation continues to work.

## How it works

- **Sun / Awake / No:** `/usr/bin/pmset -a disablesleep 1`.
- **Moon / Sleep / Yes:** `/usr/bin/pmset -a disablesleep 0`.
- Sleep mode restores normal macOS rules; external-display clamshell mode and
  other sleep assertions still apply. It does not force immediate sleep.
- The app reads the actual system setting at launch, when its menu opens, and
  every 15 seconds. The power setting persists independently of the app.

### One-time permission

Setup installs `/private/etc/sudoers.d/lidsleep-<uid>` as `root:wheel`, mode
`0440`. The rule permits only that user to run the two exact commands above as
root without a password. There are no wildcards, shell privileges, or grants
for other `pmset` options. Other processes running as that user can also invoke
these two commands; the grant is user-scoped, not app-scoped.

The rule is staged, validated with `visudo`, and atomically installed. A failed
validation rolls back a newly installed rule. The main sudoers file is never
modified, and setup refuses to overwrite a different rule.

Toggles use `sudo -n -k`: they never prompt, use cached administrator credentials,
or fall back to interactive approval. There is no privileged daemon, network
access, stored password, or third-party dependency.

## Command-line interface

```sh
APP="$HOME/Applications/Lid Sleep.app/Contents/MacOS/LidSleep"

"$APP" --status                 # Read-only status
"$APP" --self-test              # Tests; no power settings changed
"$APP" --enable-no-prompt       # One-time administrator setup
"$APP" --set sleep              # Restore normal sleep rules
"$APP" --set awake              # Disable all system sleep
"$APP" --icon-preview build/icons
"$APP" --help
```

To test a fresh build without installing:

```sh
"build/Lid Sleep.app/Contents/MacOS/LidSleep" --self-test
codesign --verify --strict "build/Lid Sleep.app"
```

## Remove

1. If desired, choose **Yes — allow normal sleep** before quitting, or run
   `LidSleep --set sleep`. Removing the app alone does not restore sleep.
2. Quit the app, remove its login item, and delete `~/Applications/Lid Sleep.app`.
3. Revoke password-free access with administrator approval:

   ```sh
   sudo rm "/private/etc/sudoers.d/lidsleep-$(id -u)"
   ```

For a LaunchAgent installation, unload only that login item with
`launchctl bootout "gui/$(id -u)/local.yeyito.LidSleep"` and remove
`~/Library/LaunchAgents/local.yeyito.LidSleep.plist`.
