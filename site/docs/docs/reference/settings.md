# Settings

Open **Settings…** from the menu bar icon, or press ⌘, while the menu is open.

## General

| Setting | What it does |
| --- | --- |
| **Open at login** | Registers OpenBeam as a login item so it starts with your session. Disabled unless OpenBeam is in your Applications folder — a login item pointing anywhere else breaks as soon as that location goes away. |
| **Send as UYVY (4:2:2)** | Sends half the colour data. Lighter on the network; whether you can see the difference depends on what your camera produces natively. |

If macOS is holding the login item for approval, the pane says so and offers a button
straight to **System Settings → General → Login Items**. No app can approve itself there.

## Updates

| Setting | What it does |
| --- | --- |
| **Check for updates automatically** | The daily background check. |
| **Download in the background** | Fetches an update before you ask for it. |
| **Check Now** | Checks immediately. |

The pane also shows the running version — which the menu bar shows beside the app's name too — and when the last check happened. See
[Updating](/guides/updating).

## Clipboard

| Setting | What it does |
| --- | --- |
| **Sync the clipboard** | Turns clipboard sync on. |
| **Discovered** | Devices on the network running OpenBeam that you have not paired. |
| **Paired** | Devices you have paired, with a **Forget** button. |

See [Clipboard sync](/guides/clipboard-sync).

## About

The version this copy is running, and where everything came from: the source on GitHub,
the author's profile, the licence, and the projects OpenBeam is built on — the NDI SDK
by Vizrt and Phosphor Icons. Every row opens in your browser.

## What stays in the menu

The menu bar keeps what is an action or live state rather than a preference: the
Send/Receive tabs, the camera preview, the audio level meter, camera and microphone
selection, NDI source selection, virtual camera status, Restart NDI and Statistics.
