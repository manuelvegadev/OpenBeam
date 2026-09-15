# Troubleshooting

## The app will not open on first launch

Expected: OpenBeam is not notarized. Open **System Settings → Privacy & Security**,
scroll to the bottom, and choose **Open Anyway**. See
[Install](/#install).

## No NDI sources appear in Receive

- Confirm the sending machine really is sending: its menu shows a live preview and
  `NDI: <name>`.
- Confirm both machines are on the same network, and that it is not a guest network.
  Client isolation blocks the discovery that NDI depends on. See
  [Requirements](/reference/requirements#network).
- Give it a few seconds. Discovery starts when the menu opens, so the first look often
  finds nothing.
- Try **Restart NDI** on the sending machine.

## "Choose the source in NDI Virtual Input"

OpenBeam can see the NDI camera extension but cannot tell it which source to take —
that version of NDI Tools does not expose the setting. Pick the source inside NDI Virtual
Input itself; everything else keeps working.

## The virtual camera does not appear in Zoom or Meet

- Install [NDI Tools](https://ndi.video/tools/) if you have not, and approve the camera
  extension when macOS asks.
- Quit the call app fully and reopen it. Most of them enumerate cameras once at launch.
- Choose **NDI Virtual Camera** in that app's own video settings. No app can select it
  for you.

## The camera is black, or another app has it

macOS hands a camera to one app at a time for exclusive formats. Quit whatever else is
using it — including a video call app left running in the background — and pick the
camera again in OpenBeam.

## Updates never appear

Check **Settings → Updates**. If it says OpenBeam cannot update itself from where it is,
move the app to your Applications folder and open it from there. See
[Updating](/guides/updating#open-beam-must-be-in-applications).

## Clipboard sync does not sync

- Both machines need **Sync the clipboard** on.
- They need to be *paired*, not merely discovered, and pairing has to be accepted on the
  other machine.
- Same network rules as NDI apply.
